import Darwin
import Foundation
import Testing
@testable import PortsCore

// MARK: - Helpers

/// A fresh temp folder with the given files (path relative to the folder -> contents; "x/" makes a folder).
struct TempTree {
    let root: String
    init(_ files: [String: String]) throws {
        root = (NSTemporaryDirectory() as NSString).appendingPathComponent("ports-p2-\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(atPath: root, withIntermediateDirectories: true)
        for (path, text) in files {
            let full = root + "/" + path
            if path.hasSuffix("/") {
                try fm.createDirectory(atPath: full, withIntermediateDirectories: true)
            } else {
                try fm.createDirectory(atPath: (full as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                try Data(text.utf8).write(to: URL(fileURLWithPath: full))
            }
        }
    }
    func path(_ p: String) -> String { p.isEmpty ? root : root + "/" + p }
    func remove() { try? FileManager.default.removeItem(atPath: root) }
}

/// Connect to a loopback listener of this process and accept it, so both ends are open.
func loopbackConnection(to listener: TestListener) throws -> (client: Int32, server: Int32) {
    let c = socket(AF_INET, SOCK_STREAM, 0)
    guard c >= 0 else { throw POSIXError(.EIO) }
    var a = sockaddr_in()
    a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    a.sin_family = sa_family_t(AF_INET)
    a.sin_port = UInt16(listener.port).bigEndian
    a.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
    let ok = withUnsafePointer(to: &a) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(c, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 }
    }
    guard ok else { Darwin.close(c); throw POSIXError(.ECONNREFUSED) }
    let s = accept(listener.fd, nil, nil)
    guard s >= 0 else { Darwin.close(c); throw POSIXError(.EIO) }
    return (c, s)
}

func row(port: Int, pid: pid_t, ppid: pid_t, uid: uid_t = 501, chain: [pid_t] = [], connections: Int = 0,
         exposure: Exposure = .loopback) -> Listener {
    var l = Listener(port: port, pid: pid, start: 1, uid: uid, exposed: exposure.isNetworkReachable, exposure: exposure,
                     exe: "/opt/demo/bin/gunicorn", command: "gunicorn app:app", cwd: "/tmp/demo", kind: .backend,
                     label: "gunicorn")
    l.ppid = ppid
    l.chain = chain.map { Ancestor(pid: $0, name: "p\($0)", exe: "/bin/p") }
    l.connections = connections
    return l
}

// MARK: - 1. Parent, tree, TTY

@Suite("Phase 2 · Process tree")
struct ProcessTreeTests {
    static let argCases: [([String], [String])] = [
        (["node", "server.js"], ["PORT=3000", "HOME=/tmp/demo"]),
        (["python3", "", "-m", "http.server"], []),
        (["sleep"], ["A=1"]),
    ]
    @Test("KERN_PROCARGS2 buffers split into argv and environment", arguments: argCases)
    func procArgs(argv: [String], env: [String]) {
        var buf = withUnsafeBytes(of: Int32(argv.count)) { Array($0) }
        buf += Array("/bin/exec-path".utf8) + [0, 0, 0, 0]
        for s in argv + env { buf += Array(s.utf8) + [0] }
        buf += [0, 0]
        let parsed = parseProcArgs(buf)
        #expect(parsed.args == argv)
        #expect(parsed.env == env)
    }

    @Test("NODEV means no controlling terminal")
    func ttyDevice() {
        #expect(Proc.ttyDevice(-1) == nil)
        #expect(Proc.ttyDevice(0x1000003) == 0x1000003)
    }

    @Test("A spawned child reports this process as parent, our uid, and our terminal")
    func childBSDInfo() throws {
        let child = try spawn("/bin/sleep", ["30"])
        defer { child.terminate(); child.waitUntilExit() }
        let info = try #require(Proc.bsdInfo(child.processIdentifier))
        #expect(info.ppid == getpid())
        #expect(info.uid == getuid())
        #expect(info.name == "sleep")
        #expect(Proc.state(child.processIdentifier).tty == Proc.state(getpid()).tty)   // inherited (or none in CI)
    }

    @Test("Launcher chain of a grandchild runs through its shell and this process up to launchd")
    func launcherChain() throws {
        // `; :` keeps sh alive as the parent instead of exec-ing sleep.
        let sh = try spawn("/bin/sh", ["-c", "/bin/sleep 30; :"])
        defer { sh.terminate(); sh.waitUntilExit() }
        var grandchild: pid_t = 0
        try #require(waitFor {
            grandchild = Proc.allPIDs().first { Proc.bsdInfo($0)?.ppid == sh.processIdentifier } ?? 0
            return grandchild > 0 && Proc.exePath(grandchild) == "/bin/sleep"
        })
        let info = try #require(Proc.bsdInfo(grandchild))
        defer { _ = forceKill(pid: grandchild, start: info.start) }       // our own grandchild, via the core path

        let chain = Proc.launcherChain(parent: info.ppid, cache: ProcessCache())
        #expect(chain.first?.pid == sh.processIdentifier)
        #expect(chain.first.map { !$0.name.isEmpty } == true)            // /bin/sh reports itself as bash
        #expect(chain.count >= 2 && chain[1].pid == getpid())
        #expect(chain.last?.pid == 1)
    }
}

// MARK: - 2. Metrics

@Suite("Phase 2 · Metrics")
struct MetricsTests {
    @Test("Own process has resident memory and CPU time")
    func ownMetrics() throws {
        let m = try #require(Proc.metrics(getpid()))
        #expect(m.resident > 1_000_000)
        #expect(m.cpuNanos > 0)
    }

    static let cpuCases: [(UInt64, UInt64, UInt64, UInt64, Double?)] = [
        (0, 0, 500_000_000, 1_000_000_000, 50.0),
        (0, 0, 2_000_000_000, 1_000_000_000, 200.0),        // two busy cores
        (5, 10, 5, 10, nil),                                 // empty interval
        (9, 0, 5, 10, nil),                                  // counter went backwards
    ]
    @Test("CPU % from two samples", arguments: cpuCases)
    func percent(prevCPU: UInt64, prevAt: UInt64, cpu: UInt64, at: UInt64, expected: Double?) {
        #expect(cpuPercent(prevCPU: prevCPU, prevAt: prevAt, cpu: cpu, at: at) == expected)
    }

    @Test("Sampler needs a previous sample per process")
    func sampler() {
        let s = CPUSampler()
        #expect(s.sample(key: "1-1", cpuNanos: 100, at: 1_000) == nil)
        #expect(s.sample(key: "1-1", cpuNanos: 600, at: 2_000) == 50)
        s.forget(keeping: [])
        #expect(s.sample(key: "1-1", cpuNanos: 700, at: 3_000) == nil)
    }

    static let uptimeCases: [(Int, String)] = [
        (45, "running 45 s"), (720, "running 12 min"), (11_100, "running 3 h 5 min"),
        (187_259, "running 2 d 4 h"), (-5, "running 0 s"),
    ]
    @Test("Uptime formatting", arguments: uptimeCases)
    func uptime(seconds: Int, text: String) { #expect(formatUptime(seconds) == text) }

    @Test("Bytes format as MB or GB")
    func bytes() {
        #expect(formatBytes(12 * 1_048_576) == "12 MB")
        #expect(formatBytes(1_395_864_371) == "1.3 GB")
    }
}

// MARK: - 3. Connections

@Suite("Phase 2 · Connections")
struct ConnectionTests {
    @Test("Established connections on the listening port are counted; none means idle")
    func countsConnections() throws {
        let s = try TestListener()
        #expect(Proc.sockets(getpid()).established[s.port] == nil)
        #expect(try #require(scan(docker: [:], cache: ProcessCache()).first { $0.pid == getpid() && $0.port == s.port }).isIdle)

        let conn = try loopbackConnection(to: s)
        defer { Darwin.close(conn.client); Darwin.close(conn.server) }
        #expect(Proc.sockets(getpid()).established[s.port] == 1)
        let l = try #require(scan(docker: [:], cache: ProcessCache()).first { $0.pid == getpid() && $0.port == s.port })
        #expect(l.connections == 1)
        #expect(!l.isIdle)
    }
}

// MARK: - 4. Multi-worker grouping

@Suite("Phase 2 · Workers")
struct WorkerTests {
    @Test("A master and its forked workers on one port collapse into one row")
    func collapses() {
        let ls = [row(port: 8000, pid: 100, ppid: 1, connections: 0),
                  row(port: 8000, pid: 101, ppid: 100, chain: [100, 1], connections: 2),
                  row(port: 8000, pid: 102, ppid: 100, chain: [100, 1], connections: 1)]
        let g = groupWorkers(ls)
        #expect(g.count == 1)
        #expect(g[0].pid == 100)
        #expect(g[0].workers == [101, 102])
        #expect(g[0].connections == 3)
    }

    @Test("Workers fold into the topmost listening ancestor, through non-listening parents")
    func topmost() {
        let ls = [row(port: 8000, pid: 100, ppid: 1),
                  row(port: 8000, pid: 300, ppid: 200, chain: [200, 100, 1])]
        #expect(groupWorkers(ls).map(\.pid) == [100])
        #expect(groupWorkers(ls)[0].workers == [300])
    }

    static let separateCases: [[Listener]] = [
        [row(port: 8000, pid: 100, ppid: 1), row(port: 8000, pid: 101, ppid: 1)],                         // IPv4 + IPv6 owners
        [row(port: 8000, pid: 100, ppid: 1), row(port: 8000, pid: 101, ppid: 100, uid: 0, chain: [100])],  // other uid
        [row(port: 8000, pid: 100, ppid: 1), row(port: 9000, pid: 101, ppid: 100, chain: [100])],          // other port
    ]
    @Test("Unrelated owners, other users and other ports stay separate", arguments: separateCases)
    func separate(ls: [Listener]) {
        let g = groupWorkers(ls)
        #expect(g.count == 2)
        #expect(g.allSatisfy { $0.workers.isEmpty })
    }

    @Test("A child on another address of the same port is its own row (not an inherited socket)")
    func otherAddress() {
        let ls = [row(port: 8000, pid: 100, ppid: 1),
                  row(port: 8000, pid: 101, ppid: 100, chain: [100], exposure: .specific("::1"))]
        #expect(groupWorkers(ls).count == 2)
    }

    @Test("ports list shows the worker count before the STOPPED badge")
    func listRowWorkers() {
        var l = row(port: 8000, pid: 100, ppid: 1)
        l.workers = [101, 102]
        #expect(listRow(l) == ":8000   100     Backend            gunicorn  ×3 workers")
        l.stopped = true
        #expect(listRow(l).hasSuffix("×3 workers  STOPPED"))
    }

    @Test("A real forked server is one row with its worker",
          .enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/bin/perl")))
    func realFork() throws {
        let perl = Process()
        perl.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        perl.arguments = ["-MIO::Socket::INET", "-e", """
            my $s = IO::Socket::INET->new(Listen => 5, LocalAddr => '127.0.0.1', LocalPort => 0, Proto => 'tcp') or die;
            $| = 1; print $s->sockport, "\\n"; my $k = fork(); sleep 60;
            """]
        let out = Pipe()
        perl.standardOutput = out
        perl.standardError = FileHandle.nullDevice
        try perl.run()
        defer { perl.terminate(); perl.waitUntilExit() }
        var text = ""
        while !text.contains("\n") {
            let d = out.fileHandleForReading.availableData
            if d.isEmpty { break }
            text += String(decoding: d, as: UTF8.self)
        }
        let port = try #require(Int(text.trimmingCharacters(in: .whitespacesAndNewlines)))

        var found: Listener?
        let grouped = waitFor {
            found = scan(docker: [:], cache: ProcessCache()).first { $0.port == port }
            return found?.workers.count == 1
        }
        // Clean up the forked worker (ours) through the core path whatever the outcome.
        for pid in Proc.allPIDs() where Proc.bsdInfo(pid)?.ppid == perl.processIdentifier {
            if let start = Proc.bsdInfo(pid)?.start { _ = forceKill(pid: pid, start: start) }
        }
        try #require(grouped)
        let l = try #require(found)
        #expect(l.pid == perl.processIdentifier)
        #expect(l.workers.count == 1)
    }
}

// MARK: - 5. Project resolver

@Suite("Phase 2 · Projects")
struct ProjectTests {
    static let manifests: [(files: [String: String], dir: String, expected: String?)] = [
        (["app/package.json": #"{"name": "demo-web", "version": "1.0.0"}"#], "app", "demo-web"),
        (["app/pyproject.toml": "[build-system]\nrequires = []\n[project]\nname = \"demo-api\"\n"], "app", "demo-api"),
        (["app/pyproject.toml": "[tool.poetry]\nname = 'poetry-api'\n"], "app", "poetry-api"),
        (["app/Cargo.toml": "[package]\nname = \"demo-rs\"\nversion = \"0.1.0\"\n"], "app", "demo-rs"),
        (["app/go.mod": "module example.com/acme/demo-go\n\ngo 1.22\n"], "app", "demo-go"),
        (["app/composer.json": #"{"name": "acme/demo-php"}"#], "app", "demo-php"),
        (["app/pom.xml": "<project><parent><artifactId>parent-pom</artifactId></parent><artifactId>demo-java</artifactId></project>"],
         "app", "demo-java"),
        (["app/build.gradle": "", "app/settings.gradle": "rootProject.name = 'demo-gradle'\n"], "app", "demo-gradle"),
        (["demo-ruby/Gemfile": "source 'https://rubygems.org'\n"], "demo-ruby", "demo-ruby"),
        (["app/deno.json": #"{"name": "@acme/demo-deno"}"#], "app", "@acme/demo-deno"),
        (["demo-bun/bun.lockb": ""], "demo-bun", "demo-bun"),
        (["demo-git/.git/HEAD": "ref: refs/heads/main\n"], "demo-git", "demo-git"),
        (["app/package.json": #"{"name": "demo-web"}"#, "app/src/routes/": ""], "app/src/routes", "demo-web"),
        // Monorepo: a package inside a git repo, and inside a workspace without git.
        (["shop/.git/HEAD": "ref: refs/heads/main\n", "shop/package.json": #"{"name": "shop", "workspaces": ["apps/*"]}"#,
          "shop/apps/web/package.json": #"{"name": "web"}"#, "shop/apps/web/src/": ""], "shop/apps/web/src", "shop › web"),
        (["mono/pnpm-workspace.yaml": "packages: []\n", "mono/packages/ui/package.json": #"{"name": "ui"}"#],
         "mono/packages/ui", "mono › ui"),
        (["nothing/here/": ""], "nothing/here", nil),
        (["app/package.json": "{ not json"], "app", "app"),                 // unreadable manifest: folder name
    ]

    @Test("Manifests name the project; monorepos show repo › package", arguments: manifests)
    func resolves(files: [String: String], dir: String, expected: String?) throws {
        let tree = try TempTree(files)
        defer { tree.remove() }
        let r = ProjectResolver(home: "/nonexistent-home")
        #expect(r.resolve(dir: tree.path(dir))?.display == expected)
    }

    @Test("The home folder and / are never projects, even with a dotfiles .git in home")
    func homeNotProject() throws {
        let tree = try TempTree(["home/.git/HEAD": "ref: refs/heads/main\n", "home/scratch/": ""])
        defer { tree.remove() }
        let r = ProjectResolver(home: tree.path("home"))
        #expect(r.resolve(dir: tree.path("home/scratch")) == nil)
        #expect(r.resolve(dir: "/") == nil)
    }

    @Test("A script deeper in the project wins; node_modules scripts never do")
    func scriptDirectory() throws {
        let tree = try TempTree(["shop/.git/HEAD": "ref: refs/heads/main\n", "shop/package.json": #"{"name": "shop"}"#,
                                 "shop/apps/api/package.json": #"{"name": "api"}"#, "shop/apps/api/server.js": "",
                                 "shop/node_modules/vite/package.json": #"{"name": "vite"}"#,
                                 "shop/node_modules/vite/bin/vite.js": ""])
        defer { tree.remove() }
        let r = ProjectResolver(home: "/nonexistent-home")
        let cwd = tree.path("shop")
        #expect(r.resolve(cwd: cwd, script: "apps/api/server.js")?.display == "shop › api")
        #expect(r.resolve(cwd: cwd, script: "node_modules/vite/bin/vite.js")?.display == "shop")
        #expect(r.resolve(cwd: cwd, script: nil)?.display == "shop")
        #expect(r.resolve(cwd: "", script: tree.path("shop/apps/api/server.js"))?.display == "shop › api")
    }

    static let scriptCases: [(String, [String], String?)] = [
        ("/usr/local/bin/node", ["node", "--inspect", "apps/api/server.js"], "apps/api/server.js"),
        ("/usr/bin/python3", ["python3", "-m", "uvicorn", "app:app"], nil),
        ("/usr/bin/python3", ["python3", "-c", "print(1)"], nil),
        ("/opt/homebrew/bin/bun", ["bun", "run", "index.ts"], "index.ts"),
        ("/usr/local/bin/vite", ["vite"], nil),
    ]
    @Test("Script argument of interpreters", arguments: scriptCases)
    func script(exe: String, argv: [String], expected: String?) {
        #expect(scriptArgument(exe: exe, argv: argv) == expected)
    }

    @Test("Row label: tool · project › package · branch for dev servers")
    func label() {
        let p = Project(root: "/tmp/shop/apps/web", name: "web", repo: "shop", repoRoot: "/tmp/shop", branch: "main")
        #expect(rowLabel(kind: .frontend, tool: "vite", cwd: "/tmp/shop", project: p) == "vite · shop › web · main")
        #expect(rowLabel(kind: .docker, tool: "postgres-1", cwd: "/tmp/shop", project: p) == "postgres-1")
        #expect(rowLabel(kind: .system, tool: "ControlCenter", cwd: "/", project: nil) == "ControlCenter")
        #expect(rowLabel(kind: .backend, tool: "python3", cwd: home + "/demo-folder", project: nil) == "python3 · demo-folder")
        #expect(rowLabel(kind: .backend, tool: "python3", cwd: "/tmp/elsewhere", project: nil) == "python3")
    }
}

// MARK: - 6. Git

@Suite("Phase 2 · Git")
struct GitTests {
    static let headCases: [(String, String?)] = [
        ("ref: refs/heads/main\n", "main"),
        ("ref: refs/heads/feature/login-form", "feature/login-form"),
        ("0123456789abcdef0123456789abcdef01234567\n", "0123456"),
        ("garbage", nil),
        ("", nil),
    ]
    @Test("HEAD contents", arguments: headCases)
    func parseHead(text: String, expected: String?) { #expect(GitInfo.parseHead(text) == expected) }

    @Test("Branch from a .git folder, a worktree gitdir file (relative and absolute), or none")
    func branch() throws {
        let tree = try TempTree([
            "repo/.git/HEAD": "ref: refs/heads/develop\n",
            "repo/.git/worktrees/wt/HEAD": "ref: refs/heads/feature/demo\n",
            "wt/.git": "gitdir: ../repo/.git/worktrees/wt\n",
            "detached/.git/HEAD": "fedcba9876543210fedcba9876543210fedcba98\n",
            "plain/": "",
            "abs/": "",
        ])
        defer { tree.remove() }
        try Data("gitdir: \(tree.path("repo/.git/worktrees/wt"))\n".utf8).write(to: URL(fileURLWithPath: tree.path("abs/.git")))

        #expect(GitInfo.branch(repoRoot: tree.path("repo")) == "develop")
        #expect(GitInfo.branch(repoRoot: tree.path("wt")) == "feature/demo")
        #expect(GitInfo.branch(repoRoot: tree.path("abs")) == "feature/demo")
        #expect(GitInfo.branch(repoRoot: tree.path("detached")) == "fedcba9")
        #expect(GitInfo.branch(repoRoot: tree.path("plain")) == nil)
    }

    @Test("A scan reads the branch of a listener's project")
    func scanBranch() throws {
        let tree = try TempTree(["svc/.git/HEAD": "ref: refs/heads/feature/demo\n", "svc/package.json": #"{"name": "demo-svc"}"#])
        defer { tree.remove() }
        let s = try TestListener()
        let dir = tree.path("svc")
        let cache = ProcessCache(load: { _ in ("/usr/local/bin/node", ["node", "server.js"], dir) })
        let l = try #require(scan(docker: [:], cache: cache).first { $0.pid == getpid() && $0.port == s.port })
        #expect(l.project?.displayWithBranch == "demo-svc · feature/demo")
        #expect(l.label == "node · demo-svc · feature/demo")
    }
}

// MARK: - 7. Start command, environment, cache

@Suite("Phase 2 · Start command and environment")
struct StartCommandTests {
    static let quoteCases: [(String, String)] = [
        ("vite", "vite"), ("--port=3000", "--port=3000"), ("", "''"), ("my app", "'my app'"),
        ("it's", "'it'\\''s'"), ("$HOME", "'$HOME'"), ("a;b", "'a;b'"),
    ]
    @Test("Shell quoting", arguments: quoteCases)
    func quote(input: String, expected: String) { #expect(shellQuote(input) == expected) }

    @Test("Start command is cd + quoted argv")
    func command() {
        #expect(startCommand(cwd: "/tmp/my app", argv: ["npm", "run", "dev", "--", "--host"])
                == "cd '/tmp/my app' && npm run dev -- --host")
        #expect(startCommand(cwd: "", argv: ["node", "server.js"]) == "node server.js")
    }

    static let maskCases: [(String, String)] = [
        ("API_KEY=abc", "API_KEY=••••"), ("GITHUB_TOKEN=ghp_x", "GITHUB_TOKEN=••••"),
        ("DATABASE_URL=postgres://demo:hunter2@localhost/db", "DATABASE_URL=••••"),
        ("RANDOM_BLOB=aGVsbG8gd29ybGQgdGhpcyBpcyBsb25n", "RANDOM_BLOB=••••"),
        ("PORT=3000", "PORT=3000"), ("PATH=/usr/bin:/bin", "PATH=/usr/bin:/bin"), ("NODE_ENV=development", "NODE_ENV=development"),
        ("PWD=/tmp/demo", "PWD=/tmp/demo"), ("NOVALUE", "NOVALUE"),
    ]
    @Test("Secret-looking environment values are masked", arguments: maskCases)
    func mask(entry: String, expected: String) { #expect(maskedEnvironment([entry]) == [expected]) }

    /// Recent macOS withholds other processes' environments from KERN_PROCARGS2 (even `ps -E` shows none):
    /// reading must then return nothing, never argv strings or garbage.
    @Test("Environment of an own child is read and masked, or withheld by macOS")
    func childEnvironment() throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sleep")
        p.arguments = ["30"]
        p.environment = ["DEMO_TOKEN": "not-a-real-token", "DEMO_PLAIN": "hello"]
        try p.run()
        defer { p.terminate(); p.waitUntilExit() }
        try #require(waitFor { Proc.arguments(p.processIdentifier) == ["/bin/sleep", "30"] })
        let env = Proc.environment(p.processIdentifier)
        if env.isEmpty { return }
        #expect(maskedEnvironment(env).contains("DEMO_PLAIN=hello"))
        #expect(maskedEnvironment(env).contains("DEMO_TOKEN=••••"))
    }
}

@Suite("Phase 2 · Cache")
struct CacheTests {
    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func bump() { lock.lock(); n += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return n }
    }

    @Test("Static data is read once per (pid, start) and dropped when the process is gone")
    func readsOnce() {
        let loads = Counter()
        let cache = ProcessCache(load: { _ in loads.bump(); return ("/bin/demo", ["demo"], "/tmp/demo") })
        _ = cache.info(pid: 10, start: 1)
        _ = cache.info(pid: 10, start: 1)
        #expect(loads.value == 1)
        _ = cache.info(pid: 10, start: 2)                 // same PID, new process: read again
        #expect(loads.value == 2)
        cache.endScan()
        #expect(cache.count == 2)
        cache.endScan()                                   // nothing seen during this scan
        #expect(cache.count == 0)
    }

    @Test("A scan fills tree, metrics and parent for this process's listener")
    func scanFillsModel() throws {
        let s = try TestListener()
        let l = try #require(scan(docker: [:], cache: ProcessCache()).first { $0.pid == getpid() && $0.port == s.port })
        #expect(l.ppid == getppid())
        #expect(l.chain.first?.pid == getppid())
        #expect(l.memory > 0)
        #expect(l.cpuPercent == nil)                      // only sampled when asked (panel open)
    }
}
