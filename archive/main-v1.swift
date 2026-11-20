// Ports — a tiny menu bar app that lists every listening TCP port with its PID,
// sorts them into Developer (frontend / backend / databases / docker) and System & Apps,
// and lets you kill a process or stop a Docker container. Local only: it just runs
// lsof, ps and docker on this Mac.

import AppKit
import Darwin

// MARK: - Model

enum Kind: Int, CaseIterable {
    case frontend, backend, database, docker, system
    var title: String { ["Frontend", "Backend", "Databases", "Docker", "System & Apps"][rawValue] }
    var isDeveloper: Bool { self != .system }
}

enum Filter: Int { case developer, system, all }

struct Listener {
    let port: Int
    let pid: Int32
    let address: String
    let command: String     // full command line from ps
    let cwd: String
    var container: String?  // docker container name, if a container publishes this port
    var kind: Kind = .system
    var label = ""
}

// MARK: - Shell helpers

func run(_ path: String, _ args: [String]) -> (out: String, ok: Bool) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    do { try p.run() } catch { return ("", false) }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (String(decoding: data, as: UTF8.self), p.terminationStatus == 0)
}

let home = FileManager.default.homeDirectoryForCurrentUser.path
func tilde(_ path: String) -> String { path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path }

let dockerPath = ["/usr/local/bin/docker", "/opt/homebrew/bin/docker",
                  "/Applications/Docker.app/Contents/Resources/bin/docker"]
    .first { FileManager.default.isExecutableFile(atPath: $0) }

/// host port -> "container (image)"
func dockerPorts() -> [Int: String] {
    guard let docker = dockerPath else { return [:] }
    let res = run(docker, ["ps", "--format", "{{.Names}}\t{{.Image}}\t{{.Ports}}"])
    guard res.ok else { return [:] }
    var map: [Int: String] = [:]
    let regex = try! NSRegularExpression(pattern: #":(\d+)(?:-(\d+))?->"#)
    for line in res.out.split(separator: "\n") {
        let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3 else { continue }
        let ports = parts[2] as NSString
        for m in regex.matches(in: parts[2], range: NSRange(location: 0, length: ports.length)) {
            let lo = Int(ports.substring(with: m.range(at: 1)))!
            let hi = m.range(at: 2).location == NSNotFound ? lo : Int(ports.substring(with: m.range(at: 2)))!
            for p in lo...max(lo, hi) { map[p] = parts[0] }
        }
    }
    return map
}

// MARK: - Classification (edit these lists to teach it about your tools)

let dbNames = ["postgres", "mysqld", "mariadbd", "mongod", "redis-server", "memcached", "clickhouse",
               "influxd", "cockroach", "elasticsearch", "opensearch", "neo4j", "couchdb", "rabbitmq",
               "nats-server", "kafka", "surreal", "valkey-server"]
let frontendTools = ["vite", "next", "next-server", "astro", "nuxt", "webpack", "react-scripts", "parcel",
                     "svelte-kit", "remix", "gatsby", "ng", "live-server", "http-server", "eleventy",
                     "storybook", "expo", "metro", "serve"]
let backendTools = ["node", "python", "python3", "ruby", "php", "java", "go", "deno", "bun", "uvicorn",
                    "gunicorn", "flask", "manage.py", "rails", "puma", "dotnet", "cargo", "nodemon", "tsx",
                    "ts-node", "nest", "air", "hypercorn", "fastapi", "supabase"]
let appTools = ["claude", "agy", "electron"]                  // dev *apps*, not servers you started
let systemPrefixes = ["/System/", "/usr/libexec/", "/usr/sbin/", "/Applications/", "/Library/"]

/// Splits a command line into lowercase words ("…/astro/bin/astro.mjs" -> ["astro", "bin", "astro.mjs"]).
func tokens(_ command: String) -> [String] {
    command.lowercased().split(whereSeparator: { $0 == " " || $0 == "/" }).map(String.init)
}
func matches(_ toks: [String], _ tools: [String]) -> String? {
    for t in toks { for tool in tools where t == tool || t.hasPrefix(tool + ".") || t.hasPrefix(tool + "-") { return tool } }
    return nil
}

let wellKnownPorts = [5432: "postgres", 3306: "mysql", 6379: "redis", 27017: "mongo", 9200: "elasticsearch",
                      5672: "rabbitmq", 11211: "memcached", 1433: "sql server", 8080: "web", 8000: "web", 3000: "web"]

/// Friendly name for an app/system process: "Visual Studio Code", "VS Code ext: oracle.sql-developer", "rapportd".
func appName(_ command: String) -> String {
    if let r = command.range(of: "/.vscode/extensions/") {
        let ext = command[r.upperBound...].split(separator: "/").first.map(String.init) ?? ""
        return "VS Code ext: " + ext.replacingOccurrences(of: #"-\d.*$"#, with: "", options: .regularExpression)
    }
    if let r = command.range(of: ".app/") {                       // first .app in the path = the app
        return URL(fileURLWithPath: String(command[..<r.lowerBound])).lastPathComponent
    }
    let exe = command.split(separator: " ").first.map(String.init) ?? command
    return URL(fileURLWithPath: exe).lastPathComponent
}

func classify(_ l: Listener) -> (Kind, String) {
    let toks = tokens(l.command)
    if let c = l.container { return (.docker, c) }
    if l.command.contains("com.docker") {                       // docker ps failed (paused / not running)
        let guess = wellKnownPorts[l.port].map { "\($0)? · " } ?? ""
        return (.docker, "\(guess)Docker paused")
    }
    if let db = matches(toks, dbNames) { return (.database, db) }
    // 1. Dev *apps* and editor helpers (they run node/java inside, but you didn't start them).
    if matches(Array(toks.prefix(1)), appTools) != nil || l.command.contains("/.vscode/extensions")
        || l.command.contains("/.gemini/") {
        return (.system, appName(l.command))
    }
    // 2. Servers you started. Checked before system paths because e.g. python lives in /Library/…/Python.app.
    let isOS = ["/System/", "/usr/libexec/", "/usr/sbin/"].contains(where: l.command.hasPrefix)
    if !isOS, let fe = matches(toks, frontendTools) { return (.frontend, fe) }
    if !isOS, let be = matches(toks, backendTools) { return (.backend, be) }
    // 3. Everything else under system / app folders.
    if systemPrefixes.contains(where: l.command.hasPrefix) { return (.system, appName(l.command)) }
    return (.system, toks.first.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "?")
}

// MARK: - Scan

func scan() -> [Listener] {
    let raw = run("/usr/sbin/lsof", ["-nP", "-iTCP", "-sTCP:LISTEN", "-F", "pn"]).out
    var found: [(pid: Int32, port: Int, addr: String)] = []
    var seen = Set<String>()
    var pid: Int32 = 0
    for line in raw.split(separator: "\n") {
        let v = String(line.dropFirst())
        switch line.first {
        case "p": pid = Int32(v) ?? 0
        case "n":
            guard let i = v.lastIndex(of: ":"), let port = Int(v[v.index(after: i)...]) else { continue }
            if seen.insert("\(pid):\(port)").inserted { found.append((pid, port, String(v[..<i]))) }
        default: break
        }
    }
    let pids = Set(found.map(\.pid)).map(String.init).joined(separator: ",")
    guard !pids.isEmpty else { return [] }

    var commands: [Int32: String] = [:]
    for line in run("/bin/ps", ["-o", "pid=,command=", "-p", pids]).out.split(separator: "\n") {
        let t = line.trimmingCharacters(in: .whitespaces)
        if let sp = t.firstIndex(of: " "), let p = Int32(t[..<sp]) {
            commands[p] = t[sp...].trimmingCharacters(in: .whitespaces)
        }
    }
    var cwds: [Int32: String] = [:]
    var cur: Int32 = 0
    for line in run("/usr/sbin/lsof", ["-a", "-d", "cwd", "-p", pids, "-Fpn"]).out.split(separator: "\n") {
        if line.first == "p" { cur = Int32(line.dropFirst()) ?? 0 }
        if line.first == "n" { cwds[cur] = String(line.dropFirst()) }
    }
    let docker = dockerPorts()

    return found.map { f in
        var l = Listener(port: f.port, pid: f.pid, address: f.addr,
                         command: commands[f.pid] ?? "?", cwd: cwds[f.pid] ?? "",
                         container: docker[f.port])
        let (kind, tool) = classify(l)
        l.kind = kind
        let folder = (l.cwd.hasPrefix(home) && l.cwd != home) ? URL(fileURLWithPath: l.cwd).lastPathComponent : ""
        l.label = (kind.isDeveloper && !folder.isEmpty && kind != .docker) ? "\(tool) · \(folder)" : tool
        return l
    }.sorted { ($0.kind.rawValue, $0.port) < ($1.kind.rawValue, $1.port) }
}

// MARK: - Menu item with a closure

final class ActionItem: NSMenuItem {
    private var handler: () -> Void = {}
    convenience init(_ title: String, key: String = "", _ handler: @escaping () -> Void) {
        self.init(title: title, action: #selector(fire), keyEquivalent: key)
        self.target = self
        self.handler = handler
    }
    @objc private func fire() { handler() }
}

func info(_ text: String) -> NSMenuItem {
    let i = NSMenuItem(title: text, action: nil, keyEquivalent: "")
    i.isEnabled = false
    return i
}

// MARK: - App

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let menu = NSMenu()
    var filter = Filter(rawValue: UserDefaults.standard.integer(forKey: "filter")) ?? .developer {
        didSet { UserDefaults.standard.set(filter.rawValue, forKey: "filter") }
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        let img = NSImage(systemSymbolName: "point.3.connected.trianglepath.dotted", accessibilityDescription: "Ports")
        img?.isTemplate = true
        status.button?.image = img
        status.button?.imagePosition = .imageLeading
        menu.delegate = self
        status.menu = menu
        updateBadge()
        Timer.scheduledTimer(timeInterval: 15, target: self, selector: #selector(updateBadge), userInfo: nil, repeats: true)
    }

    /// Shows how many developer ports are open next to the icon.
    @objc func updateBadge() {
        let n = scan().filter { $0.kind.isDeveloper }.count
        status.button?.title = n > 0 ? " \(n)" : ""
    }

    // Rebuilt every time the menu opens, so it is always live.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let all = scan()
        let shown = all.filter {
            switch filter { case .developer: $0.kind.isDeveloper; case .system: !$0.kind.isDeveloper; case .all: true }
        }
        status.button?.title = { let n = all.filter { $0.kind.isDeveloper }.count; return n > 0 ? " \(n)" : "" }()

        let show = NSMenuItem(title: "Show: " + ["Developer", "System & Apps", "All"][filter.rawValue], action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for (f, name) in [(Filter.developer, "Developer (frontend, backend, DB, Docker)"),
                          (.system, "System & Apps"), (.all, "All")] {
            let item = ActionItem(name) { [weak self] in self?.filter = f }
            item.state = filter == f ? .on : .off
            sub.addItem(item)
        }
        show.submenu = sub
        menu.addItem(show)

        if shown.isEmpty { menu.addItem(.separator()); menu.addItem(info("Nothing listening here")) }
        for kind in Kind.allCases {
            let rows = shown.filter { $0.kind == kind }
            guard !rows.isEmpty else { continue }
            menu.addItem(.separator())
            menu.addItem(NSMenuItem.sectionHeader(title: "\(kind.title) (\(rows.count))"))
            for l in rows { menu.addItem(row(l)) }
        }

        menu.addItem(.separator())
        menu.addItem(ActionItem("Kill by Port…") { [weak self] in self?.killByPort() })
        menu.addItem(ActionItem("Kill by PID…") { [weak self] in self?.killByPID() })
        menu.addItem(.separator())
        menu.addItem(ActionItem("Quit Ports", key: "q") { NSApp.terminate(nil) })
    }

    func row(_ l: Listener) -> NSMenuItem {
        let port = ":\(l.port)".padding(toLength: 7, withPad: " ", startingAt: 0)
        let label = l.label.count > 38 ? String(l.label.prefix(37)) + "…" : l.label
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        let text = NSMutableAttributedString(string: port + label,
            attributes: [.font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)])
        text.append(NSAttributedString(string: "   PID \(l.pid)",
            attributes: [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                         .foregroundColor: NSColor.secondaryLabelColor]))
        item.attributedTitle = text

        let sub = NSMenu()
        sub.addItem(info("PID \(l.pid) · listening on \(l.address == "*" ? "all interfaces" : l.address)"))
        if !l.cwd.isEmpty { sub.addItem(info("Folder: \(tilde(l.cwd))")) }
        let cmd = tilde(l.command)
        sub.addItem(info(cmd.count > 90 ? String(cmd.prefix(89)) + "…" : cmd))
        sub.addItem(.separator())
        sub.addItem(ActionItem("Open http://localhost:\(l.port)") {
            NSWorkspace.shared.open(URL(string: "http://localhost:\(l.port)")!)
        })
        if !l.cwd.isEmpty && l.cwd != "/" {
            sub.addItem(ActionItem("Reveal Folder in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: l.cwd)])
            })
        }
        sub.addItem(ActionItem("Copy PID") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString("\(l.pid)", forType: .string)
        })
        sub.addItem(.separator())
        if let c = l.container {
            sub.addItem(ActionItem("Stop Container “\(c)”") { [weak self] in self?.stopContainer(c, port: l.port) })
        } else {
            sub.addItem(ActionItem("Kill Process (PID \(l.pid))") { [weak self] in self?.confirmKill(l) })
        }
        item.submenu = sub
        return item
    }

    // MARK: Actions

    func confirmKill(_ l: Listener) {
        var detail = "Port \(l.port) · PID \(l.pid)\n\(tilde(l.command))"
        if l.kind == .system { detail += "\n\n⚠️ This is a system or app process. Killing it may close an app or break something." }
        if l.command.contains("com.docker") { detail += "\n\n⚠️ This is the Docker engine. Killing it stops ALL containers." }
        guard confirm("Kill \(l.label)?", detail, button: "Kill") else { return }
        terminate(l.pid)
    }

    /// Polite SIGTERM first; if it is still alive after 2 s, SIGKILL.
    func terminate(_ pid: Int32) {
        if kill(pid, SIGTERM) != 0 {
            let reason = errno == EPERM ? "Permission denied (it belongs to another user or the system)." : String(cString: strerror(errno))
            alert("Couldn't stop PID \(pid)", reason)
            return
        }
        DispatchQueue.global().async {
            for _ in 0..<20 { usleep(100_000); if kill(pid, 0) != 0 { break } }
            if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
            DispatchQueue.main.async { self.updateBadge() }
        }
    }

    func stopContainer(_ name: String, port: Int) {
        guard let docker = dockerPath else { return }
        guard confirm("Stop container “\(name)”?", "It publishes port \(port). You can start it again with: docker start \(name)", button: "Stop") else { return }
        DispatchQueue.global().async {
            let res = run(docker, ["stop", name])
            DispatchQueue.main.async {
                if !res.ok { self.alert("Couldn't stop \(name)", res.out) }
                self.updateBadge()
            }
        }
    }

    func killByPort() {
        guard let text = prompt("Kill by Port", "Which port? (e.g. 4321)"), let port = Int(text) else { return }
        let hits = scan().filter { $0.port == port }
        guard let l = hits.first else { alert("Nothing is listening on port \(port)", ""); return }
        if let c = l.container { stopContainer(c, port: port) } else { confirmKill(l) }
    }

    func killByPID() {
        guard let text = prompt("Kill by PID", "Which process ID?"), let pid = Int32(text) else { return }
        let cmd = run("/bin/ps", ["-o", "command=", "-p", "\(pid)"]).out.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cmd.isEmpty else { alert("No process with PID \(pid)", ""); return }
        guard confirm("Kill PID \(pid)?", tilde(cmd), button: "Kill") else { return }
        terminate(pid)
    }

    // MARK: Dialogs

    func confirm(_ title: String, _ text: String, button: String) -> Bool {
        NSApp.activate()
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.addButton(withTitle: button).hasDestructiveAction = true
        a.addButton(withTitle: "Cancel")
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
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        a.accessoryView = field
        a.addButton(withTitle: "Continue")
        a.addButton(withTitle: "Cancel")
        a.window.initialFirstResponder = field
        guard a.runModal() == .alertFirstButtonReturn else { return nil }
        let v = field.stringValue.trimmingCharacters(in: .whitespaces)
        return v.isEmpty ? nil : v
    }
}

// `Ports.app/Contents/MacOS/Ports --list` prints the table in Terminal instead of opening the menu.
if CommandLine.arguments.contains("--list") {
    for l in scan() {
        print(":\(l.port)".padding(toLength: 7, withPad: " ", startingAt: 0),
              "\(l.pid)".padding(toLength: 7, withPad: " ", startingAt: 0),
              l.kind.title.padding(toLength: 14, withPad: " ", startingAt: 0), l.label)
    }
    exit(0)
}

MainActor.assumeIsolated {           // top-level code runs on the main thread
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)   // menu bar only, no Dock icon
    app.run()
}
