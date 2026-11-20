import Darwin
import Foundation
import Testing
@testable import PortsCore

func make(_ exe: String, _ argv: [String], port: Int = 4000, uid: uid_t = getuid(), pid: pid_t = 4242,
          ppid: pid_t = 900, parent: String? = nil, deps: [String] = [], cwd: String = "/tmp/demo") -> Listener {
    var l = Listener(port: port, pid: pid, start: 1, uid: uid, exposed: false, exe: exe,
                     command: argv.joined(separator: " "), argv: argv, cwd: cwd)
    l.ppid = ppid
    if let parent { l.chain = [Ancestor(pid: ppid, name: parent, exe: "/opt/demo/bin/" + parent)] }
    if !deps.isEmpty { l.project = Project(root: "/tmp/demo", name: "demo", dependencies: deps) }
    return l
}

struct FrameworkCase: Sendable, CustomTestStringConvertible {
    let framework: Framework
    let name: String
    var testDescription: String { "\(framework.name) via \(name)" }
}

/// One case per (framework, name): the table drives its own tests, so a new row is covered automatically.
let frameworkCases: [FrameworkCase] = frameworks.flatMap { f in f.names.map { FrameworkCase(framework: f, name: $0) } }

@Suite("Phase 3 · Framework table")
struct FrameworkTableTests {
    @Test("Every named framework matcher classifies its own command line", arguments: frameworkCases)
    func everyMatcher(_ c: FrameworkCase) {
        let l = make("/opt/demo/bin/\(c.name)", [c.name] + c.framework.args)
        let r = classifyDetailed(l)
        #expect(r.kind == c.framework.kind)
        #expect(r.framework?.name == c.framework.name)
    }

    static let runtimeCases: [(String, [String], String)] = [
        ("/usr/local/bin/node", ["node", "/tmp/demo/node_modules/.bin/vite", "--port", "5173"], "Vite"),
        ("/usr/local/bin/node", ["node", "/tmp/demo/node_modules/next/dist/bin/next", "dev"], "Next.js"),
        ("/usr/local/bin/node", ["next", "dev", "--turbo"], "Next.js (Turbopack)"),
        ("/usr/local/bin/node", ["npx", "astro", "dev"], "Astro"),
        ("/usr/bin/python3", ["python3", "manage.py", "runserver"], "Django"),
        ("/usr/bin/python3", ["python3", "-m", "uvicorn", "app:app"], "Uvicorn"),
        ("/usr/bin/python3", ["python3", "-m", "streamlit", "run", "app.py"], "Streamlit"),
        ("/usr/bin/php", ["php", "artisan", "serve"], "Laravel"),
        ("/usr/bin/php", ["php", "-S", "localhost:8000"], "PHP built-in server"),
        ("/usr/bin/java", ["java", "-cp", "x.jar", "org.springframework.boot.loader.launch.JarLauncher"], "Spring Boot"),
        ("/usr/bin/java", ["java", "org.apache.catalina.startup.Bootstrap", "start"], "Tomcat"),
        ("/usr/bin/java", ["java", "-jar", "/tmp/demo/target/quarkus-app/quarkus-run.jar"], "Quarkus"),
        ("/opt/demo/bin/mix", ["mix", "phx.server"], "Phoenix"),
        ("/opt/demo/bin/esbuild", ["esbuild", "app.ts", "--serve=8000"], "esbuild serve"),
        ("/opt/demo/bin/kubectl", ["kubectl", "port-forward", "svc/web", "8080:80"], "kubectl port-forward"),
    ]
    @Test("Frameworks run by a runtime are found through the tool it runs", arguments: runtimeCases)
    func viaRuntime(exe: String, argv: [String], expected: String) {
        #expect(classifyDetailed(make(exe, argv)).framework?.name == expected)
    }

    static let contextCases: [(Listener, Kind, String)] = [
        (make("/var/folders/xx/go-build123/b001/exe/server", ["/var/folders/xx/go-build123/b001/exe/server"], parent: "go"),
         Kind.backend, "Go (go run)"),
        (make("/tmp/demo/target/debug/api", ["target/debug/api"], parent: "cargo"), .backend, "Rust (cargo run)"),
        (make("/usr/local/bin/node", ["node", "server.js"], deps: ["express", "dotenv"]), .backend, "Express"),
        (make("/usr/local/bin/node", ["node", "dist/main.js"], deps: ["@nestjs/core"]), .backend, "Nest"),
        (make("/usr/local/bin/node", ["node", "index.js"], deps: ["fastify"]), .backend, "Fastify"),
        (make("/usr/local/bin/bun", ["bun", "run", "src/index.ts"], deps: ["hono"]), .backend, "Hono"),
        (make("/opt/kibana-8.0.0/node/bin/node", ["node", "/opt/kibana-8.0.0/src/cli/dist"]), .backend, "Kibana"),
        (make("/Applications/LM Studio.app/Contents/MacOS/LM Studio", ["LM Studio"]), .ai, "LM Studio"),
        (make("/Applications/Ollama.app/Contents/Resources/ollama", ["ollama", "serve"]), .ai, "Ollama"),
    ]
    @Test("Frameworks recognised by launcher, dependencies or bundled runtime", arguments: contextCases)
    func context(l: Listener, kind: Kind, expected: String) {
        let r = classifyDetailed(l)
        #expect(r.kind == kind)
        #expect(r.framework?.name == expected)
    }

    @Test("Generic runtimes keep the tool as their name; named frameworks use the display name")
    func names() {
        #expect(classifyDetailed(make("/usr/bin/python3", ["python3", "app.py"])).name == "python3")
        #expect(classifyDetailed(make("/usr/local/bin/node", ["node", "server.js"])).name == "node")
        #expect(classifyDetailed(make("/usr/local/bin/vite", ["vite"])).name == "Vite")
        #expect(classifyDetailed(make("/opt/homebrew/bin/redis-server", ["redis-server"])).name == "Redis")
    }
}

@Suite("Phase 3 · Misclassification guards")
struct MisclassificationTests {
    static let guardCases: [(Listener, Kind, String)] = [
        (make("/usr/bin/python3", ["python3", "/tmp/work/astro-dashboard/app.py"]), Kind.backend, "python3"),
        (make("/usr/local/bin/node", ["node", "/tmp/vite-playground/server.js"]), .backend, "node"),
        (make("/usr/bin/python3", ["python3", "serve.py"]), .backend, "python3"),
        (make("/usr/bin/python3", ["python3", "/tmp/postgres-tools/sync.py"]), .backend, "python3"),
        (make("/tmp/next-app/bin/server", ["/tmp/next-app/bin/server"]), .system, "server"),
        (make("/usr/local/bin/node", ["node", "/tmp/mcp-notes/index.js"]), .backend, "node"),     // folder named mcp-…
    ]
    @Test("Folder and file names never pick a framework", arguments: guardCases)
    func guards(l: Listener, kind: Kind, tool: String) {
        let r = classifyDetailed(l)
        #expect(r.kind == kind)
        #expect(r.tool == tool)
    }
}

@Suite("Phase 3 · Categories, confidence and tiers")
struct CategoryTests {
    static let categoryCases: [(Listener, Kind)] = [
        (make("/Users/test/.vscode/extensions/demo.ext-1.0.0/server/node", ["node", "extension.js"]), Kind.app),
        (make("/Applications/Demo.app/Contents/MacOS/Demo", ["Demo"]), .app),
        (make("/System/Library/CoreServices/ControlCenter.app/Contents/MacOS/ControlCenter", ["ControlCenter"], port: 5000), .system),
        (make("/usr/libexec/rapportd", ["rapportd"]), .system),
        (make("/opt/demo/bin/syncd", ["syncd"], ppid: 1), .service),                         // own launchd job
        (make("/opt/demo/bin/syncd", ["syncd"], uid: 0, ppid: 1), .system),                  // someone else's
        (make("/usr/local/bin/node", ["npx", "@modelcontextprotocol/server-filesystem", "/tmp"]), .ai),
        (make("/usr/local/bin/demo-mcp", ["demo-mcp", "--stdio"]), .ai),
        (make("/usr/bin/ssh", ["ssh", "-N", "-L", "15432:db:5432", "bastion"]), .tunnel),
        (make("/opt/homebrew/bin/cloudflared", ["cloudflared", "tunnel", "--url", "http://localhost:3000"]), .tunnel),
    ]
    @Test("Category model", arguments: categoryCases)
    func categories(l: Listener, kind: Kind) { #expect(classifyDetailed(l).kind == kind) }

    static let confidenceCases: [(Listener, Int)] = [
        (make("/usr/local/bin/vite", ["vite"]), 90),
        (make("/usr/bin/php", ["php", "artisan", "serve"]), 85),
        (make("/usr/local/bin/node", ["node", "server.js"]), 50),
        (make("/usr/local/bin/node", ["node", "server.js"], deps: ["express"]), 60),
        (make("/var/folders/xx/go-build1/exe/main", ["main"], parent: "go"), 80),
        (make("/opt/homebrew/bin/postgres", ["postgres", "-D", "/tmp/data"]), 90),
        (make("/usr/libexec/rapportd", ["rapportd"]), 95),
        (make("/opt/demo/bin/unknownd", ["unknownd"]), 30),
    ]
    @Test("Confidence reflects how the match was made", arguments: confidenceCases)
    func confidence(l: Listener, expected: Int) { #expect(classifyDetailed(l).confidence == expected) }

    static let tierCases: [(Listener, SafetyTier)] = [
        (make("/usr/local/bin/vite", ["vite"]), SafetyTier.safe),
        (make("/opt/homebrew/bin/postgres", ["postgres"]), .warning),
        (make("/Applications/Demo.app/Contents/MacOS/Demo", ["Demo"]), .warning),
        (make("/usr/local/bin/vite", ["vite"], uid: getuid() + 1), .blocked),            // another user's
        (make("/sbin/launchd", ["launchd"], pid: 1, ppid: 0), .blocked),
    ]
    @Test("Safety tiers", arguments: tierCases)
    func tiers(l: Listener, tier: SafetyTier) { #expect(classifyDetailed(l).tier == tier) }

    @Test("Every category has a CLI column title of at most 14 characters and a stable id")
    func titles() {
        for k in Kind.allCases {
            #expect(k.shortTitle.count <= 14)
            #expect(Kind(id: k.id) == k)
        }
        #expect(Kind(id: "nope") == nil)
    }
}

@Suite("Phase 3 · Known ports")
struct KnownPortsTableTests {
    @Test("Every port the spec lists has an entry", arguments: [5000, 7000, 3000, 5173, 8080, 8000, 5432, 3306, 6379,
                                                                27017, 9200, 5672, 9092, 11211, 1433, 8123, 9000, 4040,
                                                                631, 88, 445, 548, 2375, 2376, 6443])
    func listed(port: Int) { #expect(KnownPorts.info(port: port) != nil) }

    @Test("AirPlay, ephemeral and unknown ports")
    func specifics() {
        #expect(KnownPorts.info(port: 5000)?.owner.contains("AirPlay") == true)
        #expect(KnownPorts.info(port: 5000)?.howToFree?.contains("AirPlay Receiver") == true)
        #expect(KnownPorts.info(port: 51234)?.owner == "Ephemeral port")
        #expect(KnownPorts.info(port: 1234) == nil)
    }
}

@Suite("Phase 3 · Overrides")
struct OverrideTests {
    func store() -> (OverrideStore, URL) {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ports-p3-\(UUID().uuidString)/overrides.json")
        return (OverrideStore(url: url), url)
    }

    @Test("Overrides persist, reload, and an emptied entry disappears")
    func persist() throws {
        let (s, url) = store()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try s.update("sig") { $0.name = "Shop API"; $0.kind = .backend; $0.favorite = true }
        let reloaded = OverrideStore(url: url)
        #expect(reloaded.override(for: "sig")?.name == "Shop API")
        #expect(reloaded.override(for: "sig")?.kind == .backend)
        #expect(String(decoding: try Data(contentsOf: url), as: UTF8.self).contains("\"backend\""))   // stable id, not rawValue
        try reloaded.update("sig") { $0 = Override() }
        #expect(OverrideStore(url: url).all.isEmpty)
    }

    @Test("Rename, move and flags apply to the row; the same service matches after a restart")
    func apply() throws {
        let (s, url) = store()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var l = make("/usr/local/bin/vite", ["vite"])
        l.kind = .frontend
        try s.update(serviceSignature(l)) { $0.name = "Storefront"; $0.kind = .backend; $0.hidden = true }
        var restarted = l
        restarted = Listener(port: 5174, pid: 9999, start: 77, uid: l.uid, exposed: false, exe: l.exe, command: l.command,
                             argv: l.argv, cwd: l.cwd, kind: .frontend)
        let r = try #require(applyOverrides([restarted], s).first)
        #expect(r.label == "Storefront")
        #expect(r.kind == .backend)
        #expect(r.baseKind == .frontend)
        #expect(r.override?.hidden == true)
    }

    @Test("Moving a database to another category never changes how it is stopped or probed")
    func safetyFollowsDetectedKind() throws {
        let (s, url) = store()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let db = make("/opt/homebrew/bin/postgres", ["postgres"])
        var detected = db
        detected.kind = .database
        try s.update(serviceSignature(detected)) { $0.kind = .frontend }
        let moved = try #require(applyOverrides([detected], s).first)
        #expect(moved.kind == .frontend)
        #expect(StopPolicy(moved) == .dataStore)
        #expect(!StopPolicy(moved).autoForce)
        #expect(!isWebCandidate(moved))
    }

    @Test("Kind decoding rejects unknown ids")
    func badKind() {
        #expect(throws: DecodingError.self) { try JSONDecoder().decode([Kind].self, from: Data(#"["teleporter"]"#.utf8)) }
    }
}

@Suite("Phase 3 · Icons")
struct IconTests {
    @Test("Icon source: linked app, owning bundle, project favicon, category symbol")
    func sources() {
        var helper = make("/Applications/Demo Editor.app/Contents/Frameworks/Demo Helper.app/Contents/MacOS/Demo Helper", ["x"])
        #expect(iconSource(helper) == .app("/Applications/Demo Editor.app"))
        helper.override = { var o = Override(); o.linkedApp = "/Applications/Other.app"; return o }()
        #expect(iconSource(helper) == .app("/Applications/Other.app"))

        var web = make("/usr/local/bin/vite", ["vite"])
        web.kind = .frontend
        web.project = Project(root: "/tmp/demo-site", name: "demo-site")
        #expect(iconSource(web, fileExists: { $0 == "/tmp/demo-site/static/favicon.ico" }) == .favicon("/tmp/demo-site/static/favicon.ico"))
        #expect(iconSource(web, fileExists: { _ in false }) == .symbol(Kind.frontend.symbol))
    }
}
