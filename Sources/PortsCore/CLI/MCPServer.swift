// Phase 11: `ports mcp` — a Model Context Protocol server over stdio (JSON-RPC 2.0, one message per line).
// Read-only tools, plus `stop_port`, which is refused unless the user turned it on (see `mcpStopRefusal`).
import Darwin
import Foundation

public struct MCPEnvironment: Sendable {
    public var scan: @Sendable () -> [Listener] = { scanWithContainers() }
    public var analyze: @Sendable ([Listener]) -> Analysis = { PortsCore.analyze($0, includeLeftovers: true) }
    public var settings: @Sendable () -> Settings = { SettingsStore().settings }
    public var checkPort: @Sendable (Int, [Listener]) -> PortCheck = { PortsCore.checkPort($0, listeners: $1) }
    public var nextFree: @Sendable (Int, [Listener]) -> Int? = { nextFreePort(from: $0, listeners: $1) }
    /// Runs the stop through the core ladder and returns the outcome; also records history and notifies.
    public var stop: @Sendable (Listener) -> String = { l in
        let out = stopAll([StopTarget(l)], registry: StopRegistry())[0]
        HistoryStore().append([HistoryEvent(at: Date(), kind: .stop, port: l.port, pid: l.pid, name: l.label, by: "mcp",
                                            method: "signal ladder", result: out.summary)])
        return out.summary
    }
    public init() {}
}

public final class MCPServer: @unchecked Sendable {
    public static let protocolVersion = "2024-11-05"
    let env: MCPEnvironment
    public init(env: MCPEnvironment = MCPEnvironment()) { self.env = env }

    static let tools: [[String: Any]] = [
        tool("list_ports", "Listening ports on this Mac with process, framework, project, branch, exposure and orphan verdict.",
             ["all": ["type": "boolean", "description": "Include apps, services and system processes"],
              "project": ["type": "string", "description": "Only this project name"]]),
        tool("explain_port", "Everything known about one port: owners, why it is running, who started it, safe to stop?",
             ["port": ["type": "integer"]], required: ["port"]),
        tool("is_port_free", "Whether a port can be bound (checks visible owners and tries to bind 127.0.0.1, ::1, 0.0.0.0).",
             ["port": ["type": "integer"]], required: ["port"]),
        tool("find_free_port", "The first free port at or above `from`.", ["from": ["type": "integer", "description": "Default 3000"]]),
        tool("list_orphans", "Processes nothing owns any more (likely or confirmed), with evidence.", [:]),
        tool("project_servers", "Servers whose project or working directory is inside `dir`.", ["dir": ["type": "string"]], required: ["dir"]),
        tool("stop_port", "Stop the dev server on a port. Off unless the user enabled “Allow agents to stop processes”; never stops databases, containers, apps or system processes.",
             ["port": ["type": "integer"]], required: ["port"]),
    ]

    static func tool(_ name: String, _ description: String, _ props: [String: Any], required: [String] = []) -> [String: Any] {
        ["name": name, "description": description, "inputSchema": ["type": "object", "properties": props, "required": required]]
    }

    /// One JSON-RPC message in, at most one line out (nil for notifications).
    public func handle(_ line: String) -> String? {
        guard let data = line.data(using: .utf8), let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return encode(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"]])
        }
        let id = msg["id"]
        guard let method = msg["method"] as? String else {
            return id == nil ? nil : encode(["jsonrpc": "2.0", "id": id!, "error": ["code": -32600, "message": "Invalid request"]])
        }
        if id == nil { return nil }                                  // notifications (e.g. notifications/initialized)
        let params = msg["params"] as? [String: Any] ?? [:]
        let result: Any
        switch method {
        case "initialize":
            result = ["protocolVersion": Self.protocolVersion, "capabilities": ["tools": [:]],
                      "serverInfo": ["name": Brand.cliName, "version": "1.0.0"]]
        case "ping": result = [:] as [String: Any]
        case "tools/list": result = ["tools": Self.tools]
        case "tools/call":
            let name = params["name"] as? String ?? ""
            let args = params["arguments"] as? [String: Any] ?? [:]
            let (text, isError) = call(name, args)
            result = ["content": [["type": "text", "text": text]], "isError": isError]
        default:
            return encode(["jsonrpc": "2.0", "id": id!, "error": ["code": -32601, "message": "Method not found: \(method)"]])
        }
        return encode(["jsonrpc": "2.0", "id": id!, "result": result])
    }

    func encode(_ obj: [String: Any]) -> String {
        (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .withoutEscapingSlashes]))
            .map { String(decoding: $0, as: UTF8.self) } ?? #"{"jsonrpc":"2.0","error":{"code":-32603,"message":"encode"}}"#
    }

    func int(_ v: Any?) -> Int? { (v as? Int) ?? (v as? Double).map(Int.init) ?? (v as? String).flatMap(Int.init) }

    func call(_ name: String, _ args: [String: Any]) -> (String, Bool) {
        let ls = env.scan()
        switch name {
        case "list_ports":
            var q = ListQuery()
            q.all = args["all"] as? Bool ?? false
            q.project = args["project"] as? String
            let a = env.analyze(ls)
            return (jsonString(envelope(applyQuery(ls, q, analysis: a), analysis: a)), false)
        case "explain_port":
            guard let port = int(args["port"]), (1...65535).contains(port) else { return ("`port` must be 1–65535.", true) }
            let a = env.analyze(ls)
            let found = owners(ofPort: port, in: ls)
            if found.isEmpty { return ("Nothing is listening on port \(port). " + (KnownPorts.info(port: port).map { "Usually: \($0.owner)." } ?? ""), false) }
            return (jsonString(found.map { portJSON($0, analysis: a) }), false)
        case "is_port_free":
            guard let port = int(args["port"]), (1...65535).contains(port) else { return ("`port` must be 1–65535.", true) }
            let c = env.checkPort(port, ls)
            return (jsonString(["port": "\(port)", "free": c.free ? "true" : "false", "message": c.message]), false)
        case "find_free_port":
            let from = int(args["from"]) ?? 3000
            guard (1...65535).contains(from) else { return ("`from` must be 1–65535.", true) }
            return env.nextFree(from, ls).map { (String($0), false) } ?? ("No free port near \(from).", true)
        case "list_orphans":
            let a = env.analyze(ls)
            let rows = ls.filter { (a.verdict($0)?.level ?? .notOrphan) >= .likely }
            let left = a.leftovers.map { ["pid": "\($0.process.pid)", "tool": $0.tool, "evidence": $0.verdict.evidence.joined(separator: " ")] }
            return ("{\"ports\": \(jsonString(rows.map { portJSON($0, analysis: a) })), \"leftovers\": \(jsonString(left))}", false)
        case "project_servers":
            guard let dir = args["dir"] as? String, dir.hasPrefix("/") else { return ("`dir` must be an absolute path.", true) }
            var q = ListQuery(); q.dir = dir; q.all = true
            let a = env.analyze(ls)
            return (jsonString(envelope(applyQuery(ls, q, analysis: a), analysis: a)), false)
        case "stop_port":
            guard let port = int(args["port"]), (1...65535).contains(port) else { return ("`port` must be 1–65535.", true) }
            let found = owners(ofPort: port, in: ls)
            guard !found.isEmpty else { return ("Nothing is listening on port \(port).", true) }
            let settings = env.settings()
            if let why = found.lazy.compactMap({ mcpStopRefusal($0, settings: settings) }).first { return ("Refused: " + why, true) }
            return (found.map(env.stop).joined(separator: "\n"), false)
        default:
            return ("Unknown tool \(name).", true)
        }
    }

    /// Serve until stdin closes.
    public func run(output: FileHandle = .standardOutput) {
        while let line = readLine(strippingNewline: true) {
            if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            if let reply = handle(line) { output.write(Data((reply + "\n").utf8)) }
        }
    }
}
