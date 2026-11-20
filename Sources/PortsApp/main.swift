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

// MARK: - App

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let menu = NSMenu()
    let scanQueue = DispatchQueue(label: "local.portwatch.scan", qos: .userInitiated)
    var listeners: [Listener] = []
    var docker: [Int: String] = [:]
    var menuOpen = false
    var scanning = false
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
        guard !scanning else { return }
        scanning = true
        let cachedDocker = docker
        scanQueue.async {
            // Menu open: query containers in this same scan. Background poll: reuse the last map —
            // scan() only applies it to container-runtime proxies, so a native process never inherits it.
            var map = cachedDocker
            var result = scan(docker: map)
            if withDocker {
                map = needsContainerQuery(result) ? dockerPorts() : [:]
                result = scan(docker: map)
            }
            RunLoop.main.perform(inModes: [.common]) {
                MainActor.assumeIsolated {
                    self.scanning = false
                    self.docker = map
                    guard result != self.listeners else { return }   // nothing changed: don't touch the UI
                    self.listeners = result
                    self.render()
                }
            }
        }
    }

    func render() {
        let n = listeners.filter { $0.kind.isDeveloper }.count
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
        let shown = listeners.filter {
            switch filter { case .developer: showsInDeveloperView($0); case .system: !$0.kind.isDeveloper; case .all: true }
        }

        let show = NSMenuItem(title: "Show: " + ["Developer", "System & Apps", "All"][filter.rawValue], action: nil, keyEquivalent: "")
        show.image = NSImage(systemSymbolName: "line.3.horizontal.decrease.circle", accessibilityDescription: nil)
        let sub = NSMenu()
        for (f, name, key) in [(Filter.developer, "Developer — frontend, backend, DB, Docker", "1"),
                               (.system, "System & Apps", "2"), (.all, "All", "3")] {
            let item = ActionItem(name, key: key) { [weak self] in self?.filter = f }
            item.state = filter == f ? .on : .off
            sub.addItem(item)
        }
        show.submenu = sub
        menu.addItem(show)

        if shown.isEmpty {
            menu.addItem(.separator())
            menu.addItem(infoItem(filter == .developer ? "No dev servers running" : "Nothing listening", symbol: "checkmark.circle"))
        }
        for kind in Kind.allCases {
            let rows = shown.filter { $0.kind == kind }
            guard !rows.isEmpty else { continue }
            menu.addItem(.separator())
            menu.addItem(NSMenuItem.sectionHeader(title: "\(kind.title) · \(rows.count)"))
            for l in rows { menu.addItem(row(l)) }
        }

        menu.addItem(.separator())
        menu.addItem(ActionItem("Kill by Port…", symbol: "number", key: "k") { [weak self] in self?.killByPort() })
        menu.addItem(ActionItem("Kill by PID…", symbol: "xmark.circle", key: "k", mods: [.command, .shift]) { [weak self] in self?.killByPID() })
        menu.addItem(.separator())
        menu.addItem(ActionItem("Quit Ports", key: "q") { NSApp.terminate(nil) })
    }

    func row(_ l: Listener) -> NSMenuItem {
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: l.kind.symbol, accessibilityDescription: l.kind.title)
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
        if l.stopped {
            text.append(NSAttributedString(string: "  STOPPED", attributes: [
                .font: NSFont.systemFont(ofSize: 10, weight: .bold), .foregroundColor: NSColor.systemYellow]))
        }
        item.attributedTitle = text
        item.toolTip = tilde(l.command)

        let sub = NSMenu()
        sub.addItem(infoItem("PID \(l.pid)", symbol: "number"))
        sub.addItem(infoItem(l.exposed ? "Reachable from your network (\(l.exposure.address))" : "Local only (\(l.exposure.address))",
                             symbol: l.exposed ? "wifi.exclamationmark" : "lock"))
        if let why = KnownPorts.explanation(l) {
            for line in wrap(why, 60) { sub.addItem(infoItem(line, symbol: line == wrap(why, 60).first ? "info.circle" : nil)) }
        }
        if l.stopped {
            sub.addItem(infoItem("Stopped (suspended) — holds the port but answers nothing", symbol: "pause.circle"))
        }
        if !l.cwd.isEmpty && l.cwd != "/" { sub.addItem(infoItem(tilde(l.cwd), symbol: "folder")) }
        let cmd = tilde(l.command)
        sub.addItem(infoItem(cmd.count > 90 ? String(cmd.prefix(89)) + "…" : cmd, symbol: "terminal"))
        sub.addItem(.separator())
        sub.addItem(ActionItem("Open in Browser", symbol: "safari", key: "") {
            NSWorkspace.shared.open(URL(string: "http://localhost:\(l.port)")!)
        })
        if !l.cwd.isEmpty && l.cwd != "/" {
            sub.addItem(ActionItem("Show Folder in Finder", symbol: "folder", key: "") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: l.cwd)])
            })
        }
        sub.addItem(ActionItem("Copy PID", symbol: "doc.on.doc", key: "") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString("\(l.pid)", forType: .string)
        })
        sub.addItem(.separator())
        if let c = l.container {
            sub.addItem(ActionItem("Stop Container “\(c)”", symbol: "stop.circle", key: "") { [weak self] in self?.stopContainer(c, port: l.port) })
        } else if l.uid != getuid() {
            sub.addItem(infoItem("Owned by the system — can't stop", symbol: "lock.shield"))
        } else {
            sub.addItem(ActionItem(l.kind == .database ? "Shut Down…" : "Kill Process", symbol: "xmark.octagon", key: "") { [weak self] in self?.confirmKill(l) })
        }
        item.submenu = sub
        return item
    }

    // MARK: Actions

    /// Run `work` off the main thread, then hand a fresh scan (with container labels) back to the UI.
    func afterWork(_ work: @escaping () -> Void, then done: @escaping ([Listener]) -> Void) {
        scanQueue.async {
            work()
            let fresh = scanWithContainers()
            RunLoop.main.perform(inModes: [.common]) {
                MainActor.assumeIsolated {
                    if fresh != self.listeners { self.listeners = fresh; self.render() }
                    done(fresh)
                }
            }
        }
    }

    func confirmKill(_ l: Listener) {
        let policy = StopPolicy(l)
        var detail = "Port \(l.port) · PID \(l.pid)\n\(tilde(l.command))"
        if let warning = policy.warning { detail += "\n\n⚠️ " + warning }
        if l.kind == .system { detail += "\n\nThis is an app or system process. Stopping it may close an app." }
        if l.kind == .docker { detail += "\n\nThis is the container engine. Stopping it stops ALL containers." }
        guard confirm("Stop \(l.label)?", detail, button: policy == .dataStore ? "Shut Down" : "Kill") else { return }
        stop(pid: l.pid, start: l.start, policy: policy, ports: [l.port], name: l.label)
    }

    /// Stop ladder, then rescan and report each port. Data stores are never force-killed here:
    /// if one is still running, Force is offered as its own explicit step.
    func stop(pid: pid_t, start: UInt64, policy: StopPolicy, ports: [Int], name: String) {
        var err: KillError?
        afterWork({ err = safeTerminate(pid: pid, start: start, policy: policy) }) { fresh in
            if let err { self.alert("Couldn't stop PID \(pid)", err.description); return }
            let report = ports.map { portReport($0, owners: owners(ofPort: $0, in: fresh)) }.joined(separator: "\n")
            let survived = fresh.contains { $0.pid == pid && $0.start == start }
            guard survived && !policy.autoForce else { return self.alert(report, "") }
            guard self.confirm("\(name) is still running", report + "\n\nIt didn't shut down within \(Int(policy.grace)) s. "
                               + "Force Quit kills it immediately (SIGKILL) and may lose unsaved data.",
                               button: "Force Quit") else { return }
            var forceErr: KillError?
            self.afterWork({ forceErr = forceKill(pid: pid, start: start) }) { fresh in
                if let forceErr { return self.alert("Couldn't force quit PID \(pid)", forceErr.description) }
                self.alert(ports.map { portReport($0, owners: owners(ofPort: $0, in: fresh)) }.joined(separator: "\n"), "")
            }
        }
    }

    func stopContainer(_ name: String, port: Int) {
        guard let docker = dockerPath, isSafeContainerName(name) else { return }
        guard confirm("Stop container “\(name)”?", "It publishes port \(port).\nStart it again any time with:  docker start \(name)", button: "Stop") else { return }
        var res = (out: "", ok: true)
        afterWork({ res = run(docker, ["stop", "--", name], timeout: 20) }) { fresh in
            if !res.ok { return self.alert("Couldn't stop \(name)", res.out) }
            self.alert(portReport(port, owners: owners(ofPort: port, in: fresh)), "")
        }
    }

    func stop(_ l: Listener) {
        if let c = l.container { stopContainer(c, port: l.port) } else { confirmKill(l) }
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
        let mine = listeners.filter { $0.pid == pid && $0.start == id.start }
        let policy = mine.contains { StopPolicy($0) == .dataStore } ? StopPolicy.dataStore : .devServer
        var detail = tilde(cmd.isEmpty ? Proc.exePath(pid) : cmd)
        if let warning = policy.warning { detail += "\n\n⚠️ " + warning }
        guard confirm("Kill PID \(pid)?", detail, button: "Kill") else { return }
        // start time captured *before* the dialog
        stop(pid: pid, start: id.start, policy: policy, ports: mine.map(\.port), name: "PID \(pid)")
    }

    // MARK: Dialogs

    func confirm(_ title: String, _ text: String, button: String) -> Bool {
        NSApp.activate()
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = title
        a.informativeText = text
        a.addButton(withTitle: button).hasDestructiveAction = true
        a.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
        return a.runModal() == .alertFirstButtonReturn
    }

    /// Several processes own one port: list them all and let the user pick.
    func choose(_ owners: [Listener], port: Int) -> Listener? {
        NSApp.activate()
        let a = NSAlert()
        a.messageText = "\(owners.count) processes are listening on port \(port)"
        a.informativeText = "Choose which one to stop."
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 360, height: 26), pullsDown: false)
        for l in owners {
            popup.addItem(withTitle: "\(l.label) — PID \(l.pid) · \(l.exposure.address)\(l.container.map { " · container \($0)" } ?? "")")
        }
        a.accessoryView = popup
        a.addButton(withTitle: "Continue")
        a.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
        guard a.runModal() == .alertFirstButtonReturn else { return nil }
        return owners[popup.indexOfSelectedItem]
    }

    func alert(_ title: String, _ text: String) {
        NSApp.activate()
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.runModal()
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
    for l in scanWithContainers() {
        print(":\(l.port)".padding(toLength: 7, withPad: " ", startingAt: 0),
              "\(l.pid)".padding(toLength: 7, withPad: " ", startingAt: 0),
              l.kind.title.padding(toLength: 14, withPad: " ", startingAt: 0),
              (l.exposed ? "LAN " : "    ") + l.label)
    }
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
