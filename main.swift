// Ports — a native macOS menu bar app that lists every listening TCP port with its PID,
// groups them (Frontend / Backend / Databases / Docker / System & Apps) and lets you stop them.
//
// Performance: ports, PIDs, paths and folders come straight from the kernel via libproc
// (no lsof/ps child processes). Scans run on a background queue; the menu opens instantly
// from a cache and updates in place.
//
// Security: classification uses the real executable path (argv can be faked); every kill
// re-checks the process start time (guards against PID reuse) and the owner; only your own
// processes can be signalled; the only child process ever started is the docker CLI, from a
// fixed absolute path, with a minimal environment, a timeout and validated arguments.

import AppKit
import Darwin

// MARK: - Model

enum Kind: Int, CaseIterable {
    case frontend, backend, database, docker, system
    var title: String { ["Frontend", "Backend", "Databases", "Docker", "System & Apps"][rawValue] }
    var symbol: String { ["macwindow", "server.rack", "cylinder.split.1x2", "shippingbox", "gearshape"][rawValue] }
    var isDeveloper: Bool { self != .system }
}

enum Filter: Int { case developer, system, all }

struct Listener: Equatable {
    let port: Int
    let pid: pid_t
    let start: UInt64        // process start time (µs) — identity check against PID reuse
    let uid: uid_t
    var exposed: Bool        // listening on all interfaces (reachable from your network)
    let exe: String          // real executable path from the kernel
    let command: String      // argv joined (display + tool detection only)
    let cwd: String
    var container: String? = nil
    var kind: Kind = .system
    var label = ""
}

let home = FileManager.default.homeDirectoryForCurrentUser.path
func tilde(_ p: String) -> String { p.hasPrefix(home) ? "~" + p.dropFirst(home.count) : p }
func basename(_ p: String) -> String { (p as NSString).lastPathComponent }

// MARK: - Native process info (libproc / sysctl)

enum Proc {
    static func allPIDs() -> [pid_t] {
        let n = proc_listallpids(nil, 0)
        guard n > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(n) + 128)
        let got = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        return got > 0 ? Array(pids.prefix(Int(got))).filter { $0 > 0 } : []
    }

    struct Identity: Equatable { let uid: uid_t; let start: UInt64 }
    static func identity(_ pid: pid_t) -> Identity? {
        var bi = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bi, size) == size else { return nil }
        return Identity(uid: bi.pbi_uid, start: bi.pbi_start_tvsec &* 1_000_000 &+ bi.pbi_start_tvusec)
    }

    static func exePath(_ pid: pid_t) -> String {
        var buf = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        return n > 0 ? String(decoding: buf.prefix(Int(n)), as: UTF8.self) : ""
    }

    static func cwd(_ pid: pid_t) -> String {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return "" }
        return withUnsafeBytes(of: &info.pvi_cdir.vip_path) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }

    /// argv via KERN_PROCARGS2: [argc:int32][exec path\0][padding \0…][argv0\0][argv1\0]…
    static func commandLine(_ pid: pid_t) -> String {
        var argmax: Int32 = 0
        var size = MemoryLayout<Int32>.size
        var mib = [CTL_KERN, KERN_ARGMAX]
        guard sysctl(&mib, 2, &argmax, &size, nil, 0) == 0 else { return "" }
        var buf = [UInt8](repeating: 0, count: Int(argmax))
        size = buf.count
        mib = [CTL_KERN, KERN_PROCARGS2, pid]
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0, size > 4 else { return "" }
        let argc = buf.withUnsafeBytes { $0.load(as: Int32.self) }
        var i = 4
        while i < size && buf[i] != 0 { i += 1 }      // skip exec path
        while i < size && buf[i] == 0 { i += 1 }      // skip padding
        var args: [String] = [], start = i
        while i < size && args.count < argc {
            if buf[i] == 0 { args.append(String(decoding: buf[start..<i], as: UTF8.self)); start = i + 1 }
            i += 1
        }
        return args.joined(separator: " ")
    }

    /// Listening TCP sockets of one process: (port, exposedToNetwork).
    static func listeningPorts(_ pid: pid_t) -> [(port: Int, exposed: Bool)] {
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0 else { return [] }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / stride + 16)
        let got = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * stride))
        guard got > 0 else { return [] }

        var result: [(Int, Bool)] = []
        for fd in fds.prefix(Int(got) / stride) where fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var si = socket_fdinfo()
            let siSize = Int32(MemoryLayout<socket_fdinfo>.size)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &si, siSize) == siSize,
                  si.psi.soi_kind == SOCKINFO_TCP else { continue }
            let tcp = si.psi.soi_proto.pri_tcp
            guard tcp.tcpsi_state == TSI_S_LISTEN else { continue }
            let ini = tcp.tcpsi_ini
            let port = Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: ini.insi_lport)))
            let exposed: Bool
            if ini.insi_vflag & UInt8(INI_IPV4) != 0 {
                exposed = ini.insi_laddr.ina_46.i46a_addr4.s_addr == INADDR_ANY
            } else {
                var any = in6addr_any, addr = ini.insi_laddr.ina_6
                exposed = memcmp(&addr, &any, MemoryLayout<in6_addr>.size) == 0
            }
            result.append((port, exposed))
        }
        return result
    }
}

// MARK: - Docker (the only external command; fixed path, minimal env, timeout)

let dockerPath = ["/usr/local/bin/docker", "/opt/homebrew/bin/docker",
                  "/Applications/Docker.app/Contents/Resources/bin/docker"]
    .first { FileManager.default.isExecutableFile(atPath: $0) }

func run(_ path: String, _ args: [String], timeout: TimeInterval = 3) -> (out: String, ok: Bool) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args                                            // argv array: no shell, no injection
    p.environment = ["HOME": home, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    do { try p.run() } catch { return ("", false) }
    let done = DispatchSemaphore(value: 0)
    var data = Data()
    DispatchQueue.global(qos: .utility).async { data = pipe.fileHandleForReading.readDataToEndOfFile(); done.signal() }
    if done.wait(timeout: .now() + timeout) == .timedOut {
        p.terminate()
        _ = done.wait(timeout: .now() + 1)
        return ("Timed out after \(Int(timeout)) s", false)
    }
    p.waitUntilExit()
    return (String(decoding: data, as: UTF8.self), p.terminationStatus == 0)
}

func isSafeContainerName(_ s: String) -> Bool {
    s.range(of: #"^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$"#, options: .regularExpression) != nil
}

/// host port -> container name
func dockerPorts() -> [Int: String] {
    guard let docker = dockerPath else { return [:] }
    let res = run(docker, ["ps", "--format", "{{.Names}}\t{{.Ports}}"])
    guard res.ok else { return [:] }
    var map: [Int: String] = [:]
    let regex = try! NSRegularExpression(pattern: #":(\d+)(?:-(\d+))?->"#)
    for line in res.out.split(separator: "\n") {
        let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
        guard parts.count == 2, isSafeContainerName(parts[0]) else { continue }
        let ports = parts[1] as NSString
        for m in regex.matches(in: parts[1], range: NSRange(location: 0, length: ports.length)) {
            guard let lo = Int(ports.substring(with: m.range(at: 1))) else { continue }
            let hi = m.range(at: 2).location == NSNotFound ? lo : (Int(ports.substring(with: m.range(at: 2))) ?? lo)
            for p in lo...min(max(lo, hi), lo + 1000) { map[p] = parts[0] }
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
let appTools = ["claude", "agy", "electron"]                   // dev *apps*, not servers you started
let wellKnownPorts = [5432: "postgres", 3306: "mysql", 6379: "redis", 27017: "mongo", 9200: "elasticsearch",
                      5672: "rabbitmq", 11211: "memcached", 1433: "sql server"]

func tokens(_ s: String) -> [String] {
    s.lowercased().split(whereSeparator: { $0 == " " || $0 == "/" }).map(String.init)
}
func matches(_ toks: [String], _ tools: [String]) -> String? {
    for t in toks { for tool in tools where t == tool || t.hasPrefix(tool + ".") || t.hasPrefix(tool + "-") { return tool } }
    return nil
}

/// "Visual Studio Code", "VS Code ext: oracle.sql-developer", "rapportd"…
func appName(_ exe: String) -> String {
    if let r = exe.range(of: "/.vscode/extensions/") {
        let ext = exe[r.upperBound...].split(separator: "/").first.map(String.init) ?? ""
        return "VS Code ext: " + ext.replacingOccurrences(of: #"-\d.*$"#, with: "", options: .regularExpression)
    }
    if let r = exe.range(of: ".app/") { return basename(String(exe[..<r.lowerBound])) }
    return basename(exe)
}

func classify(_ l: Listener) -> (Kind, String) {
    let toks = tokens(l.command)
    let exeName = basename(l.exe).lowercased()
    let argv0 = basename(l.command.split(separator: " ").first.map(String.init) ?? "").lowercased()

    if let c = l.container { return (.docker, c) }
    if l.exe.contains("/Docker.app/") || exeName.hasPrefix("com.docker") {
        let guess = wellKnownPorts[l.port].map { "\($0)? · " } ?? ""
        return (.docker, "\(guess)Docker engine")
    }
    if let db = matches([exeName] + toks, dbNames) { return (.database, db) }
    // Dev apps & editor helpers (they embed node/java, but you didn't start them).
    if appTools.contains(argv0) || l.exe.contains("/.vscode/extensions/") || l.exe.contains("/.gemini/")
        || (l.exe.contains(".app/") && !backendTools.contains(exeName)) {
        return (.system, appTools.contains(argv0) ? argv0 : appName(l.exe))
    }
    let isOS = ["/System/", "/usr/libexec/", "/usr/sbin/", "/sbin/"].contains(where: l.exe.hasPrefix)
    if !isOS, let fe = matches(toks, frontendTools) { return (.frontend, fe) }
    if !isOS, let be = matches([exeName] + toks, backendTools) { return (.backend, be) }
    return (.system, appName(l.exe))
}

// MARK: - Scan (runs off the main thread)

func scan(docker: [Int: String]) -> [Listener] {
    var out: [Listener] = []
    for pid in Proc.allPIDs() {
        let ports = Proc.listeningPorts(pid)
        guard !ports.isEmpty, let id = Proc.identity(pid) else { continue }
        let exe = Proc.exePath(pid), cmd = Proc.commandLine(pid), cwd = Proc.cwd(pid)
        var byPort: [Int: Bool] = [:]
        for p in ports { byPort[p.port] = (byPort[p.port] ?? false) || p.exposed }
        for (port, exposed) in byPort {
            var l = Listener(port: port, pid: pid, start: id.start, uid: id.uid, exposed: exposed,
                             exe: exe, command: cmd.isEmpty ? exe : cmd, cwd: cwd, container: docker[port])
            let (kind, tool) = classify(l)
            l.kind = kind
            let folder = (cwd.hasPrefix(home + "/")) ? basename(cwd) : ""
            l.label = (kind.isDeveloper && kind != .docker && !folder.isEmpty) ? "\(tool) · \(folder)" : tool
            out.append(l)
        }
    }
    return out.sorted { ($0.kind.rawValue, $0.port, $0.pid) < ($1.kind.rawValue, $1.port, $1.pid) }
}

// MARK: - Safe kill

enum KillError: Error, CustomStringConvertible {
    case gone, notYours, protected, failed(String)
    var description: String {
        switch self {
        case .gone: "That process has already exited (its PID may now belong to something else), so nothing was killed."
        case .notYours: "It belongs to the system or another user. Ports only stops your own processes."
        case .protected: "Ports won't stop this process."
        case .failed(let s): s
        }
    }
}

/// SIGTERM, then SIGKILL after 2 s — re-verifying identity before each signal.
func safeTerminate(pid: pid_t, start: UInt64) -> KillError? {
    guard pid > 1, pid != getpid() else { return .protected }
    guard let id = Proc.identity(pid), id.start == start else { return .gone }
    guard id.uid == getuid() else { return .notYours }
    if kill(pid, SIGTERM) != 0 { return .failed(String(cString: strerror(errno))) }
    for _ in 0..<20 {
        usleep(100_000)
        if Proc.identity(pid)?.start != start { return nil }       // exited
    }
    if Proc.identity(pid)?.start == start { kill(pid, SIGKILL) }
    return nil
}

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
