// Phase 3: data-driven detection. Add a row to `frameworks` to teach Ports a new tool.
//
// Matching never looks at directory names in paths (the working directory or a script's folders):
// only the executable name, argv[0], the script/module/package a runtime runs, argv tokens, the
// launching parent's name, and the project's declared dependencies. `exePath` rules match the
// install location of a bundled runtime (e.g. Kibana's own node), never the user's folders.
import Foundation

/// Who may stop it: `blocked` never (PID 0/1, launchd, kernel, other users), `warning` with a warning
/// (databases, brokers, the container engine, apps, system daemons), `safe` (dev servers you started).
public enum SafetyTier: String, Sendable, Codable, Comparable {
    case safe, warning, blocked
    var rank: Int { switch self { case .safe: 0; case .warning: 1; case .blocked: 2 } }
    public static func < (a: Self, b: Self) -> Bool { a.rank < b.rank }
}

public struct Framework: Sendable, Equatable {
    public let name: String          // display name, e.g. "Next.js"
    public let kind: Kind
    public let names: [String]       // identity tokens (exe, argv0, script, module, npx tool, java main-class part)
    public let args: [String]        // argv tokens that must all be present ("runserver", "-S", "--serve")
    public let parents: [String]     // launching parent's name ("go" for `go run`, "cargo" for `cargo run`)
    public let deps: [String]        // project dependencies (package.json), any one
    public let exePath: String?      // substring of a bundled runtime's install path
    public let defaultPort: Int?
    public let isHTTP: Bool

    init(_ name: String, _ kind: Kind, _ names: [String] = [], args: [String] = [], parents: [String] = [],
         deps: [String] = [], exePath: String? = nil, port: Int? = nil, http: Bool = true) {
        self.name = name; self.kind = kind; self.names = names; self.args = args; self.parents = parents
        self.deps = deps; self.exePath = exePath; self.defaultPort = port; self.isHTTP = http
    }
}

/// Most specific first: a rule with `args` precedes the plain rule for the same name.
public let frameworks: [Framework] = [
    // Frontend
    .init("Next.js (Turbopack)", .frontend, ["next"], args: ["--turbo"], port: 3000),
    .init("Next.js (Turbopack)", .frontend, ["next"], args: ["--turbopack"], port: 3000),
    .init("Next.js", .frontend, ["next", "next-server"], port: 3000),
    .init("Vite", .frontend, ["vite"], port: 5173),
    .init("Nuxt", .frontend, ["nuxt", "nuxi"], port: 3000),
    .init("Astro", .frontend, ["astro"], port: 4321),
    .init("Remix", .frontend, ["remix", "remix-serve"], port: 3000),
    .init("SvelteKit", .frontend, ["svelte-kit"], port: 5173),
    .init("Gatsby", .frontend, ["gatsby"], port: 8000),
    .init("Angular CLI", .frontend, ["ng"], port: 4200),
    .init("Create React App", .frontend, ["react-scripts"], port: 3000),
    .init("Webpack dev server", .frontend, ["webpack-dev-server", "webpack"], port: 8080),
    .init("Parcel", .frontend, ["parcel"], port: 1234),
    .init("Storybook", .frontend, ["storybook", "start-storybook"], port: 6006),
    .init("Expo", .frontend, ["expo"], port: 8081),
    .init("Metro", .frontend, ["react-native"], args: ["start"], port: 8081),
    .init("Metro", .frontend, ["metro"], port: 8081),
    .init("Eleventy", .frontend, ["eleventy"], port: 8080),
    .init("live-server", .frontend, ["live-server"], port: 8080),
    .init("http-server", .frontend, ["http-server"], port: 8080),
    .init("serve", .frontend, ["serve"], port: 3000),
    .init("esbuild serve", .frontend, ["esbuild"], args: ["--serve"], port: 8000),
    .init("Trunk", .frontend, ["trunk"], port: 8080),
    .init("Hugo", .frontend, ["hugo"], port: 1313),
    .init("Jekyll", .frontend, ["jekyll"], port: 4000),

    // Backend: tools named on the command line
    .init("Nest", .backend, ["nest"], port: 3000),
    .init("nodemon", .backend, ["nodemon"]),
    .init("tsx", .backend, ["tsx"]),
    .init("ts-node", .backend, ["ts-node"]),
    .init("Django", .backend, ["manage.py", "django-admin"], port: 8000),
    .init("Flask", .backend, ["flask"], port: 5000),
    .init("FastAPI", .backend, ["fastapi"], port: 8000),
    .init("Uvicorn", .backend, ["uvicorn"], port: 8000),
    .init("Hypercorn", .backend, ["hypercorn"], port: 8000),
    .init("Gunicorn", .backend, ["gunicorn"], port: 8000),
    .init("Tornado", .backend, ["tornado"], port: 8888),
    .init("Jupyter", .backend, ["jupyter", "jupyter-lab", "jupyter-notebook", "jupyter-server", "jupyterlab", "notebook"], port: 8888),
    .init("Streamlit", .backend, ["streamlit"], port: 8501),
    .init("Gradio", .backend, ["gradio"], port: 7860),
    .init("Rails", .backend, ["rails"], port: 3000),
    .init("Puma", .backend, ["puma"], port: 3000),
    .init("Rack", .backend, ["rackup"], port: 9292),
    .init("Phoenix", .backend, ["mix"], args: ["phx.server"], port: 4000),
    .init("Laravel", .backend, ["php"], args: ["artisan", "serve"], port: 8000),
    .init("PHP built-in server", .backend, ["php"], args: ["-S"], port: 8000),
    .init("Spring Boot", .backend, ["springframework"], port: 8080),
    .init("Tomcat", .backend, ["catalina"], port: 8080),
    .init("Jetty", .backend, ["jetty"], port: 8080),
    .init("Quarkus", .backend, ["quarkus-run", "quarkus"], port: 8080),
    .init(".NET", .backend, ["dotnet"], port: 5000),
    .init("Go (air)", .backend, ["air"], port: 8080),
    .init("Strapi", .backend, ["strapi"], port: 1337),
    .init("Supabase", .backend, ["supabase"], port: 54321),
    .init("Hasura", .backend, ["graphql-engine"], port: 8080),
    .init("PostgREST", .backend, ["postgrest"], port: 3000),
    .init("n8n", .backend, ["n8n"], port: 5678),
    .init("Airflow", .backend, ["airflow"], port: 8080),
    .init("Prometheus", .backend, ["prometheus"], port: 9090),
    .init("Grafana", .backend, ["grafana", "grafana-server"], port: 3000),
    .init("Jaeger", .backend, ["jaeger-all-in-one", "jaeger"], port: 16686),
    .init("Mailpit", .backend, ["mailpit"], port: 8025),
    .init("MailHog", .backend, ["mailhog"], port: 8025),
    .init("MinIO", .backend, ["minio"], port: 9000),
    .init("Portainer", .backend, ["portainer"], port: 9443),
    .init("Nginx", .backend, ["nginx"], port: 8080),
    .init("Caddy", .backend, ["caddy"], port: 2019),
    .init("Traefik", .backend, ["traefik"], port: 8080),
    .init("Apache httpd", .backend, ["httpd"], port: 8080),
    .init("Wrangler", .backend, ["wrangler", "workerd"], port: 8787),
    .init("Firebase emulators", .backend, ["firebase"], port: 4000),
    .init("Firestore emulator", .backend, ["cloud-firestore-emulator"], port: 8080),
    .init("LocalStack", .backend, ["localstack"], port: 4566),
    // Backend: recognised by how they were launched, their dependencies, or a bundled runtime
    .init("Kibana", .backend, exePath: "/kibana", port: 5601),
    .init("Go (go run)", .backend, parents: ["go"], port: 8080),
    .init("Rust (cargo run)", .backend, parents: ["cargo"], port: 8080),
    .init("Nest", .backend, deps: ["@nestjs/core"], port: 3000),
    .init("Fastify", .backend, deps: ["fastify"], port: 3000),
    .init("Hono", .backend, deps: ["hono"], port: 3000),
    .init("Koa", .backend, deps: ["koa"], port: 3000),
    .init("Express", .backend, deps: ["express"], port: 3000),
    // Generic runtimes: last, lowest confidence
    .init("Deno", .backend, ["deno"], port: 8000),
    .init("Bun", .backend, ["bun"], port: 3000),
    .init("Node.js", .backend, ["node"]),
    .init("Python", .backend, ["python", "python3"]),
    .init("Ruby", .backend, ["ruby"]),
    .init("PHP", .backend, ["php"]),
    .init("Java", .backend, ["java"]),
    .init("Go", .backend, ["go"]),
    .init("Cargo", .backend, ["cargo"]),

    // Databases and brokers
    .init("PostgreSQL", .database, ["postgres"], port: 5432, http: false),
    .init("MySQL", .database, ["mysqld"], port: 3306, http: false),
    .init("MariaDB", .database, ["mariadbd"], port: 3306, http: false),
    .init("MongoDB", .database, ["mongod"], port: 27017, http: false),
    .init("Redis", .database, ["redis-server"], port: 6379, http: false),
    .init("Valkey", .database, ["valkey-server"], port: 6379, http: false),
    .init("Memcached", .database, ["memcached"], port: 11211, http: false),
    .init("ClickHouse", .database, ["clickhouse"], port: 8123, http: false),
    .init("CockroachDB", .database, ["cockroach"], port: 26257, http: false),
    .init("InfluxDB", .database, ["influxd"], port: 8086, http: false),
    .init("Elasticsearch", .database, ["elasticsearch"], port: 9200, http: false),
    .init("OpenSearch", .database, ["opensearch"], port: 9200, http: false),
    .init("Neo4j", .database, ["neo4j"], port: 7474, http: false),
    .init("CouchDB", .database, ["couchdb"], port: 5984, http: false),
    .init("RabbitMQ", .database, ["rabbitmq"], port: 5672, http: false),
    .init("Kafka", .database, ["kafka"], port: 9092, http: false),
    .init("NATS", .database, ["nats-server"], port: 4222, http: false),
    .init("SurrealDB", .database, ["surreal"], port: 8000, http: false),
    .init("Cassandra", .database, ["cassandra"], port: 9042, http: false),
    .init("SQL Server", .database, ["sqlservr"], port: 1433, http: false),

    // Tunnels & forwards (display only)
    .init("ngrok", .tunnel, ["ngrok"], port: 4040),
    .init("cloudflared", .tunnel, ["cloudflared"], http: false),
    .init("kubectl port-forward", .tunnel, ["kubectl"], args: ["port-forward"], http: false),
    .init("SSH forward", .tunnel, ["ssh"], http: false),
    .init("gcloud IAP tunnel", .tunnel, ["gcloud"], http: false),
    .init("AWS SSM port forward", .tunnel, ["session-manager-plugin"], http: false),
    .init("Cloud SQL proxy", .tunnel, ["cloud-sql-proxy", "cloud_sql_proxy"], http: false),
    .init("Tailscale", .tunnel, ["tailscaled", "tailscale"], http: false),

    // AI & agents
    .init("Ollama", .ai, ["ollama"], port: 11434),
    .init("LM Studio", .ai, exePath: "/LM Studio.app/", port: 1234),
    .init("llama.cpp server", .ai, ["llama-server"], port: 8080),
    .init("vLLM", .ai, ["vllm"], port: 8000),
]

/// Dev apps and editor helpers: they embed node/java, but you didn't start them.
let appTools = ["claude", "agy", "electron"]
let wellKnownPorts = [5432: "postgres", 3306: "mysql", 6379: "redis", 27017: "mongo", 9200: "elasticsearch",
                      5672: "rabbitmq", 11211: "memcached", 1433: "sql server"]
let genericRuntimes: Set = ["Deno", "Bun", "Node.js", "Python", "Ruby", "PHP", "Java", "Go", "Cargo"]
let osPathPrefixes = ["/System/", "/usr/libexec/", "/usr/sbin/", "/sbin/"]

func toolNames(_ kind: Kind) -> [String] {
    var seen = Set<String>(), out: [String] = []
    for f in frameworks where f.kind == kind { for n in f.names where seen.insert(n).inserted { out.append(n) } }
    return out
}
let dbNames = toolNames(.database)
let frontendTools = toolNames(.frontend)
let backendTools = toolNames(.backend)
let tunnelTools = toolNames(.tunnel)
let aiTools = toolNames(.ai)

/// `t` names `tool` exactly, or as `tool.ext` / `tool-suffix` ("python3.12", "next-server", "quarkus-run.jar").
func nameMatches(_ t: String, _ tool: String) -> Bool { t == tool || t.hasPrefix(tool + ".") || t.hasPrefix(tool + "-") }

func matches(_ toks: [String], _ tools: [String]) -> String? {
    for t in toks { for tool in tools where nameMatches(t, tool) { return tool } }
    return nil
}

/// "--serve" also matches "--serve=8000".
func hasArgs(_ argv: [String], _ needed: [String]) -> Bool {
    needed.allSatisfy { a in argv.contains { $0 == a || $0.hasPrefix(a + "=") } }
}

/// "Visual Studio Code", "VS Code ext: oracle.sql-developer", "rapportd"…
public func appName(_ exe: String) -> String {
    if let r = exe.range(of: "/.vscode/extensions/") {
        let ext = exe[r.upperBound...].split(separator: "/").first.map(String.init) ?? ""
        return "VS Code ext: " + ext.replacingOccurrences(of: #"-\d.*$"#, with: "", options: .regularExpression)
    }
    if let r = exe.range(of: ".app/") { return basename(String(exe[..<r.lowerBound])) }
    return basename(exe)
}

public struct Classification: Equatable, Sendable {
    public var kind: Kind
    public var tool: String               // the matched token, e.g. "vite", "manage.py", "python3"
    public var framework: Framework?      // the table row, when one matched
    public var confidence: Int            // 0–100
    public var tier: SafetyTier
    /// Row name: the framework's display name, else the tool. Generic runtimes keep the tool ("python3").
    public var name: String {
        guard let f = framework, !genericRuntimes.contains(f.name) else { return tool }
        return f.name
    }
}

/// The first framework of `kind` whose names include `tool` and whose argv/parent/deps rules hold.
func refine(_ kind: Kind, tool: String, argv: [String]) -> Framework? {
    frameworks.first { f in
        f.kind == kind && f.names.contains(tool) && f.parents.isEmpty && f.deps.isEmpty && f.exePath == nil
            && hasArgs(argv, f.args)
    }
}

/// A rule without names (launch parent, dependency, bundled runtime) that holds for this listener.
func contextFramework(_ l: Listener, kinds: Set<Kind>) -> Framework? {
    let parent = l.chain.first?.name.lowercased()
    let deps = Set(l.project?.dependencies ?? [])
    return frameworks.first { f in
        guard kinds.contains(f.kind), f.names.isEmpty else { return false }
        if let p = f.exePath { return l.exe.contains(p) }
        if !f.parents.isEmpty { return parent.map(f.parents.contains) ?? false }
        if !f.deps.isEmpty { return !deps.isDisjoint(with: f.deps) }
        return false
    }
}

func tier(_ kind: Kind, _ l: Listener, uid: uid_t) -> SafetyTier {
    if l.pid <= 1 || basename(l.exe) == "launchd" || l.uid != uid { return .blocked }
    return kind == .frontend || kind == .backend ? .safe : .warning
}

/// Category, tool, framework, confidence and safety tier for one listener.
public func classifyDetailed(_ l: Listener, uid: uid_t = getuid()) -> Classification {
    func done(_ kind: Kind, _ tool: String, _ fw: Framework? = nil, _ confidence: Int) -> Classification {
        Classification(kind: kind, tool: tool, framework: fw, confidence: confidence, tier: tier(kind, l, uid: uid))
    }
    let names = identityNames(exe: l.exe, argv: l.argv)
    let exeName = names[0]
    let argv0 = names.count > 1 ? names[1] : exeName
    let specific = Array(names.dropFirst())

    if let c = l.container { return done(.docker, c, nil, 95) }
    if let runtime = containerRuntime(exe: l.exe) {
        let guess = wellKnownPorts[l.port].map { "\($0)? · " } ?? ""
        return done(.docker, "\(guess)\(runtime) engine", nil, 90)
    }
    // A script run by node/python is not a database just because of its file name; a java main class can be.
    let dbCandidates = isInterpreter(exeName) && exeName != "java" ? Array(names.prefix(2)) : names
    if let db = matches(dbCandidates, dbNames) {
        return done(.database, db, refine(.database, tool: db, argv: l.argv), names.prefix(2).contains { nameMatches($0, db) } ? 90 : 75)
    }
    let isOS = osPathPrefixes.contains(where: l.exe.hasPrefix)
    if isOS { return done(.system, appName(l.exe), nil, 95) }
    // Tunnels and model servers by name (before apps: Ollama.app ships an `ollama` binary).
    for (kind, tools) in [(Kind.tunnel, tunnelTools), (.ai, aiTools)] {
        if let t = matches(names, tools), let fw = refine(kind, tool: t, argv: l.argv) { return done(kind, t, fw, 85) }
    }
    if let fw = contextFramework(l, kinds: [.ai]) { return done(.ai, fw.name, fw, 80) }
    // MCP servers: "mcp-server-x", "x-mcp", or the official `@modelcontextprotocol/server-*` packages.
    if names.contains(where: { $0.contains("mcp") }) || l.argv.contains(where: { $0.hasPrefix("@modelcontextprotocol/") }) {
        return done(.ai, names.last { $0.contains("mcp") } ?? names.last ?? argv0, nil, 70)
    }
    if appTools.contains(argv0) || l.exe.contains("/.vscode/extensions/") || l.exe.contains("/.gemini/")
        || (l.exe.contains(".app/") && !backendTools.contains(exeName)) {
        return done(.app, appTools.contains(argv0) ? argv0 : appName(l.exe), nil, 85)
    }
    // Most specific first: the tool a runtime is running beats the runtime itself (node -> next).
    // Frontend tools are JS tools: a python script called "serve.py" is not the `serve` package.
    let jsOrNative = !isInterpreter(exeName) || ["node", "bun", "deno"].contains(exeName)
    let feCandidates = jsOrNative ? specific : Array(specific.prefix(1))
    if let fe = matches(feCandidates, frontendTools) ?? matches([exeName], frontendTools) {
        return done(.frontend, fe, refine(.frontend, tool: fe, argv: l.argv), 90)
    }
    if let be = matches(specific.reversed(), backendTools) ?? matches([exeName], backendTools) {
        let named = refine(.backend, tool: be, argv: l.argv)
        let generic = named.map { genericRuntimes.contains($0.name) } ?? true
        let isRuntime = isInterpreter(be) || ["deno", "bun", "go", "cargo"].contains(be)
        if isRuntime, generic, let fw = contextFramework(l, kinds: [.backend]) { return done(.backend, be, fw, 60) }
        return done(.backend, be, named, isRuntime && generic ? 50 : (named?.args.isEmpty == false ? 85 : 90))
    }
    if let fw = contextFramework(l, kinds: [.backend, .frontend]) { return done(fw.kind, appName(l.exe), fw, 80) }
    if l.ppid == 1 && l.uid == uid { return done(.service, appName(l.exe), nil, 40) }
    return done(.system, appName(l.exe), nil, 30)
}

public func classify(_ l: Listener) -> (Kind, String) {
    let c = classifyDetailed(l)
    return (c.kind, c.tool)
}
