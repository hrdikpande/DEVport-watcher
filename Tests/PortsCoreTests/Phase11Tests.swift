import Darwin
import Foundation
import Testing
@testable import PortsCore

func cliRow(_ port: Int, kind: Kind = .backend, uid: uid_t = getuid(), pid: pid_t = 300, start: UInt64 = 1,
            framework: String? = nil, cwd: String = "/tmp/demo/app") -> Listener {
    var l = Listener(port: port, pid: pid, start: start, uid: uid, exposed: false, exe: "/usr/local/bin/node", command: "node server.js",
                     argv: ["node", "server.js"], cwd: cwd, kind: kind, label: "node · demo")
    l.framework = framework
    l.tier = kind == .frontend || kind == .backend ? .safe : .warning
    if uid != getuid() { l.tier = .blocked }
    return l
}

/// The built `ports` executable next to the test bundle (built by `swift build --build-tests`).
func cliPath() -> String? {
    var dir = Bundle(for: CLIMarker.self).bundleURL.deletingLastPathComponent()
    for _ in 0..<3 {
        let p = dir.appendingPathComponent(Brand.cliName).path
        if FileManager.default.isExecutableFile(atPath: p) { return p }
        dir = dir.deletingLastPathComponent()
    }
    return nil
}
final class CLIMarker {}

/// Run the CLI with an isolated support folder (never the user's settings/history); stdin is /dev/null (non-interactive).
func runCLI(_ args: [String], supportDir: String) throws -> (code: Int32, out: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: try #require(cliPath()))
    p.arguments = args
    p.environment = ["PORTS_SUPPORT_DIR": supportDir, "HOME": NSTemporaryDirectory(), "PATH": "/usr/bin:/bin"]
    let out = Pipe()
    p.standardOutput = out
    p.standardError = out
    p.standardInput = FileHandle.nullDevice
    try p.run()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: data, as: UTF8.self))
}

@Suite("Phase 11 · Query and JSON")
struct QueryTests11 {
    @Test("--since and --range parsing", arguments: [("30m", 1800.0), ("2h", 7200), ("1d", 86_400), ("45s", 45)])
    func since(text: String, seconds: Double) {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(parseSince(text, now: now) == now.addingTimeInterval(-seconds))
    }

    @Test("Invalid --since and --range")
    func invalid() {
        #expect(parseSince("soon") == nil && parseSince("5y") == nil && parseSince("") == nil)
        #expect(parseRange("3000-3999") == 3000...3999)
        #expect(parseRange("4000-3000") == nil && parseRange("0-10") == nil && parseRange("3000") == nil)
        #expect(parseSince("today") != nil)
    }

    @Test("Filters: default developer view, --all, category, project, dir, port, range, since, orphans; sort")
    func filters() {
        var web = cliRow(3000, kind: .frontend, start: 2_000_000_000_000_000)
        web.project = Project(root: "/tmp/demo/shop", name: "shop")
        let api = cliRow(8000, pid: 301, start: 1_000_000, cwd: "/tmp/other")
        var app = cliRow(9090, kind: .app, pid: 302, cwd: "/tmp/elsewhere"); app.memory = 999
        let ls = [app, api, web]
        var a = Analysis()
        a.verdicts[processKey(api)] = OrphanVerdict(level: .confirmed, evidence: ["x"], safeToStop: .green)
        var q = ListQuery()
        #expect(applyQuery(ls, q, analysis: a).map(\.port) == [3000, 8000])
        q.all = true
        #expect(applyQuery(ls, q, analysis: a).map(\.port) == [3000, 8000, 9090])
        q.sort = "mem"
        #expect(applyQuery(ls, q, analysis: a).first?.port == 9090)
        q = ListQuery(); q.category = .app
        #expect(applyQuery(ls, q, analysis: a).map(\.port) == [9090])
        q = ListQuery(); q.project = "SHOP"
        #expect(applyQuery(ls, q, analysis: a).map(\.port) == [3000])
        q = ListQuery(); q.dir = "/tmp/demo"
        #expect(applyQuery(ls, q, analysis: a).map(\.port) == [3000])
        q = ListQuery(); q.range = 7000...8500
        #expect(applyQuery(ls, q, analysis: a).map(\.port) == [8000])
        q = ListQuery(); q.since = Date(timeIntervalSince1970: 1_000_000_000)
        #expect(applyQuery(ls, q, analysis: a).map(\.port) == [3000])
        q = ListQuery(); q.orphans = true
        #expect(applyQuery(ls, q, analysis: a).map(\.port) == [8000])
    }

    @Test("JSON envelope decodes and its keys match the published schema")
    func schema() throws {
        var l = cliRow(5432, kind: .database, framework: "PostgreSQL")
        l.project = Project(root: "/tmp/demo", name: "demo", branch: "main")
        var a = Analysis()
        a.verdicts[processKey(l)] = OrphanVerdict(level: .likely, evidence: ["e"], safeToStop: .green)
        let text = jsonString(envelope([l], analysis: a, now: Date(timeIntervalSince1970: 0)))
        let back = try JSONDecoder().decode(ListEnvelope.self, from: Data(text.utf8))
        #expect(back.schemaVersion == jsonSchemaVersion && back.ports.first?.database?.type == "postgres" && back.ports.first?.orphan?.level == "likely")
        let schemaURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/schema/ports-list.schema.json")
        let schema = try JSONSerialization.jsonObject(with: Data(contentsOf: schemaURL)) as! [String: Any]
        let props = (((schema["properties"] as! [String: Any])["ports"] as! [String: Any])["items"] as! [String: Any])["properties"] as! [String: Any]
        let obj = try JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
        let keys = Set(((obj["ports"] as! [[String: Any]])[0]).keys)
        #expect(keys.isSubset(of: Set(props.keys)), "\(keys.subtracting(props.keys))")
        let required = Set((((schema["properties"] as! [String: Any])["ports"] as! [String: Any])["items"] as! [String: Any])["required"] as! [String])
        #expect(required.isSubset(of: keys), "\(required.subtracting(keys))")
    }
}

@Suite("Phase 11 · Stop rules (CLI and MCP)")
struct StopRuleTests11 {
    let sig = { (l: Listener) in [StopMethod.signal(StopTarget(l))] }

    @Test("CLI: --yes proceeds for dev servers; refuses others' processes, protected ports and explanations")
    func cli() {
        let dev = cliRow(3000)
        #expect(cliStopDecision(dev, methods: sig(dev), settings: Settings(), yes: true) == .proceed(.signal(StopTarget(dev))))
        if case .confirm = cliStopDecision(dev, methods: sig(dev), settings: Settings(), yes: false) {} else { Issue.record("needs confirm") }
        let other = cliRow(3000, uid: getuid() + 1)
        if case .refuse = cliStopDecision(other, methods: sig(other), settings: Settings(), yes: true) {} else { Issue.record("other user") }
        var s = Settings(); s.protectedPorts = [3000]
        if case .refuse(let why) = cliStopDecision(dev, methods: sig(dev), settings: s, yes: true) { #expect(why.contains("protected")) }
        else { Issue.record("protected") }
        if case .refuse = cliStopDecision(dev, methods: [.explain("macOS restarts it")], settings: Settings(), yes: true) {} else { Issue.record("explain") }
    }

    @Test("CLI: --yes never bypasses the database warning; apps get the gentle ladder")
    func databasesAndApps() {
        let db = cliRow(5432, kind: .database, framework: "PostgreSQL")
        if case .confirm(let text, _) = cliStopDecision(db, methods: sig(db), settings: Settings(), yes: true) { #expect(text.contains("lose")) }
        else { Issue.record("db must confirm") }
        let app = cliRow(9000, kind: .app)
        let d = cliStopDecision(app, methods: [.app(bundle: "/Applications/Demo.app", pid: app.pid)], settings: Settings(), yes: true)
        guard case .proceed(.signal(let t)) = d else { Issue.record("app → signal, got \(d)"); return }
        #expect(!t.policy.autoForce)
    }

    @Test("MCP stop: off by default; only own safe-tier dev servers when allowed", arguments: [
        (cliRow(3000), true), (cliRow(3000, uid: getuid() + 1), false), (cliRow(5432, kind: .database, framework: "PostgreSQL"), false),
        (cliRow(9000, kind: .app), false), (cliRow(631, kind: .system), false), (cliRow(9001, kind: .service), false),
        ({ var c = cliRow(55432, kind: .docker); c.container = "db"; return c }(), false),
        ({ var d = cliRow(6380); d.probedDatabase = .redis; return d }(), false),
    ] as [(Listener, Bool)])
    func mcpGate(l: Listener, allowed: Bool) {
        #expect(mcpStopRefusal(l, settings: Settings()) != nil)                     // default: always refused
        var s = Settings(); s.mcpEnabled = true
        #expect(mcpStopRefusal(l, settings: s) != nil)                              // enabled but stop not allowed
        s.mcpAllowStop = true
        #expect((mcpStopRefusal(l, settings: s) == nil) == allowed)
        s.protectedPorts = [l.port]
        #expect(mcpStopRefusal(l, settings: s) != nil)
    }
}

final class StopLog: @unchecked Sendable {
    private let lock = NSLock(); private var ports: [Int] = []
    func add(_ p: Int) { lock.lock(); ports.append(p); lock.unlock() }
    var all: [Int] { lock.lock(); defer { lock.unlock() }; return ports }
}

@Suite("Phase 11 · MCP server")
struct MCPTests11 {
    func server(_ settings: Settings = Settings(), log: StopLog = StopLog()) -> MCPServer {
        var env = MCPEnvironment()
        let rows = [cliRow(3000, kind: .frontend, framework: "Vite", cwd: "/tmp/demo/web"), cliRow(5432, kind: .database, pid: 301, framework: "PostgreSQL")]
        env.scan = { rows }
        env.analyze = { _ in Analysis() }
        env.settings = { settings }
        env.checkPort = { p, ls in PortCheck(port: p, owners: owners(ofPort: p, in: ls), attempts: []) }
        env.nextFree = { from, _ in from + 1 }
        env.stop = { l in log.add(l.port); return "stopped" }
        return MCPServer(env: env)
    }
    func call(_ s: MCPServer, _ name: String, _ args: String = "{}") throws -> [String: Any] {
        let reply = try #require(s.handle(#"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"\#(name)","arguments":\#(args)}}"#))
        return try #require(JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any])
    }
    func text(_ r: [String: Any]) -> String { (((r["result"] as? [String: Any])?["content"] as? [[String: Any]])?.first?["text"] as? String) ?? "" }
    func isError(_ r: [String: Any]) -> Bool { (r["result"] as? [String: Any])?["isError"] as? Bool ?? false }

    @Test("initialize, tools/list, ping, notifications, errors")
    func protocolBasics() throws {
        let s = server()
        let ini = try #require(s.handle(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#))
        #expect(ini.contains(MCPServer.protocolVersion) && ini.contains("\"tools\""))
        let list = try #require(s.handle(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#))
        for t in ["list_ports", "explain_port", "is_port_free", "find_free_port", "list_orphans", "project_servers", "stop_port"] {
            #expect(list.contains("\"\(t)\""))
        }
        #expect(s.handle(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == nil)
        #expect(s.handle(#"{"jsonrpc":"2.0","id":3,"method":"ping"}"#)?.contains("\"result\"") == true)
        #expect(s.handle("not json")?.contains("-32700") == true)
        #expect(s.handle(#"{"jsonrpc":"2.0","id":4,"method":"bogus"}"#)?.contains("-32601") == true)
    }

    @Test("Read-only tools answer from the scan")
    func tools() throws {
        let s = server()
        let lp = try call(s, "list_ports")
        #expect(text(lp).contains("\"port\" : 3000") && !isError(lp))
        #expect(text(try call(s, "explain_port", #"{"port":5432}"#)).contains("PostgreSQL"))
        #expect(text(try call(s, "explain_port", #"{"port":1}"#)).contains("Nothing is listening"))
        #expect(text(try call(s, "is_port_free", #"{"port":3000}"#)).contains("\"free\" : \"false\""))
        #expect(text(try call(s, "find_free_port", #"{"from":4000}"#)) == "4001")
        #expect(text(try call(s, "project_servers", #"{"dir":"/tmp/demo/web"}"#)).contains("3000"))
        #expect(isError(try call(s, "project_servers", #"{"dir":"relative"}"#)))
        #expect(isError(try call(s, "explain_port", #"{"port":"x"}"#)))
        #expect(isError(try call(s, "nope")))
    }

    @Test("stop_port is refused by default and for databases; allowed for a dev server only when switched on")
    func stopGate() throws {
        let log = StopLog()
        let off = try call(server(log: log), "stop_port", #"{"port":3000}"#)
        #expect(isError(off) && text(off).contains("Refused"))
        var s = Settings(); s.mcpEnabled = true; s.mcpAllowStop = true
        let on = server(s, log: log)
        #expect(isError(try call(on, "stop_port", #"{"port":5432}"#)))
        #expect(!isError(try call(on, "stop_port", #"{"port":3000}"#)))
        #expect(log.all == [3000])
    }
}

@Suite("Phase 11 · CLI exit codes", .serialized, .enabled(if: cliPath() != nil))
struct ExitCodeTests11 {
    let support = NSTemporaryDirectory() + "ports-p11-\(UUID().uuidString)"

    @Test("Usage 64, not found 1, preflight 0 or 1, MCP off 2")
    func codes() throws {
        defer { try? FileManager.default.removeItem(atPath: support) }
        #expect(try runCLI(["frobnicate"], supportDir: support).code == 64)
        #expect(try runCLI(["list", "--sort", "nonsense"], supportDir: support).code == 64)
        var closed = 0
        do { let s = try TestListener(); closed = s.port }
        let busy = try TestListener()
        #expect(try runCLI(["preflight", String(busy.port)], supportDir: support).code == 1)
        let free = try runCLI(["preflight", String(closed)], supportDir: support)
        #expect(free.code == 0 || free.code == 1)                     // the closed port may have been reused meanwhile
        #expect(try runCLI(["explain", "1"], supportDir: support).code == 1)
        #expect(try runCLI(["mcp"], supportDir: support).code == 2)
        let json = try runCLI(["list", "--json", "--port", String(busy.port)], supportDir: support)
        #expect(json.code == 0 && json.out.contains("\"schemaVersion\" : 1"))
        let next = try runCLI(["next-free", "--from", String(busy.port)], supportDir: support)
        #expect(next.code == 0 && Int(next.out.trimmingCharacters(in: .whitespacesAndNewlines)).map { $0 > busy.port } == true)
    }

    @Test("stop: non-interactive without --yes needs confirmation (3); --yes stops its own child (0) and logs it")
    func stop() throws {
        defer { try? FileManager.default.removeItem(atPath: support) }
        let perl = Process()
        perl.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        perl.arguments = ["-MIO::Socket::INET", "-e",
                          "my $s = IO::Socket::INET->new(Listen => 5, LocalAddr => '127.0.0.1', LocalPort => 0) or die; $| = 1; print $s->sockport, \"\\n\"; sleep 60;"]
        let out = Pipe()
        perl.standardOutput = out
        try perl.run()
        defer { if perl.isRunning { perl.terminate() }; perl.waitUntilExit() }
        var text = ""
        while !text.contains("\n") { let d = out.fileHandleForReading.availableData; if d.isEmpty { break }; text += String(decoding: d, as: UTF8.self) }
        let port = try #require(Int(text.trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(try runCLI(["stop", "pid:\(perl.processIdentifier)"], supportDir: support).code == 3)
        #expect(perl.isRunning)
        #expect(try runCLI(["stop", "--dry-run", "--yes", String(port)], supportDir: support).code == 0)
        #expect(perl.isRunning)
        let r = try runCLI(["stop", "--yes", "pid:\(perl.processIdentifier)"], supportDir: support)
        #expect(r.code == 0, "\(r.out)")
        perl.waitUntilExit()
        let history = try runCLI(["history", "--json"], supportDir: support)
        #expect(history.out.contains("\"by\" : \"cli\""))
    }
}
