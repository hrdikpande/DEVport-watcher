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
        let wantDocker = withDocker && dockerPath != nil
        let cachedDocker = docker
        scanQueue.async {
            var map = cachedDocker
            var result = scan(docker: map)
            if wantDocker && result.contains(where: { $0.kind == .docker }) {
                map = dockerPorts()
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
            switch filter { case .developer: $0.kind.isDeveloper; case .system: !$0.kind.isDeveloper; case .all: true }
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
        item.attributedTitle = text
        item.toolTip = tilde(l.command)

        let sub = NSMenu()
        sub.addItem(infoItem("PID \(l.pid)", symbol: "number"))
        sub.addItem(infoItem(l.exposed ? "Reachable from your network (0.0.0.0)" : "Local only (127.0.0.1)",
                             symbol: l.exposed ? "wifi.exclamationmark" : "lock"))
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
            sub.addItem(ActionItem("Kill Process", symbol: "xmark.octagon", key: "") { [weak self] in self?.confirmKill(l) })
        }
        item.submenu = sub
        return item
    }

    // MARK: Actions

    func confirmKill(_ l: Listener) {
        var detail = "Port \(l.port) · PID \(l.pid)\n\(tilde(l.command))"
        if l.kind == .system { detail += "\n\nThis is an app or system process. Stopping it may close an app." }
        if l.kind == .docker { detail += "\n\nThis is the Docker engine. Stopping it stops ALL containers." }
        guard confirm("Stop \(l.label)?", detail, button: "Kill") else { return }
        signal(pid: l.pid, start: l.start)
    }

    func signal(pid: pid_t, start: UInt64) {
        scanQueue.async {
            let err = safeTerminate(pid: pid, start: start)
            RunLoop.main.perform(inModes: [.common]) {
                MainActor.assumeIsolated {
                    if let err { self.alert("Couldn't stop PID \(pid)", err.description) }
                    self.refresh(withDocker: false)
                }
            }
        }
    }

    func stopContainer(_ name: String, port: Int) {
        guard let docker = dockerPath, isSafeContainerName(name) else { return }
        guard confirm("Stop container “\(name)”?", "It publishes port \(port).\nStart it again any time with:  docker start \(name)", button: "Stop") else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let res = run(docker, ["stop", "--", name], timeout: 20)
            RunLoop.main.perform(inModes: [.common]) {
                MainActor.assumeIsolated {
                    if !res.ok { self.alert("Couldn't stop \(name)", res.out) }
                    self.refresh(withDocker: true)
                }
            }
        }
    }

    func killByPort() {
        guard let text = prompt("Kill by Port", "Which port? (e.g. 4321)"),
              let port = Int(text), (1...65535).contains(port) else { return }
        guard let l = listeners.first(where: { $0.port == port }) else {
            alert("Nothing is listening on port \(port)", ""); return
        }
        if let c = l.container { stopContainer(c, port: port) } else { confirmKill(l) }
    }

    func killByPID() {
        guard let text = prompt("Kill by PID", "Which process ID?"), let pid = pid_t(text), pid > 0 else { return }
        guard let id = Proc.identity(pid) else { alert("No process with PID \(pid)", ""); return }
        let cmd = Proc.commandLine(pid)
        guard confirm("Kill PID \(pid)?", tilde(cmd.isEmpty ? Proc.exePath(pid) : cmd), button: "Kill") else { return }
        signal(pid: pid, start: id.start)     // start time captured *before* the dialog
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
    let map = dockerPath != nil ? dockerPorts() : [:]
    for l in scan(docker: map) {
        print(":\(l.port)".padding(toLength: 7, withPad: " ", startingAt: 0),
              "\(l.pid)".padding(toLength: 7, withPad: " ", startingAt: 0),
              l.kind.title.padding(toLength: 14, withPad: " ", startingAt: 0),
              (l.exposed ? "LAN " : "    ") + l.label)
    }
    let t1 = Date()
    _ = scan(docker: map)
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
