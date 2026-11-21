import AppKit
import Darwin
import PortsCore

// MARK: - UI helpers

final class ActionItem: NSMenuItem {
    private var handler: () -> Void = {}
    convenience init(_ title: String, symbol: String? = nil, key: String = "",
                     mods: NSEvent.ModifierFlags = .command, _ handler: @escaping () -> Void) {
        self.init(title: title, action: #selector(fire), keyEquivalent: key)
        keyEquivalentModifierMask = mods
        target = self
        self.handler = handler
        if let symbol { image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
    }
    @objc private func fire() { handler() }
}

func infoItem(_ text: String, symbol: String? = nil) -> NSMenuItem {
    let i = NSMenuItem(title: text, action: nil, keyEquivalent: "")
    i.isEnabled = false
    if let symbol { i.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
    return i
}

/// Menu items don't wrap; split long text into lines of at most `width` characters.
func wrap(_ text: String, _ width: Int) -> [String] {
    var lines: [String] = [], line = ""
    for word in text.split(separator: " ") {
        if !line.isEmpty && line.count + word.count + 1 > width { lines.append(line); line = "" }
        line += (line.isEmpty ? "" : " ") + word
    }
    return line.isEmpty ? lines : lines + [line]
}

/// Web-probe results per process instance (pid + start time + port), shared with the scan queue.
final class WebCache: @unchecked Sendable {
    private let lock = NSLock()
    private var known: [String: WebScheme?] = [:]

    /// Fill `web` from the cache; with `probe`, probe candidates not seen before (in parallel).
    func apply(_ ls: [Listener], probe: Bool) -> [Listener] {
        func key(_ l: Listener) -> String { "\(l.pid)-\(l.start)-\(l.port)" }
        if probe {
            lock.lock(); let todo = ls.filter { isWebCandidate($0) && known[key($0)] == nil }; lock.unlock()
            var found = [WebScheme?](repeating: nil, count: todo.count)
            found.withUnsafeMutableBufferPointer { out in
                DispatchQueue.concurrentPerform(iterations: todo.count) { out[$0] = probeWeb(todo[$0]) }
            }
            lock.lock(); for (l, w) in zip(todo, found) { known[key(l)] = .some(w) }; lock.unlock()
        }
        lock.lock(); defer { lock.unlock() }
        let live = Set(ls.map(key))
        known = known.filter { live.contains($0.key) }      // forget exited processes (bounded memory)
        return ls.map { var l = $0; l.web = known[key($0)] ?? nil; return l }
    }
}

func copyToPasteboard(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}

/// Process detail rows: uptime, memory, CPU, connections, workers, launcher chain.
func detailLines(_ l: Listener) -> [(text: String, symbol: String?)] {
    var lines: [(String, String?)] = []
    var stats = [formatUptime(uptimeSeconds(start: l.start))]
    if l.memory > 0 { stats.append(formatBytes(l.memory)) }
    if let cpu = l.cpuPercent { stats.append(String(format: "%.1f%% CPU", cpu)) }
    lines.append((stats.joined(separator: " · "), "clock"))
    lines.append((l.connections == 0 ? "Idle — no open connections" : "\(l.connections) open connection\(l.connections == 1 ? "" : "s")",
                  "arrow.left.arrow.right"))
    if !l.workers.isEmpty {
        lines.append(("\(l.workers.count) worker\(l.workers.count == 1 ? "" : "s"): PID " + l.workers.map(String.init).joined(separator: ", "),
                      "square.stack.3d.up"))
    }
    if !l.chain.isEmpty {
        let chain = l.chain.prefix(6).map { "\($0.name) (\($0.pid))" }.joined(separator: " ← ")
        lines.append(("Started by " + chain + (l.chain.count > 6 ? " ← …" : ""), "arrow.turn.left.up"))
    }
    return lines
}

/// Framework, confidence, safety tier, known port and note.
func classificationLines(_ l: Listener) -> [(text: String, symbol: String?)] {
    var lines: [(String, String?)] = []
    let what = l.framework ?? l.kind.title
    lines.append(("\(what) · \(l.confidence)% confident", "checkmark.seal"))
    switch l.tier {
    case .safe: lines.append(("Dev server you started: safe to stop", "checkmark.shield"))
    case .warning: lines.append(("Stop with care: \(l.baseKind == .database ? "may lose unsaved data" : "an app, service or engine")", "exclamationmark.shield"))
    case .blocked: lines.append(("Protected: system or another user", "lock.shield"))
    }
    if KnownPorts.explanation(l) == nil, let k = KnownPorts.info(port: l.port) {
        lines.append(("Port \(l.port): \(k.owner) — \(k.explanation)", "info.circle"))
    }
    if let note = l.override?.note { lines.append(("Note: " + note, "note.text")) }
    return lines
}

// MARK: - App

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let menu = NSMenu()
    let scanQueue = DispatchQueue(label: "local.portwatch.scan", qos: .userInitiated)
    var listeners: [Listener] = []
    var docker: [Int: String] = [:]
    let web = WebCache()
    let stops = StopRegistry()
    let settingsStore = SettingsStore()
    var pausedByUs = Set<String>()                       // processKey of processes Ports paused
    let overrides = OverrideStore()
    var icons: [String: NSImage] = [:]
    var showHidden = false
    var analysis = Analysis()
    var dockerReachable: Bool?
    let localhostIPv6First = localhostPrefersIPv6()
    var stopAlerts: [String: NSWindow] = [:]     // the one open alert of each running stop flow
    var menuOpen = false
    var scanning = false
    var pendingFullRefresh = false      // the menu opened while a background scan was running
    var filter = Filter(rawValue: UserDefaults.standard.integer(forKey: "filter")) ?? .developer {
        didSet { UserDefaults.standard.set(filter.rawValue, forKey: "filter"); render() }
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        let img = NSImage(systemSymbolName: "point.3.connected.trianglepath.dotted", accessibilityDescription: "Ports")
        img?.isTemplate = true
        status.button?.image = img
        status.button?.imagePosition = .imageLeading
        status.button?.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        status.button?.toolTip = "Ports — listening ports and their PIDs"
        menu.delegate = self
        menu.autoenablesItems = false
        status.menu = menu

        refresh(withDocker: true)
        // Background poll for the badge; tolerance lets macOS coalesce wake-ups (saves energy).
        let timer = Timer(timeInterval: 10, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh(withDocker: false) }
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
    }

    /// Scan in the background, then apply on the main thread (also while the menu is open).
    func refresh(withDocker: Bool) {
        guard !scanning else { if withDocker { pendingFullRefresh = true }; return }
        scanning = true
        let cachedDocker = docker, cachedReachable = dockerReachable
        let probe = withDocker && menuOpen          // web probes run only while the menu is open
        let ipv6First = localhostIPv6First
        scanQueue.async {
            // Menu open: query containers in this same scan. Background poll: reuse the last map —
            // scan() only applies it to container-runtime proxies, so a native process never inherits it.
            var map = cachedDocker, reachable = cachedReachable
            // CPU % is sampled only while the menu is open, on the scan whose result is shown.
            var result = scan(docker: [:])
            // Engines are asked only when a runtime's proxy listens: every open-menu scan, else at most every 15 s
            // (or at once when the proxy listeners change).
            let snap = ContainerDirectory.shared.current(listeners: result, maxAge: withDocker ? 0 : 15)
            map = snap?.namesByPort ?? [:]
            reachable = snap?.reachable
            if snap != nil || probe {
                result = scan(docker: map, containers: snap?.byPort ?? [:], sampleCPU: probe)
            }
            _ = cachedDocker
            result = applyOverrides(self.web.apply(result, probe: probe), self.overrides)
            // Orphans, duplicates and Doctor. launchctl and the leftover sweep run only while the menu is open.
            var input = DoctorInput()
            input.dockerReachable = reachable
            input.localhostIPv6First = ipv6First
            // Verdicts need the launchd job list, which is read only while the menu is open, so a closed-menu
            // scan keeps the last analysis instead of guessing.
            let a: Analysis? = probe ? analyze(result, starred: self.overrides.starred, includeLeftovers: true, doctor: input) : nil
            RunLoop.main.perform(inModes: [.common]) {
                MainActor.assumeIsolated {
                    self.scanning = false
                    defer {
                        if self.pendingFullRefresh { self.pendingFullRefresh = false; self.refresh(withDocker: true) }
                    }
                    self.docker = map
                    self.dockerReachable = reachable
                    var changed = result != self.listeners
                    if let a {
                        changed = changed || a.issues != self.analysis.issues || a.leftovers != self.analysis.leftovers
                            || a.verdicts != self.analysis.verdicts
                        self.analysis = a
                    }
                    guard changed else { return }                      // nothing changed: don't touch the UI
                    self.listeners = result
                    self.render()
                }
            }
        }
    }

    func render() {
        let n = listeners.filter { $0.kind.isDeveloper && $0.override?.hidden != true }.count
        status.button?.title = n > 0 ? " \(n)" : ""
        if menuOpen || menu.items.isEmpty { build() }
    }

    func menuWillOpen(_ menu: NSMenu) {
        menuOpen = true
        build()                       // instant, from cache
        refresh(withDocker: true)     // then fresh data swaps in if anything changed
    }
    func menuDidClose(_ menu: NSMenu) { menuOpen = false }

    func build() {
        menu.removeAllItems()
        let hiddenCount = listeners.filter { $0.override?.hidden == true }.count
        let shown = listeners.filter {
            if $0.override?.hidden == true && !showHidden { return false }
            return switch filter { case .developer: showsInDeveloperView($0); case .system: !$0.kind.isDeveloper; case .all: true }
        }

        let show = NSMenuItem(title: "Show: " + ["Developer", "Apps & System", "All"][filter.rawValue], action: nil, keyEquivalent: "")
        show.image = NSImage(systemSymbolName: "line.3.horizontal.decrease.circle", accessibilityDescription: nil)
        let sub = NSMenu()
        for (f, name, key) in [(Filter.developer, "Developer — servers, databases, containers, tunnels, AI", "1"),
                               (.system, "Apps, services & system", "2"), (.all, "All", "3")] {
            let item = ActionItem(name, key: key) { [weak self] in self?.filter = f }
            item.state = filter == f ? .on : .off
            sub.addItem(item)
        }
        show.submenu = sub
        menu.addItem(show)

        if !analysis.issues.isEmpty {
            menu.addItem(.separator())
            menu.addItem(NSMenuItem.sectionHeader(title: "Health · \(analysis.issues.count)"))
            for issue in analysis.issues.prefix(8) { menu.addItem(issueItem(issue)) }
        }
        if shown.isEmpty {
            menu.addItem(.separator())
            menu.addItem(infoItem(filter == .developer ? "No dev servers running" : "Nothing listening", symbol: "checkmark.circle"))
        }
        let favorites = shown.filter { $0.override?.favorite == true }
        if !favorites.isEmpty {
            menu.addItem(.separator())
            menu.addItem(NSMenuItem.sectionHeader(title: "Favorites · \(favorites.count)"))
            for l in favorites { menu.addItem(row(l)) }
        }
        for kind in Kind.allCases {
            let rows = shown.filter { $0.kind == kind && $0.override?.favorite != true }
            guard !rows.isEmpty else { continue }
            menu.addItem(.separator())
            menu.addItem(NSMenuItem.sectionHeader(title: "\(kind.title) · \(rows.count)"))
            for l in rows { menu.addItem(row(l)) }
        }

        if !analysis.leftovers.isEmpty {
            menu.addItem(.separator())
            menu.addItem(NSMenuItem.sectionHeader(title: "Leftovers · \(analysis.leftovers.count)"))
            for left in analysis.leftovers { menu.addItem(leftoverItem(left)) }
        }
        menu.addItem(.separator())
        if let snap = ContainerDirectory.shared.last {
            let running = snap.containers.filter { $0.state == "running" }.count
            let names = snap.answered.isEmpty ? (snap.viaCLI ? "docker CLI" : "not answering") : snap.answered.map(\.name).joined(separator: ", ")
            menu.addItem(infoItem("Containers: \(names) · \(running) running", symbol: "shippingbox"))
        }
        let cleanable = cleanupCandidates()
        let clean = ActionItem("Clean Up Leftovers…", symbol: "sparkles", key: "") { [weak self] in self?.cleanUp() }
        clean.isEnabled = !cleanable.isEmpty
        menu.addItem(clean)
        menu.addItem(ActionItem("Copy Setup Prompt for AI", symbol: "text.bubble", key: "") { [weak self] in
            guard let self else { return }
            copyToPasteboard(aiSetupPrompt(self.listeners))
        })
        if hiddenCount > 0 {
            let toggle = ActionItem(showHidden ? "Hide Hidden Rows" : "Show Hidden (\(hiddenCount))", symbol: "eye", key: "") {
                [weak self] in self?.showHidden.toggle(); self?.build()
            }
            menu.addItem(toggle)
        }
        menu.addItem(ActionItem("Check Port…", symbol: "magnifyingglass", key: "") { [weak self] in self?.checkPortPrompt() })
        menu.addItem(ActionItem("Find Free Port…", symbol: "number.circle", key: "") { [weak self] in self?.findFreePort() })
        menu.addItem(ActionItem("Stop Several…", symbol: "checklist", key: "") { [weak self] in self?.stopSeveral() })
        menu.addItem(ActionItem("Kill by Port…", symbol: "number", key: "k") { [weak self] in self?.killByPort() })
        menu.addItem(ActionItem("Kill by PID…", symbol: "xmark.circle", key: "k", mods: [.command, .shift]) { [weak self] in self?.killByPID() })
        menu.addItem(.separator())
        menu.addItem(ActionItem("Quit Ports", key: "q") { NSApp.terminate(nil) })
    }

    func row(_ l: Listener) -> NSMenuItem {
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        item.image = icon(for: l)
        let label = l.label.count > 40 ? String(l.label.prefix(39)) + "…" : l.label
        let text = NSMutableAttributedString(string: ":\(l.port)".padding(toLength: 7, withPad: " ", startingAt: 0),
                                             attributes: [.font: NSFont.monospacedSystemFont(ofSize: 13, weight: .semibold)])
        text.append(NSAttributedString(string: label, attributes: [.font: NSFont.menuFont(ofSize: 13)]))
        text.append(NSAttributedString(string: "   PID \(l.pid)", attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular), .foregroundColor: NSColor.secondaryLabelColor]))
        if l.exposed {
            text.append(NSAttributedString(string: "  LAN", attributes: [
                .font: NSFont.systemFont(ofSize: 10, weight: .bold), .foregroundColor: NSColor.systemOrange]))
        }
        if let v = analysis.verdict(l), v.level >= .likely {
            text.append(NSAttributedString(string: "  ORPHAN", attributes: [
                .font: NSFont.systemFont(ofSize: 10, weight: .bold), .foregroundColor: NSColor.systemPurple]))
        }
        if analysis.isDuplicate(l) {
            text.append(NSAttributedString(string: "  TWICE", attributes: [
                .font: NSFont.systemFont(ofSize: 10, weight: .bold), .foregroundColor: NSColor.systemBlue]))
        }
        if !l.workers.isEmpty {
            text.append(NSAttributedString(string: "  ×\(l.workers.count + 1)", attributes: [
                .font: NSFont.systemFont(ofSize: 10, weight: .bold), .foregroundColor: NSColor.secondaryLabelColor]))
        }
        if l.stopped {
            text.append(NSAttributedString(string: pausedByUs.contains(processKey(l)) ? "  PAUSED" : "  STOPPED", attributes: [
                .font: NSFont.systemFont(ofSize: 10, weight: .bold), .foregroundColor: NSColor.systemYellow]))
        }
        item.attributedTitle = text
        item.toolTip = tilde(l.command)

        let sub = NSMenu()
        sub.addItem(infoItem("PID \(l.pid)", symbol: "number"))
        let bound = l.addresses.joined(separator: ", ")      // this process's own binds, not the port's union
        sub.addItem(infoItem(l.exposed ? "Reachable from your network (\(bound))" : "Local only (\(bound))",
                             symbol: l.exposed ? "wifi.exclamationmark" : "lock"))
        if let why = KnownPorts.explanation(l) {
            for line in wrap(why, 60) { sub.addItem(infoItem(line, symbol: line == wrap(why, 60).first ? "info.circle" : nil)) }
        }
        if l.stopped {
            sub.addItem(infoItem("Stopped (suspended) — holds the port but answers nothing", symbol: "pause.circle"))
        }
        if let p = l.project { sub.addItem(infoItem(p.displayWithBranch, symbol: "folder.badge.gearshape")) }
        if !l.cwd.isEmpty && l.cwd != "/" { sub.addItem(infoItem(tilde(l.cwd), symbol: "folder")) }
        let cmd = tilde(l.command)
        sub.addItem(infoItem(cmd.count > 90 ? String(cmd.prefix(89)) + "…" : cmd, symbol: "terminal"))
        for line in detailLines(l) { sub.addItem(infoItem(line.text, symbol: line.symbol)) }
        for line in classificationLines(l) { sub.addItem(infoItem(line.text, symbol: line.symbol)) }
        for line in containerLines(l) { for (i, w) in wrap(line.text, 70).enumerated() { sub.addItem(infoItem(w, symbol: i == 0 ? line.symbol : nil)) } }
        for line in verdictLines(l) { for (i, w) in wrap(line.text, 70).enumerated() { sub.addItem(infoItem(w, symbol: i == 0 ? line.symbol : nil)) } }
        sub.addItem(.separator())
        if let link = KnownPorts.settingsAction(l) {           // the fix that frees the port: listed first
            sub.addItem(ActionItem(link.title, symbol: "gearshape", key: "") { NSWorkspace.shared.open(link.url) })
        }
        if let scheme = l.web, let url = browserURL(l, scheme) {
            sub.addItem(ActionItem("Open in Browser", symbol: "safari", key: "") { NSWorkspace.shared.open(url) })
        }
        if !l.cwd.isEmpty && l.cwd != "/" {
            sub.addItem(ActionItem("Show Folder in Finder", symbol: "folder", key: "") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: l.cwd)])
            })
        }
        sub.addItem(ActionItem("Copy PID", symbol: "doc.on.doc", key: "") { copyToPasteboard("\(l.pid)") })
        if l.uid == getuid() && !l.argv.isEmpty {
            sub.addItem(ActionItem("Copy Start Command", symbol: "doc.on.clipboard", key: "") { copyToPasteboard(l.startCommand) })
        }
        sub.addItem(.separator())
        if let older = analysis.olderInstance(of: l) {
            sub.addItem(ActionItem("Stop the Older One (:\(older.port), PID \(older.pid))…", symbol: "clock.arrow.circlepath", key: "") {
                [weak self] in self?.stop(older)
            })
        }
        if let c = l.container, l.uid == getuid() || l.containerInfo != nil {
            sub.addItem(ActionItem("Restart Container “\(c)”…", symbol: "arrow.clockwise.circle", key: "") { [weak self] in
                self?.restartContainer(c, port: l.port) })
            sub.addItem(ActionItem("Copy “\(logsCommand(c))”", symbol: "doc.on.clipboard", key: "") { copyToPasteboard(logsCommand(c)) })
        }
        if KnownPorts.restartsAutomatically(l) {
            sub.addItem(infoItem("macOS restarts this immediately — stopping it won't free the port", symbol: "arrow.clockwise"))
        } else if l.uid != getuid() {
            sub.addItem(infoItem("Owned by the system — can't stop", symbol: "lock.shield"))
        } else {
            let title = l.container.map { "Stop Container “\($0)”…" } ?? (l.baseKind == .database ? "Shut Down…" : "Stop…")
            sub.addItem(ActionItem(title, symbol: "xmark.octagon", key: "") { [weak self] in self?.stop(l) })
            if l.container == nil {
                if !l.workers.isEmpty {
                    sub.addItem(ActionItem("Stop All \(l.workers.count + 1) Workers…", symbol: "square.stack.3d.up.slash", key: "") {
                        [weak self] in self?.stopTree(l) })
                } else {
                    sub.addItem(ActionItem("Stop Process and Its Children…", symbol: "arrow.triangle.branch", key: "") {
                        [weak self] in self?.stopTree(l) })
                }
                let ports = listeners.filter { $0.pid == l.pid && $0.start == l.start }.map(\.port)
                if ports.count > 1 {
                    sub.addItem(infoItem("Stopping it frees all its ports: " + ports.sorted().map { ":\($0)" }.joined(separator: ", "),
                                         symbol: "number"))
                }
                sub.addItem(l.stopped
                    ? ActionItem("Resume", symbol: "play.circle", key: "") { [weak self] in self?.setPaused(l, false) }
                    : ActionItem("Pause", symbol: "pause.circle", key: "") { [weak self] in self?.setPaused(l, true) })
                if !l.argv.isEmpty {
                    sub.addItem(ActionItem("Run Start Command in Terminal…", symbol: "terminal", key: "") { [weak self] in self?.runInTerminal(l) })
                }
            }
            if l.port > 0 {
                let protected = settingsStore.settings.isProtected(l.port)
                let item = ActionItem("Protect Port :\(l.port)", symbol: "lock", key: "") { [weak self] in self?.toggleProtected(l.port) }
                item.state = protected ? .on : .off
                sub.addItem(item)
            }
        }
        sub.addItem(.separator())
        sub.addItem(customizeItem(l))
        item.submenu = sub
        return item
    }

    // MARK: Overrides and icons

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
        if case .symbol = source {} else { img?.size = NSSize(width: 16, height: 16) }
        img?.accessibilityDescription = l.kind.title
        icons[key] = img
        return img
    }

    func customize(_ l: Listener, _ change: @escaping (inout Override) -> Void) {
        do { try overrides.update(serviceSignature(l), change) } catch { alert("Couldn't save the change", "\(error)") }
        refresh(withDocker: false)
    }

    func customizeItem(_ l: Listener) -> NSMenuItem {
        let o = l.override ?? Override()
        let item = NSMenuItem(title: "Customize", action: nil, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: nil)
        let m = NSMenu()
        m.addItem(ActionItem("Rename…", symbol: "pencil", key: "") { [weak self] in
            guard let name = self?.textPrompt("Rename \(l.label)", "Shown instead of the detected name. Leave empty to reset.",
                                               initial: o.name ?? "") else { return }
            self?.customize(l) { $0.name = name.isEmpty ? nil : name }
        })
        let move = NSMenuItem(title: "Move to", action: nil, keyEquivalent: "")
        move.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        let kinds = NSMenu()
        for k in Kind.allCases {
            let i = ActionItem(k.title, key: "") { [weak self] in self?.customize(l) { $0.kind = k == l.baseKind ? nil : k } }
            i.state = l.kind == k ? .on : .off
            kinds.addItem(i)
        }
        move.submenu = kinds
        m.addItem(move)
        m.addItem(ActionItem("Note…", symbol: "note.text", key: "") { [weak self] in
            guard let note = self?.textPrompt("Note for \(l.label)", "Shown in the row's details.", initial: o.note ?? "") else { return }
            self?.customize(l) { $0.note = note.isEmpty ? nil : note }
        })
        m.addItem(ActionItem(o.linkedApp == nil ? "Link to App…" : "Unlink App", symbol: "link", key: "") { [weak self] in
            if o.linkedApp != nil { self?.customize(l) { $0.linkedApp = nil }; return }
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.application]
            panel.directoryURL = URL(fileURLWithPath: "/Applications")
            NSApp.activate()
            guard panel.runModal() == .OK, let url = panel.url else { return }
            self?.customize(l) { $0.linkedApp = url.path }
        })
        m.addItem(.separator())
        for (title, symbol, flag) in [("Favorite", "star", \Override.favorite), ("Hide", "eye.slash", \Override.hidden),
                                      ("Mute Notifications", "bell.slash", \Override.muted),
                                      ("Star (Never Flag as Orphan)", "star.circle", \Override.starred)] {
            let i = ActionItem(title, symbol: symbol, key: "") { [weak self] in self?.customize(l) { $0[keyPath: flag].toggle() } }
            i.state = o[keyPath: flag] ? .on : .off
            m.addItem(i)
        }
        if !o.isEmpty {
            m.addItem(.separator())
            m.addItem(ActionItem("Reset Customizations", symbol: "arrow.uturn.backward", key: "") { [weak self] in
                self?.customize(l) { $0 = Override() }
            })
        }
        item.submenu = m
        return item
    }

    func containerLines(_ l: Listener) -> [(text: String, symbol: String?)] {
        guard let c = l.containerInfo else { return [] }
        var lines: [(String, String?)] = []
        lines.append(("Container \(c.name)\(c.id.isEmpty ? "" : " (\(c.id.prefix(12)))") · \(c.image.isEmpty ? "image unknown" : c.image)", "shippingbox"))
        if let p = c.project { lines.append(("Compose: \(p)\(c.service.map { " / " + $0 } ?? "")", "square.stack.3d.up")) }
        if !c.status.isEmpty { lines.append(("\(c.status)\(c.runtime.map { " · " + $0.name } ?? "")", "heart.text.square")) }
        let published = c.ports.filter { $0.publicPort == l.port }
            .map { "\($0.ip.isEmpty ? "0.0.0.0" : $0.ip):\($0.publicPort) → \($0.privatePort)/\($0.proto)" }
        if !published.isEmpty { lines.append(("Published " + published.joined(separator: ", "), "arrow.right.circle")) }
        if c.publishedOnAllInterfaces(l.port) {
            let priv = c.ports.first { $0.publicPort == l.port }?.privatePort ?? l.port
            lines.append(("⚠️ Published on all interfaces: use 127.0.0.1:\(l.port):\(priv) to keep it local", nil))
        }
        return lines
    }

    func restartContainer(_ name: String, port: Int) {
        let key = "container-" + name
        guard beginStop(key) else { return }
        guard confirm("Restart container “\(name)”?", "What restarts: container \(name)\nHow: Engine API restart (stop, then start), else `docker restart`.",
                      button: "Restart", key: key) else { return endStop(key) }
        var err: String?
        afterWork({ err = containerAction("restart", name: name) }) { fresh in
            self.endStop(key)
            if let err { return self.alert("Couldn't restart \(name)", err) }
            self.alert("Restarted \(name)", portReport(port, owners: owners(ofPort: port, in: fresh)))
        }
    }

    // MARK: Health, orphans and clean-up

    func verdictLines(_ l: Listener) -> [(text: String, symbol: String?)] {
        var lines: [(String, String?)] = []
        if let s = analysis.starter(l) {
            lines.append(("Started by: " + (s.pid.map { "\(s.name) (PID \($0))" } ?? s.name)
                          + (s.kind == .unknown ? "" : " · \(s.kind.title)"), "person.crop.circle"))
        }
        if let v = analysis.verdict(l) {
            let dot = ["green": "🟢", "yellow": "🟡", "red": "🔴"][v.safeToStop.rawValue] ?? ""
            lines.append(("\(dot) Safe to stop? \(v.safeToStop.title) · \(v.level.title)", "questionmark.circle"))
            for e in v.evidence { lines.append(("• " + e, nil)) }
        }
        return lines
    }

    func issueItem(_ issue: Issue) -> NSMenuItem {
        let symbol = ["info.circle", "exclamationmark.triangle", "exclamationmark.octagon"][issue.severity.rawValue]
        let item = NSMenuItem(title: issue.title, action: nil, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: issue.severity.title)
        let sub = NSMenu()
        for (i, line) in wrap(issue.explanation, 70).enumerated() { sub.addItem(infoItem(line, symbol: i == 0 ? "text.alignleft" : nil)) }
        if let title = issue.fixTitle, let fix = issue.fix {
            sub.addItem(.separator())
            sub.addItem(ActionItem(title, symbol: "wrench.and.screwdriver", key: "") { [weak self] in self?.apply(fix) })
        }
        item.submenu = sub
        return item
    }

    func apply(_ fix: Fix) {
        switch fix {
        case .cleanUpLeftovers: cleanUp()
        case .stopOlder(let pid, let start):
            if let l = listeners.first(where: { $0.pid == pid && $0.start == start }) { stop(l) }
        case .openURL(let url): NSWorkspace.shared.open(url)
        }
    }

    func leftoverItem(_ left: Leftover) -> NSMenuItem {
        let p = left.process
        let item = NSMenuItem(title: "\(left.tool)\(p.project.map { " · " + $0.display } ?? "")   PID \(p.pid)  ORPHAN",
                              action: nil, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: "leaf", accessibilityDescription: "Leftover")
        item.toolTip = tilde(p.command)
        let sub = NSMenu()
        sub.addItem(infoItem(tilde(p.command).prefix(90).description, symbol: "terminal"))
        for e in left.verdict.evidence { for (i, w) in wrap(e, 70).enumerated() { sub.addItem(infoItem((i == 0 ? "• " : "  ") + w)) } }
        sub.addItem(.separator())
        sub.addItem(ActionItem("Stop…", symbol: "xmark.octagon", key: "") { [weak self] in self?.confirmKill(p) })
        item.submenu = sub
        return item
    }

    /// Confirmed orphans (checked by default) and likely ones (opt-in), listeners and leftovers alike.
    func cleanupCandidates() -> [(l: Listener, checked: Bool, why: String)] {
        var out: [(Listener, Bool, String)] = []
        for l in listeners where l.uid == getuid() {
            guard let v = analysis.verdict(l), v.level >= .likely else { continue }
            out.append((l, v.level == .confirmed, v.evidence.first ?? ""))
        }
        for left in analysis.leftovers { out.append((left.process, true, left.verdict.evidence.first ?? "")) }
        return out
    }

    /// The one modal confirmation the spec allows: lists exactly what will be signalled, then runs the safe ladder.
    func cleanUp() {
        let candidates = cleanupCandidates()
        guard !candidates.isEmpty else { alert("Nothing to clean up", "No orphaned processes were found."); return }
        NSApp.activate()
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = "Clean up \(candidates.count) orphaned process\(candidates.count == 1 ? "" : "es")?"
        a.informativeText = "Each checked process gets SIGTERM (SIGCONT too if it is suspended) and time to exit. "
            + "Only dev servers are force-killed (SIGKILL) if they don't exit within 2 s; anything else that keeps "
            + "running is reported, never force-killed. Likely orphans are unchecked: tick them to include them."
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        var boxes: [NSButton] = []
        for c in candidates {
            let port = c.l.port > 0 ? ":\(c.l.port) " : ""
            let box = NSButton(checkboxWithTitle: "\(port)\(c.l.label) — PID \(c.l.pid) · \(StopPolicy(c.l).autoForce ? "SIGTERM, SIGKILL after 2 s" : "SIGTERM only")",
                               target: nil, action: nil)
            box.state = c.checked ? .on : .off
            box.toolTip = c.why
            boxes.append(box)
            stack.addArrangedSubview(box)
        }
        stack.frame = NSRect(x: 0, y: 0, width: 460, height: CGFloat(boxes.count) * 22)
        a.accessoryView = stack
        a.addButton(withTitle: "Clean Up").hasDestructiveAction = true
        a.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let targets = zip(candidates, boxes).filter { $0.1.state == .on }.map { StopTarget($0.0.l) }
        guard !targets.isEmpty else { return }
        var outcomes: [StopOutcome] = []
        afterWork({ outcomes = stopAll(targets, registry: self.stops) }) { fresh in
            let ports = candidates.map(\.l.port).filter { $0 > 0 }
            let report = (outcomes.map(\.summary) + Set(ports).sorted().map { portReport($0, owners: owners(ofPort: $0, in: fresh)) })
                .joined(separator: "\n")
            self.alert("Clean-up finished", report)
        }
    }

    // MARK: Actions

    /// Run `work` off the main thread, then hand a fresh scan (with container labels) back to the UI.
    func afterWork(_ work: @escaping () -> Void, then done: @escaping ([Listener]) -> Void) {
        scanQueue.async {
            work()
            let fresh = applyOverrides(self.web.apply(scanWithContainers(), probe: false), self.overrides)
            let a = analyze(fresh, starred: self.overrides.starred, includeLeftovers: true)
            RunLoop.main.perform(inModes: [.common]) {
                MainActor.assumeIsolated {
                    self.analysis = a
                    if fresh != self.listeners { self.listeners = fresh }
                    self.render()
                    done(fresh)
                }
            }
        }
    }

    /// Claim the stop flow for `key`. If one is already running, bring its alert forward instead.
    func beginStop(_ key: String) -> Bool {
        if stops.claim(key) { return true }
        if let w = stopAlerts[key] { NSApp.activate(); w.makeKeyAndOrderFront(nil) } else { NSSound.beep() }
        return false
    }

    func endStop(_ key: String) {
        stops.release(key)
        stopAlerts[key] = nil
    }

    /// Close any other alert still open for this process (e.g. after Force Quit).
    func closeStopAlert(_ key: String) {
        guard let w = stopAlerts.removeValue(forKey: key) else { return }
        if NSApp.modalWindow == w { NSApp.abortModal() }
        w.orderOut(nil)
    }

    func confirmKill(_ l: Listener) {
        let key = StopRegistry.key(pid: l.pid, start: l.start)
        guard beginStop(key) else { return }
        let policy = StopPolicy(l)
        var detail = (l.port > 0 ? "Port \(l.port) · " : "") + "PID \(l.pid)\n\(tilde(l.command))"
        if let warning = policy.warning { detail += "\n\n⚠️ " + warning }
        if l.kind == .system { detail += "\n\nThis is an app or system process. Stopping it may close an app." }
        if l.kind == .docker { detail += "\n\nThis is the container engine. Stopping it stops ALL containers." }
        guard confirm("Stop \(l.label)?", detail, button: policy == .dataStore ? "Shut Down" : "Kill", key: key) else {
            return endStop(key)
        }
        stop(pid: l.pid, start: l.start, policy: policy, ports: l.port > 0 ? [l.port] : [], name: l.label)
    }

    /// Stop ladder, then rescan and report each port. Data stores are never force-killed here:
    /// if one is still running, Force is offered as its own explicit step. Caller holds the stop claim.
    func stop(pid: pid_t, start: UInt64, policy: StopPolicy, ports: [Int], name: String) {
        let key = StopRegistry.key(pid: pid, start: start)
        var err: KillError?
        afterWork({ err = safeTerminate(pid: pid, start: start, policy: policy) }) { fresh in
            if let err { self.alert("Couldn't stop PID \(pid)", err.description, key: key); return self.endStop(key) }
            let survived = ports.isEmpty ? Proc.identity(pid)?.start == start : fresh.contains { $0.pid == pid && $0.start == start }
            let report = ports.isEmpty ? (survived ? "\(name) (PID \(pid)) is still running" : "\(name) (PID \(pid)) stopped")
                : ports.map { portReport($0, owners: owners(ofPort: $0, in: fresh)) }.joined(separator: "\n")
            guard survived && !policy.autoForce else { self.alert(report, "", key: key); return self.endStop(key) }
            guard self.confirm("\(name) is still running", report + "\n\nIt didn't shut down within \(Int(policy.grace)) s. "
                               + "Force Quit kills it immediately (SIGKILL) and may lose unsaved data.",
                               button: "Force Quit", key: key) else { return self.endStop(key) }
            var forceErr: KillError?
            self.afterWork({ forceErr = forceKill(pid: pid, start: start) }) { fresh in
                self.closeStopAlert(key)
                if let forceErr { self.alert("Couldn't force quit PID \(pid)", forceErr.description, key: key) }
                else {
                    let report = ports.map { portReport($0, owners: owners(ofPort: $0, in: fresh)) }.joined(separator: "\n")
                    self.alert(report.isEmpty ? "\(name) (PID \(pid)) was force-quit" : report, "", key: key)
                }
                self.endStop(key)
            }
        }
    }

    func stopContainer(_ name: String, port: Int) {
        guard let docker = dockerPath, isSafeContainerName(name) else { return }
        let key = "container-" + name
        guard beginStop(key) else { return }
        var l = Listener(port: port, pid: 0, start: 0, uid: getuid(), exposed: false, exe: "", command: name, cwd: "")
        l.label = "container \(name)"
        guard confirm("Stop container “\(name)”?", confirmation(.container(name: name), for: l).text,
                      button: "Stop", key: key) else { return endStop(key) }
        var res = (out: "", ok: true)
        afterWork({ res = run(docker, ["stop", "--", name], timeout: 20) }) { fresh in
            if !res.ok { self.alert("Couldn't stop \(name)", res.out, key: key) }
            else { self.alert(portReport(port, owners: owners(ofPort: port, in: fresh)), "", key: key) }
            self.endStop(key)
        }
    }

    /// Stop through whatever supervises it. The confirmation states what stops, how, whether it restarts,
    /// and whether the change survives the next login; protected ports need their number typed in.
    func stop(_ l: Listener) {
        if KnownPorts.restartsAutomatically(l) { return explainRestart(l) }
        let key = StopRegistry.key(pid: l.pid, start: l.start)
        guard beginStop(key) else { return }
        let s = analysis.starter(l) ?? starter(of: l.chain, isLaunchdJob: false)
        var methods: [StopMethod] = []
        scanQueue.async {
            methods = stopMethods(l, starter: s, ctx: supervisorContext(for: l, starter: s))
            RunLoop.main.perform(inModes: [.common]) { MainActor.assumeIsolated { self.offer(methods, for: l, key: key) } }
        }
    }

    func stopTree(_ l: Listener) {
        let key = StopRegistry.key(pid: l.pid, start: l.start)
        guard beginStop(key) else { return }
        var methods: [StopMethod] = []
        scanQueue.async {
            methods = [.tree(treeTargets(root: StopTarget(l)))]
            RunLoop.main.perform(inModes: [.common]) { MainActor.assumeIsolated { self.offer(methods, for: l, key: key) } }
        }
    }

    func offer(_ methods: [StopMethod], for l: Listener, key: String) {
        if methods.count == 1, case .explain(let why) = methods[0] {
            endStop(key); return alert("Ports won't stop \(l.label)", why)
        }
        let settings = settingsStore.settings
        if settings.isProtected(l.port) {
            guard let typed = textPrompt("Port :\(l.port) is protected", "Type \(l.port) to stop \(l.label).", initial: ""),
                  confirmsProtectedPort(typed, port: l.port) else { endStop(key); return }
        }
        let actions = methods.filter { if case .explain = $0 { return false }; return true }.prefix(3)
        var text = actions.map { confirmation($0, for: l).text }.joined(separator: "\n\n")
        if let warning = StopPolicy(l).warning { text += "\n\n⚠️ " + warning }
        if l.baseKind == .docker && l.container == nil { text += "\n\n⚠️ This is the container engine. Stopping it stops ALL containers." }
        let offerForce = RecentStops.shared.isRecent(key)
        if offerForce { text += "\n\nYou asked to stop it less than 2 minutes ago. Force Quit (SIGKILL) ends it now." }
        NSApp.activate()
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = "Stop \(l.label)?"
        a.informativeText = text
        for m in actions { a.addButton(withTitle: confirmation(m, for: l).title).hasDestructiveAction = true }
        if offerForce { a.addButton(withTitle: "Force Quit").hasDestructiveAction = true }
        a.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
        let choice = present(a, key: key).rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        if choice >= 0 && choice < actions.count { return perform(actions[actions.index(actions.startIndex, offsetBy: choice)], for: l, key: key) }
        if offerForce && choice == actions.count { return forceNow(l, key: key) }
        endStop(key)
    }

    func perform(_ m: StopMethod, for l: Listener, key: String) {
        RecentStops.shared.record(key)
        let ports = l.port > 0 ? [l.port] : []
        switch m {
        case .signal(let t):
            stop(pid: t.pid, start: t.start, policy: t.policy, ports: ports, name: l.label)   // keeps the claim
        case .app(let bundle, let pid):
            endStop(key)
            let app = NSWorkspace.shared.runningApplications.first { $0.bundleURL?.path == bundle }
            guard let app, app.terminate() else { return alert("Couldn't ask \((bundle as NSString).lastPathComponent) to quit", "It may not be running.") }
            afterWork({
                for _ in 0..<100 where Proc.identity(pid)?.start == l.start { usleep(100_000) }   // up to 10 s to quit
            }) { fresh in
                self.alert(ports.isEmpty ? "\((bundle as NSString).lastPathComponent) quit" : portReport(l.port, owners: owners(ofPort: l.port, in: fresh)), "")
            }
        default:
            endStop(key)
            var err: SupervisorError?
            afterWork({ err = execute(m, registry: self.stops) }) { fresh in
                if let err { return self.alert("Couldn't stop \(l.label)", err.description) }
                self.alert(ports.isEmpty ? "\(l.label) stopped" : portReport(l.port, owners: owners(ofPort: l.port, in: fresh)), "")
            }
        }
    }

    func forceNow(_ l: Listener, key: String) {
        var err: KillError?
        afterWork({ err = forceKill(pid: l.pid, start: l.start) }) { fresh in
            self.endStop(key)
            if let err { return self.alert("Couldn't force quit PID \(l.pid)", err.description) }
            self.alert(l.port > 0 ? portReport(l.port, owners: owners(ofPort: l.port, in: fresh)) : "PID \(l.pid) was force-quit", "")
        }
    }

    func setPaused(_ l: Listener, _ paused: Bool) {
        var err: KillError?
        let key = processKey(l)
        afterWork({ err = paused ? pause(pid: l.pid, start: l.start) : resume(pid: l.pid, start: l.start) }) { _ in
            if let err { return self.alert("Couldn't \(paused ? "pause" : "resume") PID \(l.pid)", err.description) }
            if paused { self.pausedByUs.insert(key) } else { self.pausedByUs.remove(key) }
            self.build()
        }
    }

    func toggleProtected(_ port: Int) {
        do {
            try settingsStore.update { s in
                if let i = s.protectedPorts.firstIndex(of: port) { s.protectedPorts.remove(at: i) } else { s.protectedPorts.append(port) }
            }
        } catch { alert("Couldn't save the setting", "\(error)") }
        build()
    }

    /// Opens a visible Terminal window running the start command (never in the background).
    func runInTerminal(_ l: Listener) {
        let cmd = l.startCommand
        guard confirm("Run in Terminal?", cmd + "\n\nA new Terminal window runs this command, visibly.", button: "Run") else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ports-\(UUID().uuidString.prefix(8)).command")
        do {
            try ("#!/bin/zsh\n" + cmd + "\n").write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        } catch { return alert("Couldn't prepare the command", "\(error)") }
        let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        NSWorkspace.shared.open([url], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
    }

    func checkPortPrompt() {
        guard let text = prompt("Check Port", "Which port? Ports tries to bind it on 127.0.0.1, ::1 and 0.0.0.0."),
              let port = Int(text), (1...65535).contains(port) else { return }
        var check: PortCheck?
        afterWork({}) { fresh in
            check = checkPort(port, listeners: fresh)
            self.alert(check!.message, "")
        }
    }

    func findFreePort() {
        guard let text = prompt("Find a Free Port", "Start looking at which port? (e.g. 3000)"),
              let from = Int(text), (1...65535).contains(from) else { return }
        afterWork({}) { fresh in
            guard let p = nextFreePort(from: from, listeners: fresh) else {
                return self.alert("No free port near \(from)", "Nothing between \(from) and \(from + 1000) can be bound.")
            }
            copyToPasteboard(String(p))
            self.alert("Port \(p) is free", "Copied \(p) to the clipboard.")
        }
    }

    /// Multi-select stop: one confirmation listing every process and its signals; protected ports are left out.
    func stopSeveral() {
        let settings = settingsStore.settings
        let candidates = listeners.filter { l in
            l.uid == getuid() && l.container == nil && !KnownPorts.restartsAutomatically(l) && l.baseKind != .system
                && !settings.isProtected(l.port)
        }
        guard !candidates.isEmpty else { return alert("Nothing to stop", "No processes of yours can be stopped together.") }
        NSApp.activate()
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = "Stop several processes"
        a.informativeText = "Each checked process gets SIGTERM (and SIGCONT if suspended). Only dev servers are force-killed, "
            + "after 2 s; nothing restarts them unless a supervisor does (use each row's Stop… for those). Protected ports aren't listed."
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        var boxes: [NSButton] = []
        for l in candidates {
            let b = NSButton(checkboxWithTitle: ":\(l.port) \(l.label) — PID \(l.pid) · \(StopPolicy(l).autoForce ? "SIGTERM, SIGKILL after 2 s" : "SIGTERM only")",
                             target: nil, action: nil)
            b.state = .off
            boxes.append(b)
            stack.addArrangedSubview(b)
        }
        stack.frame = NSRect(x: 0, y: 0, width: 480, height: CGFloat(boxes.count) * 22)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 500, height: min(360, CGFloat(boxes.count) * 22 + 4)))
        scroll.documentView = stack
        scroll.hasVerticalScroller = true
        a.accessoryView = scroll
        a.addButton(withTitle: "Stop Checked").hasDestructiveAction = true
        a.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
        guard a.runModal() == .alertFirstButtonReturn else { return }
        var seen = Set<String>()
        let chosen = zip(candidates, boxes).filter { $0.1.state == .on }.map(\.0).filter { seen.insert(processKey($0)).inserted }
        guard !chosen.isEmpty else { return }
        var outcomes: [StopOutcome] = []
        afterWork({ outcomes = stopAll(chosen.map(StopTarget.init), registry: self.stops) }) { fresh in
            let report = outcomes.map(\.summary) + Set(chosen.map(\.port)).sorted().map { portReport($0, owners: owners(ofPort: $0, in: fresh)) }
            self.alert("Stopped \(outcomes.filter { $0.error == nil && !$0.refused && !$0.stillRunning }.count) of \(outcomes.count)",
                       report.joined(separator: "\n"))
        }
    }

    /// Kill would be pointless (launchd restarts it at once); offer the setting that frees the port.
    func explainRestart(_ l: Listener) {
        let a = NSAlert()
        a.messageText = "macOS will restart \(appName(l.exe)) immediately"
        a.informativeText = (KnownPorts.explanation(l).map { $0 + "\n\n" } ?? "")
            + "Stopping it won't free port \(l.port), so Ports doesn't offer that."
        let link = KnownPorts.settingsAction(l)
        if let link { a.addButton(withTitle: link.title) }
        a.addButton(withTitle: link == nil ? "OK" : "Cancel").keyEquivalent = link == nil ? "\r" : "\u{1b}"
        if present(a, key: nil) == .alertFirstButtonReturn, let link { NSWorkspace.shared.open(link.url) }
    }

    /// Always rescans first (the menu cache may be stale); several owners -> the user picks one.
    func killByPort() {
        guard let text = prompt("Kill by Port", "Which port? (e.g. 4321)"),
              let port = Int(text), (1...65535).contains(port) else { return }
        afterWork({}) { fresh in
            let found = owners(ofPort: port, in: fresh)
            switch found.count {
            case 0: self.alert("Nothing is listening on port \(port)", "")
            case 1: self.stop(found[0])
            default: if let l = self.choose(found, port: port) { self.stop(l) }
            }
        }
    }

    func killByPID() {
        guard let text = prompt("Kill by PID", "Which process ID?"), let pid = pid_t(text), pid > 0 else { return }
        guard let id = Proc.identity(pid) else { alert("No process with PID \(pid)", ""); return }
        let cmd = Proc.commandLine(pid)
        let key = StopRegistry.key(pid: pid, start: id.start)
        guard beginStop(key) else { return }
        let mine = listeners.filter { $0.pid == pid && $0.start == id.start }
        if let auto = mine.first(where: KnownPorts.restartsAutomatically) { endStop(key); return explainRestart(auto) }
        let policy = StopPolicy.strictest(mine)
        var detail = tilde(cmd.isEmpty ? Proc.exePath(pid) : cmd)
        if let warning = policy.warning { detail += "\n\n⚠️ " + warning }
        guard confirm("Kill PID \(pid)?", detail, button: "Kill", key: key) else { return endStop(key) }
        // start time captured *before* the dialog
        stop(pid: pid, start: id.start, policy: policy, ports: mine.map(\.port), name: "PID \(pid)")
    }

    // MARK: Dialogs

    /// Run an alert modally; with `key`, register it as that stop flow's open alert while it is up.
    func present(_ a: NSAlert, key: String?) -> NSApplication.ModalResponse {
        NSApp.activate()
        if let key { stopAlerts[key] = a.window }
        defer { if let key, stopAlerts[key] === a.window { stopAlerts[key] = nil } }
        return a.runModal()
    }

    func confirm(_ title: String, _ text: String, button: String, key: String? = nil) -> Bool {
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = title
        a.informativeText = text
        a.addButton(withTitle: button).hasDestructiveAction = true
        a.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
        return present(a, key: key) == .alertFirstButtonReturn
    }

    /// Several processes own one port: list them all and let the user pick.
    func choose(_ owners: [Listener], port: Int) -> Listener? {
        NSApp.activate()
        let a = NSAlert()
        a.messageText = "\(owners.count) processes are listening on port \(port)"
        a.informativeText = "Choose which one to stop."
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 360, height: 26), pullsDown: false)
        for l in owners {
            popup.addItem(withTitle: "\(l.label) — PID \(l.pid) · \(l.addresses.joined(separator: ", "))\(l.container.map { " · container \($0)" } ?? "")")
        }
        a.accessoryView = popup
        a.addButton(withTitle: "Continue")
        a.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
        guard a.runModal() == .alertFirstButtonReturn else { return nil }
        return owners[popup.indexOfSelectedItem]
    }

    func alert(_ title: String, _ text: String, key: String? = nil) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        _ = present(a, key: key)
    }

    func textPrompt(_ title: String, _ text: String, initial: String) -> String? {
        NSApp.activate()
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = initial
        a.accessoryView = field
        a.addButton(withTitle: "Save")
        a.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
        a.window.initialFirstResponder = field
        guard a.runModal() == .alertFirstButtonReturn else { return nil }
        return String(field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
    }

    func prompt(_ title: String, _ text: String) -> String? {
        NSApp.activate()
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.placeholderString = "Numbers only"
        a.accessoryView = field
        a.addButton(withTitle: "Continue")
        a.addButton(withTitle: "Cancel")
        a.window.initialFirstResponder = field
        guard a.runModal() == .alertFirstButtonReturn else { return nil }
        let v = field.stringValue.trimmingCharacters(in: .whitespaces)
        return v.allSatisfy(\.isNumber) && !v.isEmpty && v.count <= 6 ? v : nil
    }
}

// `Ports --list` prints the table in Terminal (handy for checking classification).
if CommandLine.arguments.contains("--list") {
    let t0 = Date()
    for l in scanWithContainers() { print(listRow(l)) }
    let t1 = Date()
    _ = scan(docker: [:])
    print(String(format: "\nscan (no docker): %.0f ms · with docker: %.0f ms", Date().timeIntervalSince(t1) * 1000, t1.timeIntervalSince(t0) * 1000))
    exit(0)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)   // menu bar only, no Dock icon
    app.run()
}
