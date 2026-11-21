import AppKit
import CoreImage
import Darwin
import PortsCore

/// Every action of the panel. All stops go through PortsCore (StopRegistry → identity check → StopPolicy ladder);
/// confirmations are inline in the panel (Prompter), except bulk clean-up.
extension AppDelegate {
    // MARK: Stop flow bookkeeping

    /// Claim the stop flow for `key`; if one is already running, show its prompt again instead.
    func beginStop(_ key: String) -> Bool {
        if stops.claim(key) { return true }
        if let p = model.pendingPrompts[key] { model.prompt = p } else { NSSound.beep() }
        return false
    }

    func endStop(_ key: String) {
        stops.release(key)
        model.pendingPrompts[key] = nil
    }

    func ask(_ p: InlinePrompt) {
        if let k = p.key { model.pendingPrompts[k] = p }
        prompter.ask(p)
    }

    func report(_ title: String, _ text: String = "") { prompter.tell(title, text) }

    // MARK: Stop through the supervisor (four-part confirmation)

    func stop(_ l: Listener) {
        if KnownPorts.restartsAutomatically(l) { return explainRestart(l) }
        let key = StopRegistry.key(pid: l.pid, start: l.start)
        guard beginStop(key) else { return }
        let s = model.analysis.starter(l) ?? starter(of: l.chain, isLaunchdJob: false)
        scanQueue.async {
            let methods = stopMethods(l, starter: s, ctx: supervisorContext(for: l, starter: s))
            RunLoop.main.perform(inModes: [.common]) { MainActor.assumeIsolated { self.offer(methods, for: l, key: key) } }
        }
    }

    func stopTree(_ l: Listener) {
        let key = StopRegistry.key(pid: l.pid, start: l.start)
        guard beginStop(key) else { return }
        scanQueue.async {
            let methods: [StopMethod] = [.tree(treeTargets(root: StopTarget(l)))]
            RunLoop.main.perform(inModes: [.common]) { MainActor.assumeIsolated { self.offer(methods, for: l, key: key) } }
        }
    }

    func offer(_ methods: [StopMethod], for l: Listener, key: String) {
        if methods.count == 1, case .explain(let why) = methods[0] {
            endStop(key); return report(L("Ports won't stop") + " \(l.label)", why)
        }
        if settings.isProtected(l.port) {
            return prompter.input(L("Port") + " :\(l.port) " + L("is protected"), L("Type the port number to stop") + " \(l.label).",
                                  placeholder: String(l.port), button: L("Continue"), onCancel: { self.endStop(key) }) { typed in
                guard confirmsProtectedPort(typed, port: l.port) else { self.endStop(key); return self.report(L("Not stopped"), L("The number didn't match.")) }
                self.offerMethods(methods, for: l, key: key)
            }
        }
        offerMethods(methods, for: l, key: key)
    }

    func offerMethods(_ methods: [StopMethod], for l: Listener, key: String) {
        let actions = Array(methods.filter { if case .explain = $0 { return false }; return true }.prefix(3))
        var text = actions.map { confirmation($0, for: l).text }.joined(separator: "\n\n")
        if let warning = StopPolicy(l).warning { text += "\n\n⚠️ " + warning }
        if l.baseKind == .docker && l.container == nil { text += "\n\n⚠️ " + L("This is the container engine. Stopping it stops ALL containers.") }
        let force = RecentStops.shared.isRecent(key)
        if force { text += "\n\n" + L("You asked to stop it less than 2 minutes ago. Force Quit (SIGKILL) ends it now.") }
        var buttons = actions.map { m in InlinePrompt.Button(title: confirmation(m, for: l).title, role: .destructive) { _ in self.perform(m, for: l, key: key) } }
        if force { buttons.append(.init(title: L("Force Quit"), role: .destructive) { _ in self.forceNow(l, key: key) }) }
        buttons.append(.init(title: L("Cancel"), role: .cancel) { _ in self.endStop(key) })
        var p = InlinePrompt(title: L("Stop") + " \(l.label)?", message: text, buttons: buttons)
        p.key = key
        ask(p)
    }

    func perform(_ m: StopMethod, for l: Listener, key: String) {
        RecentStops.shared.record(key)
        let ports = l.port > 0 ? [l.port] : []
        switch m {
        case .signal(let t):
            ladder(pid: t.pid, start: t.start, policy: t.policy, ports: ports, name: l.label, method: "signal ladder")
        case .app(let bundle, let pid):
            endStop(key)
            let app = NSWorkspace.shared.runningApplications.first { $0.bundleURL?.path == bundle }
            let name = (bundle as NSString).lastPathComponent
            guard let app, app.terminate() else { return report(L("Couldn't ask the app to quit"), name) }
            afterWork({ for _ in 0..<100 where Proc.identity(pid)?.start == l.start { usleep(100_000) } }) { fresh in
                self.log(l, method: "quit app", result: Proc.identity(pid)?.start == l.start ? "still running" : "quit")
                self.report(ports.isEmpty ? name + " " + L("quit") : portReport(l.port, owners: owners(ofPort: l.port, in: fresh)))
            }
        default:
            endStop(key)
            if case .container(let n) = m { containersStoppedByUs.insert(n) }
            if case .compose(_, let ns) = m { containersStoppedByUs.formUnion(ns) }
            var err: SupervisorError?
            afterWork({ err = execute(m, registry: self.stops) }) { fresh in
                self.log(l, method: confirmation(m, for: l).how, result: err?.description ?? "done")
                if let err { return self.report(L("Couldn't stop") + " \(l.label)", err.description) }
                self.report(ports.isEmpty ? "\(l.label) " + L("stopped") : portReport(l.port, owners: owners(ofPort: l.port, in: fresh)))
            }
        }
    }

    /// The safe ladder, then the port report. A data store or app still running afterwards gets Force as its own step.
    func ladder(pid: pid_t, start: UInt64, policy: StopPolicy, ports: [Int], name: String, method: String) {
        let key = StopRegistry.key(pid: pid, start: start)
        var err: KillError?
        afterWork({ err = safeTerminate(pid: pid, start: start, policy: policy) }) { fresh in
            let survived = ports.isEmpty ? Proc.identity(pid)?.start == start : fresh.contains { $0.pid == pid && $0.start == start }
            self.history.append([HistoryEvent(at: Date(), kind: .stop, port: ports.first, pid: pid, name: name, by: "app", method: method,
                                              result: err?.description ?? (survived ? "still running" : "stopped"))])
            if let err { self.endStop(key); return self.report(L("Couldn't stop PID") + " \(pid)", err.description) }
            let report = ports.isEmpty ? "\(name) (PID \(pid)) " + (survived ? L("is still running") : L("stopped"))
                : ports.map { portReport($0, owners: owners(ofPort: $0, in: fresh)) }.joined(separator: "\n")
            guard survived && !policy.autoForce else { self.endStop(key); return self.report(report) }
            var p = InlinePrompt(title: "\(name) " + L("is still running"),
                                 message: report + "\n\n" + L("It didn't shut down within") + " \(Int(policy.grace)) s. "
                                    + L("Force Quit kills it immediately (SIGKILL) and may lose unsaved data."),
                                 buttons: [.init(title: L("Force Quit"), role: .destructive) { _ in
                                     var forceErr: KillError?
                                     self.afterWork({ forceErr = forceKill(pid: pid, start: start) }) { fresh in
                                         self.endStop(key)
                                         if let forceErr { return self.report(L("Couldn't force quit PID") + " \(pid)", forceErr.description) }
                                         let r = ports.map { portReport($0, owners: owners(ofPort: $0, in: fresh)) }.joined(separator: "\n")
                                         self.report(r.isEmpty ? "\(name) (PID \(pid)) " + L("was force-quit") : r)
                                     }
                                 }, .init(title: L("Leave It Running"), role: .cancel) { _ in self.endStop(key) }])
            p.key = key
            self.ask(p)
        }
    }

    func forceNow(_ l: Listener, key: String) {
        var err: KillError?
        afterWork({ err = forceKill(pid: l.pid, start: l.start) }) { fresh in
            self.endStop(key)
            self.log(l, method: "force quit (SIGKILL)", result: err?.description ?? "done")
            if let err { return self.report(L("Couldn't force quit PID") + " \(l.pid)", err.description) }
            self.report(l.port > 0 ? portReport(l.port, owners: owners(ofPort: l.port, in: fresh)) : "PID \(l.pid) " + L("was force-quit"))
        }
    }

    func log(_ l: Listener, method: String, result: String) {
        history.append([HistoryEvent(at: Date(), kind: .stop, port: l.port > 0 ? l.port : nil, pid: l.pid, name: l.label,
                                     by: "app", method: method, result: result)])
    }

    /// Kill would be pointless (launchd restarts it at once): explain, and offer the setting that frees the port.
    func explainRestart(_ l: Listener) {
        let text = (KnownPorts.explanation(l).map { $0 + "\n\n" } ?? "") + L("Stopping it won't free port") + " \(l.port)."
        var buttons: [InlinePrompt.Button] = []
        if let link = KnownPorts.settingsAction(l) { buttons.append(.init(title: link.title, role: .normal) { _ in NSWorkspace.shared.open(link.url) }) }
        buttons.append(.init(title: L("OK"), role: .cancel) { _ in })
        prompter.ask(InlinePrompt(title: L("macOS restarts") + " \(appName(l.exe)) " + L("immediately"), message: text, buttons: buttons))
    }

    // MARK: Multi-select, bulk clean-up, pause, protect

    /// Several rows stopped together with one (inline) confirmation listing every process and its signals.
    func stopSelected(_ rows: [Listener]) {
        let ok = rows.filter { $0.uid == getuid() && $0.container == nil && !KnownPorts.restartsAutomatically($0) && $0.baseKind != .system }
        let protected = ok.filter { settings.isProtected($0.port) }
        var seen = Set<String>()
        let targets = ok.filter { !settings.isProtected($0.port) && seen.insert(processKey($0)).inserted }
        guard !targets.isEmpty else {
            return report(L("Nothing to stop"), protected.isEmpty ? L("None of the selected rows can be stopped together.")
                          : L("Protected ports are stopped one at a time."))
        }
        let list = targets.map { ":\($0.port) \($0.label) — PID \($0.pid) · " + (StopPolicy($0).autoForce ? "SIGTERM, SIGKILL after 2 s" : "SIGTERM only") }
        prompter.confirm(L("Stop") + " \(targets.count) " + L("processes?"),
                         list.joined(separator: "\n") + (protected.isEmpty ? "" : "\n\n" + L("Protected ports left out:") + " "
                            + protected.map { ":\($0.port)" }.joined(separator: ", ")),
                         button: L("Stop All")) {
            var outcomes: [StopOutcome] = []
            self.afterWork({ outcomes = stopAll(targets.map(StopTarget.init), registry: self.stops) }) { fresh in
                for (l, o) in zip(targets, outcomes) { self.log(l, method: "signal ladder (multi-select)", result: o.summary) }
                self.model.selection.removeAll()
                let lines = outcomes.map(\.summary) + Set(targets.map(\.port)).sorted().map { portReport($0, owners: owners(ofPort: $0, in: fresh)) }
                self.report(L("Stopped") + " \(outcomes.filter { $0.error == nil && !$0.refused && !$0.stillRunning }.count)/\(outcomes.count)",
                            lines.joined(separator: "\n"))
            }
        }
    }

    /// Confirmed orphans (checked) and likely ones (opt-in), listeners and leftovers alike.
    func cleanupCandidates() -> [(l: Listener, checked: Bool, why: String)] {
        var out: [(Listener, Bool, String)] = []
        for l in model.listeners where l.uid == getuid() {
            guard let v = model.analysis.verdict(l), v.level >= .likely else { continue }
            out.append((l, v.level == .confirmed, v.evidence.first ?? ""))
        }
        for left in model.analysis.leftovers { out.append((left.process, true, left.verdict.evidence.first ?? "")) }
        return out
    }

    /// The one modal confirmation the spec allows: lists exactly what will be signalled, then runs the safe ladder.
    func cleanUp() {
        let candidates = cleanupCandidates()
        guard !candidates.isEmpty else { return report(L("Nothing to clean up"), L("No orphaned processes were found.")) }
        popover.performClose(nil)
        NSApp.activate()
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = L("Clean up") + " \(candidates.count) " + L("orphaned processes?")
        a.informativeText = L("Each checked process gets SIGTERM (SIGCONT too if it is suspended) and time to exit. Only dev servers are force-killed (SIGKILL) if they don't exit within 2 s; anything else that keeps running is reported, never force-killed. Likely orphans are unchecked: tick them to include them.")
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        var boxes: [NSButton] = []
        for c in candidates {
            let port = c.l.port > 0 ? ":\(c.l.port) " : ""
            let box = NSButton(checkboxWithTitle: "\(port)\(c.l.label) — PID \(c.l.pid) · " + (StopPolicy(c.l).autoForce ? "SIGTERM, SIGKILL after 2 s" : "SIGTERM only"),
                               target: nil, action: nil)
            box.state = c.checked ? .on : .off
            box.toolTip = c.why
            boxes.append(box)
            stack.addArrangedSubview(box)
        }
        stack.frame = NSRect(x: 0, y: 0, width: 480, height: CGFloat(boxes.count) * 22)
        a.accessoryView = stack
        a.addButton(withTitle: L("Clean Up")).hasDestructiveAction = true
        a.addButton(withTitle: L("Cancel")).keyEquivalent = "\u{1b}"
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let chosen = zip(candidates, boxes).filter { $0.1.state == .on }.map(\.0.l)
        guard !chosen.isEmpty else { return }
        var outcomes: [StopOutcome] = []
        afterWork({ outcomes = stopAll(chosen.map(StopTarget.init), registry: self.stops) }) { fresh in
            for (l, o) in zip(chosen, outcomes) { self.log(l, method: "clean-up (signal ladder)", result: o.summary) }
            let ports = Set(chosen.map(\.port).filter { $0 > 0 }).sorted()
            self.report(L("Clean-up finished"), (outcomes.map(\.summary) + ports.map { portReport($0, owners: owners(ofPort: $0, in: fresh)) })
                .joined(separator: "\n"))
        }
    }

    func setPaused(_ l: Listener, _ paused: Bool) {
        var err: KillError?
        let key = processKey(l)
        afterWork({ err = paused ? pause(pid: l.pid, start: l.start) : resume(pid: l.pid, start: l.start) }) { _ in
            if let err { return self.report((paused ? L("Couldn't pause PID") : L("Couldn't resume PID")) + " \(l.pid)", err.description) }
            if paused { self.pausedByUs.insert(key) } else { self.pausedByUs.remove(key) }
            self.model.objectWillChange.send()
        }
    }

    func togglePort(_ port: Int, in list: WritableKeyPath<PortsCore.Settings, [Int]>) {
        updateSettings { s in
            if let i = s[keyPath: list].firstIndex(of: port) { s[keyPath: list].remove(at: i) } else { s[keyPath: list].append(port) }
        }
    }

    func hideGroup(_ l: Listener) {
        updateSettings { s in if !s.hiddenGroups.contains(processGroup(l)) { s.hiddenGroups.append(processGroup(l)) } }
    }

    // MARK: Containers

    func restartContainer(_ name: String, port: Int) {
        let key = "container-" + name
        guard beginStop(key) else { return }
        prompter.confirm(L("Restart container") + " “\(name)”?",
                         "What restarts: container \(name)\nHow: Engine API restart (stop, then start), else `docker restart`.",
                         button: L("Restart"), key: key, onCancel: { self.endStop(key) }) {
            var err: String?
            self.afterWork({ err = containerAction("restart", name: name) }) { fresh in
                self.endStop(key)
                if let err { return self.report(L("Couldn't restart") + " \(name)", err) }
                self.report(L("Restarted") + " \(name)", portReport(port, owners: owners(ofPort: port, in: fresh)))
            }
        }
    }

    // MARK: Ports, terminal, clients, QR

    func checkPortPrompt() {
        prompter.input(L("Check Port"), L("Which port? Ports tries to bind it on 127.0.0.1, ::1 and 0.0.0.0."), placeholder: "3000") { text in
            guard let port = Int(text), (1...65535).contains(port) else { return }
            self.afterWork({}) { fresh in self.report(checkPort(port, listeners: fresh).message) }
        }
    }

    func findFreePort() {
        prompter.input(L("Find a Free Port"), L("Start looking at which port?"), placeholder: "3000", initial: "3000") { text in
            guard let from = Int(text), (1...65535).contains(from) else { return }
            self.afterWork({}) { fresh in
                guard let p = nextFreePort(from: from, listeners: fresh) else { return self.report(L("No free port near") + " \(from)") }
                copyToPasteboard(String(p))
                self.report(L("Port") + " \(p) " + L("is free"), L("Copied to the clipboard."))
            }
        }
    }

    /// Always rescans first; several owners -> pick one.
    func killByPort() {
        prompter.input(L("Stop by Port"), L("Which port?"), placeholder: "3000") { text in
            guard let port = Int(text), (1...65535).contains(port) else { return }
            self.afterWork({}) { fresh in
                let found = owners(ofPort: port, in: fresh)
                switch found.count {
                case 0: self.report(L("Nothing is listening on port") + " \(port)")
                case 1: self.stop(found[0])
                default:
                    self.prompter.ask(InlinePrompt(title: "\(found.count) " + L("processes are listening on port") + " \(port)",
                                                   message: L("Choose which one to stop."),
                                                   buttons: found.prefix(4).map { l in
                                                       .init(title: "\(l.label) — PID \(l.pid) · \(l.addresses.joined(separator: ", "))", role: .normal) { _ in self.stop(l) }
                                                   } + [.init(title: L("Cancel"), role: .cancel) { _ in }]))
                }
            }
        }
    }

    /// Opens a visible Terminal window running the start command (never a hidden process).
    func runInTerminal(_ l: Listener) {
        let cmd = l.startCommand
        prompter.confirm(L("Run in Terminal?"), cmd + "\n\n" + L("A new Terminal window runs this command, visibly."), button: L("Run"),
                         destructive: false) {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("ports-\(UUID().uuidString.prefix(8)).command")
            do {
                try ("#!/bin/zsh\n" + cmd + "\n").write(to: url, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
            } catch { return self.report(L("Couldn't prepare the command"), "\(error)") }
            NSWorkspace.shared.open([url], withApplicationAt: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"),
                                    configuration: NSWorkspace.OpenConfiguration())
        }
    }

    func appTitle(_ path: String) -> String { ((path as NSString).lastPathComponent as NSString).deletingPathExtension }

    func open(_ url: URL, with app: String) {
        NSWorkspace.shared.open([url], withApplicationAt: URL(fileURLWithPath: app), configuration: NSWorkspace.OpenConfiguration())
    }

    /// The first time: ask which client opens this database type, and remember it.
    func chooseClient(_ db: DatabaseType, url: URL, apps: [String]) {
        prompter.ask(InlinePrompt(title: L("Open") + " \(db.title) " + L("with which app?"),
                                  message: url.absoluteString + "\n" + L("Ports remembers your choice for") + " \(db.title).",
                                  buttons: apps.prefix(4).map { app in
                                      .init(title: appTitle(app), role: .normal) { _ in
                                          self.updateSettings { $0.databaseClients[db.rawValue] = app }
                                          self.open(url, with: app)
                                      }
                                  } + [.init(title: L("Cancel"), role: .cancel) { _ in }]))
    }

    /// A QR code of the LAN URL (CoreImage), for opening the dev server on a phone.
    func showQR(_ url: URL) {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return }
        filter.setValue(Data(url.absoluteString.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let ci = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return }
        let rep = NSCIImageRep(ciImage: ci)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        image.accessibilityDescription = L("QR code for") + " " + url.absoluteString
        var p = InlinePrompt(title: L("Scan to open on a phone"), message: url.absoluteString + "\n" + L("The phone must be on the same network."),
                             buttons: [.init(title: L("Done"), role: .cancel) { _ in }])
        p.image = image
        prompter.ask(p)
    }

    // MARK: Customize (overrides)

    func customize(_ l: Listener, _ change: @escaping (inout Override) -> Void) {
        do { try overrides.update(serviceSignature(l), change) } catch { report(L("Couldn't save the change"), "\(error)") }
        refresh(full: false)
    }

    func rename(_ l: Listener) {
        prompter.input(L("Rename") + " \(l.label)", L("Shown instead of the detected name. Leave empty to reset."),
                       initial: l.override?.name ?? "", button: L("Save")) { name in
            self.customize(l) { $0.name = name.isEmpty ? nil : String(name.prefix(80)) }
        }
    }

    func note(_ l: Listener) {
        prompter.input(L("Note for") + " \(l.label)", L("Shown in the row's details."), initial: l.override?.note ?? "", button: L("Save")) { note in
            self.customize(l) { $0.note = note.isEmpty ? nil : String(note.prefix(200)) }
        }
    }

    func linkApp(_ l: Listener) {
        if l.override?.linkedApp != nil { return customize(l) { $0.linkedApp = nil } }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        customize(l) { $0.linkedApp = url.path }
    }

    // MARK: Icons

    func icon(for l: Listener) -> NSImage? {
        let source = iconSource(l)
        let key: String
        switch source { case .app(let p), .favicon(let p): key = p; case .symbol(let s): key = "sf:" + s }
        if let hit = icons[key] { return hit }
        var img: NSImage?
        switch source {
        case .app(let path): img = NSWorkspace.shared.icon(forFile: path)
        case .favicon(let path): img = NSImage(contentsOfFile: path)
        case .symbol(let name): img = NSImage(systemSymbolName: name, accessibilityDescription: l.kind.title)
        }
        // App icons and favicons carry many large representations: keep one 32 px bitmap instead.
        // App icons and favicons carry many large representations: keep one 32 px bitmap instead.
        if case .symbol = source {} else if let big = img,
           let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32, bitsPerSample: 8, samplesPerPixel: 4,
                                      hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            big.draw(in: NSRect(x: 0, y: 0, width: 32, height: 32))
            NSGraphicsContext.restoreGraphicsState()
            rep.size = NSSize(width: 16, height: 16)
            let small = NSImage(size: NSSize(width: 16, height: 16))
            small.addRepresentation(rep)
            img = small
        }
        icons[key] = img
        return img
    }

    // MARK: Doctor fixes

    func apply(_ fix: Fix) {
        switch fix {
        case .cleanUpLeftovers: cleanUp()
        case .stopOlder(let pid, let start):
            if let l = model.listeners.first(where: { $0.pid == pid && $0.start == start }) { stop(l) }
        case .openURL(let url): NSWorkspace.shared.open(url)
        }
    }
}
