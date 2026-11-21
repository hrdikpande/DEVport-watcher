import Darwin
import Foundation
import Testing
@testable import PortsCore

func anc(_ pid: pid_t, _ command: String, exe: String? = nil, uid: uid_t? = nil, name: String? = nil) -> Ancestor {
    Ancestor(pid: pid, name: name ?? command, exe: exe ?? "/opt/demo/bin/" + command, command: command, uid: uid)
}

/// A dev server listener with a given ancestry (parent first) and terminal.
func server(pid: pid_t = 500, port: Int = 3000, chain: [Ancestor], tty: Int32? = nil, kind: Kind = .backend,
            exe: String = "/usr/local/bin/node", argv: [String] = ["node", "server.js"], stopped: Bool = false,
            start: UInt64 = 1, root: String? = "/tmp/demo-shop", framework: String? = "Node.js") -> Listener {
    var l = Listener(port: port, pid: pid, start: start, uid: getuid(), exposed: false, exe: exe,
                     command: argv.joined(separator: " "), argv: argv, cwd: "/tmp/demo-shop", kind: kind, label: "node")
    l.chain = chain
    l.ppid = chain.first?.pid ?? 1
    l.tty = tty
    l.stopped = stopped
    l.framework = framework
    if let root { l.project = Project(root: root, name: "demo-shop") }
    return l
}

let launchd = anc(1, "launchd", exe: "/sbin/launchd", uid: 0)

// MARK: - Starter attribution

struct StarterCase: Sendable, CustomTestStringConvertible {
    let chain: [Ancestor]
    let expected: String
    var testDescription: String { expected + " via " + chain.map(\.command).joined(separator: " ← ") }
}

/// One case per rule, built from the rule's own data, plus realistic chains.
let starterCases: [StarterCase] = starterRules.map { r in
    let a = r.commands.first.map { anc(77, $0) }
        ?? anc(77, "helper", exe: "/Applications/\(r.apps[0]).app/Contents/MacOS/helper")
    return StarterCase(chain: [anc(60, "zsh"), a, launchd], expected: r.name)
} + [
    StarterCase(chain: [anc(60, "zsh"), anc(61, "claude", name: "2.1.329"), anc(62, "zsh"),
                        anc(63, "Code Helper", exe: "/Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper.app/Contents/MacOS/Code Helper"),
                        launchd], expected: "Claude Code"),       // agent inside the editor's terminal wins
    StarterCase(chain: [anc(60, "npm"), anc(61, "zsh"), anc(62, "login", uid: 0),
                        anc(63, "Terminal", exe: "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal"), launchd],
                expected: "Terminal"),
    StarterCase(chain: [anc(60, "node", name: "PM2 v5.3.0: God Daemon (/tmp/.pm2)"), launchd], expected: "pm2"),
    StarterCase(chain: [anc(60, "bash"), anc(61, "tmux"), launchd], expected: "tmux"),
    StarterCase(chain: [launchd], expected: "unknown"),
    StarterCase(chain: [anc(60, "zsh"), launchd], expected: "unknown"),
]

@Suite("Phase 4 · Starter attribution")
struct StarterTests {
    @Test("First meaningful ancestor is tagged", arguments: starterCases)
    func tags(_ c: StarterCase) { #expect(starter(of: c.chain, isLaunchdJob: false).name == c.expected) }

    @Test("A process launchd started as a job is a launchd job, not unknown")
    func launchdJob() {
        let s = starter(of: [launchd], isLaunchdJob: true)
        #expect(s.kind == .supervisor)
        #expect(s.name == "launchd job")
    }
}

// MARK: - Orphan verdicts

struct VerdictCase: Sendable, CustomTestStringConvertible {
    let name: String
    let listener: Listener
    let ctx: OrphanContext
    let level: OrphanLevel
    let safe: SafeToStop
    let evidence: String
    var testDescription: String { name }
}

func ctx(jobs: [pid_t: String] = [:], ttys: Set<Int32> = [], dup: [String] = [], idle: [String: Date] = [:],
         exited: [String: Starter] = [:], starred: Set<String> = []) -> OrphanContext {
    var c = OrphanContext()
    c.launchdJobs = jobs; c.liveTTYs = ttys; c.duplicates = Set(dup); c.idleSince = idle; c.exitedStarters = exited
    c.starred = starred; c.now = Date(timeIntervalSince1970: 10_000); c.idleThreshold = 1800; c.home = "/Users/test/home"
    return c
}

let adopted = server(chain: [launchd])
let verdictCases: [VerdictCase] = [
    .init(name: "reparented, no terminal → confirmed", listener: adopted, ctx: ctx(),
          level: .confirmed, safe: .green, evidence: "launchd (PID 1) adopted it"),
    .init(name: "reparented, terminal gone → confirmed", listener: server(chain: [launchd], tty: 7), ctx: ctx(ttys: [9]),
          level: .confirmed, safe: .green, evidence: "terminal session it ran in is gone"),
    .init(name: "reparented, terminal still open → likely", listener: server(chain: [launchd], tty: 7), ctx: ctx(ttys: [7]),
          level: .likely, safe: .green, evidence: "launchd (PID 1) adopted it"),
    .init(name: "its shell was orphaned too → confirmed", listener: server(chain: [anc(60, "zsh"), launchd]), ctx: ctx(),
          level: .confirmed, safe: .green, evidence: "adopted PID 60"),
    .init(name: "agent that started it exited → evidence", listener: adopted,
          ctx: ctx(exited: ["500-1": Starter(kind: .agent, name: "Claude Code", pid: 42)]),
          level: .confirmed, safe: .green, evidence: "Claude Code (PID 42), which started it, is no longer running"),
    .init(name: "brew service → never flagged", listener: adopted, ctx: ctx(jobs: [500: "homebrew.mxcl.postgresql@16"]),
          level: .notOrphan, safe: .red, evidence: "brew services (postgresql@16)"),
    .init(name: "tree started by a launchd job → never flagged", listener: server(chain: [anc(60, "sh"), launchd]),
          ctx: ctx(jobs: [60: "com.demo.agent"]), level: .notOrphan, safe: .red, evidence: "launchd job com.demo.agent"),
    .init(name: "pm2-managed → never flagged",
          listener: server(chain: [anc(60, "node", name: "PM2 v5.3.0: God Daemon"), launchd]), ctx: ctx(),
          level: .notOrphan, safe: .red, evidence: "pm2"),
    .init(name: "container proxy → never flagged", listener: server(chain: [launchd], kind: .docker), ctx: ctx(),
          level: .notOrphan, safe: .red, evidence: "container runtime"),
    .init(name: "app in /Applications → never flagged",
          listener: server(chain: [launchd], exe: "/Applications/Demo.app/Contents/MacOS/Demo", argv: ["Demo"]), ctx: ctx(),
          level: .notOrphan, safe: .red, evidence: "installed app"),
    .init(name: "runtime inside an app bundle running your script → judged by the script",
          listener: server(chain: [launchd], exe: "/Applications/Demo.app/Contents/Resources/node",
                           argv: ["node", "/tmp/demo-shop/server.js"]), ctx: ctx(),
          level: .confirmed, safe: .green, evidence: "adopted it"),
    .init(name: "macOS system process adopted by launchd (ControlCenter) → never flagged",
          listener: server(port: 5000, chain: [launchd], kind: .system,
                           exe: "/System/Library/CoreServices/ControlCenter.app/Contents/MacOS/ControlCenter", argv: ["ControlCenter"]),
          ctx: ctx(), level: .notOrphan, safe: .red, evidence: "macOS system process"),
    .init(name: "starred → never flagged", listener: adopted, ctx: ctx(starred: [serviceSignature(adopted)]),
          level: .notOrphan, safe: .red, evidence: "starred"),
    .init(name: "agent still running it → red",
          listener: server(chain: [anc(60, "zsh"), anc(77, "claude"), launchd]), ctx: ctx(),
          level: .notOrphan, safe: .red, evidence: "Claude Code (PID 77) is still running it"),
    .init(name: "SSH session (system-owned top) → not adopted",
          listener: server(chain: [anc(60, "zsh"), anc(61, "sshd-session", uid: 0), launchd]), ctx: ctx(),
          level: .notOrphan, safe: .red, evidence: "another user"),
    .init(name: "live terminal behind it → not flagged",
          listener: server(chain: [anc(60, "zsh"), anc(61, "unknown-host")], tty: 7), ctx: ctx(ttys: [7]),
          level: .notOrphan, safe: .red, evidence: "terminal session is still open"),
    .init(name: "suspended only → possible", listener: server(chain: [anc(60, "unknown-host")], tty: 7, stopped: true),
          ctx: ctx(), level: .possible, safe: .yellow, evidence: "Suspended"),
    .init(name: "duplicate only → possible", listener: server(chain: [anc(60, "unknown-host")], tty: 7),
          ctx: ctx(dup: ["500-1"]), level: .possible, safe: .yellow, evidence: "Another instance"),
    .init(name: "idle past threshold → possible", listener: server(chain: [anc(60, "unknown-host")], tty: 7),
          ctx: ctx(idle: ["500-1-3000": Date(timeIntervalSince1970: 10_000 - 3600)]), level: .possible, safe: .yellow,
          evidence: "No connections for 60 min"),
    .init(name: "live unknown parent → red", listener: server(chain: [anc(60, "unknown-host")], tty: 7), ctx: ctx(),
          level: .notOrphan, safe: .red, evidence: "unknown-host (PID 60) is still running"),
]

@Suite("Phase 4 · Orphan verdicts")
struct OrphanVerdictTests {
    @Test("Verdict, Safe to stop? and evidence", arguments: verdictCases)
    func verdict(_ c: VerdictCase) {
        let v = analyzeOrphan(c.listener, starter: starter(of: c.listener.chain, isLaunchdJob: c.ctx.launchdJobs[c.listener.pid] != nil),
                              ctx: c.ctx)
        #expect(v.level == c.level)
        #expect(v.safeToStop == c.safe)
        #expect(v.evidence.contains { $0.contains(c.evidence) }, "\(v.evidence)")
        #expect(!v.evidence.isEmpty)            // every verdict explains itself
    }

    @Test("launchctl list parsing", arguments: [
        ("PID\tStatus\tLabel\n123\t0\thomebrew.mxcl.redis\n-\t0\tcom.demo.idle\n456\t-9\tapplication.com.demo.App.1\n",
         [pid_t(123): "homebrew.mxcl.redis", 456: "application.com.demo.App.1"]),
        ("", [:]),
        ("garbage line\n", [:]),
    ])
    func launchctl(text: String, expected: [pid_t: String]) { #expect(parseLaunchctlList(text) == expected) }

    @Test("Live terminals are the ones a shell or multiplexer holds")
    func ttys() {
        let procs = [Proc.Brief(pid: 1, ppid: 0, tty: 5, name: "zsh"), Proc.Brief(pid: 2, ppid: 1, tty: 6, name: "python3"),
                     Proc.Brief(pid: 3, ppid: 1, tty: 8, name: "tmux"), Proc.Brief(pid: 4, ppid: 1, tty: nil, name: "bash")]
        #expect(liveTTYs(procs) == [5, 8])
    }
}

// MARK: - Duplicates, idle, starter memory

@Suite("Phase 4 · Duplicates and history")
struct DuplicateTests {
    @Test("Same project + framework twice is a duplicate, oldest first")
    func duplicates() {
        let newer = server(pid: 600, port: 3001, chain: [launchd], start: 20)
        let older = server(pid: 500, port: 3000, chain: [launchd], start: 10)
        let other = server(pid: 700, port: 4000, chain: [launchd], root: "/tmp/other")
        let g = duplicateGroups([newer, older, other])
        #expect(g.count == 1)
        #expect(g[0].map(\.pid) == [500, 600])
        var a = Analysis()
        a.duplicates = g
        #expect(a.olderInstance(of: newer)?.pid == 500)
        #expect(a.olderInstance(of: older) == nil)
    }

    @Test("Not duplicates: one process on two ports, different frameworks, no project, non-dev kinds")
    func notDuplicates() {
        let a = server(pid: 500, port: 3000, chain: [launchd])
        var samePID = a; samePID = Listener(port: 3001, pid: 500, start: 1, uid: a.uid, exposed: false, exe: a.exe,
                                            command: a.command, argv: a.argv, cwd: a.cwd, kind: .backend)
        samePID.project = a.project; samePID.framework = a.framework
        #expect(duplicateGroups([a, samePID]).isEmpty)
        #expect(duplicateGroups([a, server(pid: 600, chain: [launchd], framework: "Vite")]).isEmpty)
        #expect(duplicateGroups([server(pid: 1, chain: [], root: nil), server(pid: 2, chain: [], root: nil)]).isEmpty)
        #expect(duplicateGroups([server(pid: 1, chain: [], kind: .database), server(pid: 2, chain: [], kind: .database)]).isEmpty)
    }

    @Test("Idle tracker keeps the first idle time and resets on a connection")
    func idle() {
        let t = IdleTracker()
        var l = server(chain: [])
        let t0 = Date(timeIntervalSince1970: 100), t1 = Date(timeIntervalSince1970: 200)
        #expect(t.update([l], now: t0)[listenerKey(l)] == t0)
        #expect(t.update([l], now: t1)[listenerKey(l)] == t0)
        l.connections = 1
        #expect(t.update([l], now: t1)[listenerKey(l)] == nil)
        l.connections = 0
        #expect(t.update([l], now: t1)[listenerKey(l)] == t1)
    }

    @Test("Starter memory reports an agent that has since exited")
    func memory() {
        let m = StarterMemory()
        let claude = Starter(kind: .agent, name: "Claude Code", pid: 42)
        let unknown = Starter(kind: .unknown, name: "unknown", pid: nil)
        #expect(m.update([("500-1", claude)], startOf: { $0 == 42 ? 7 : nil }).isEmpty)
        #expect(m.update([("500-1", unknown)], startOf: { $0 == 42 ? 7 : nil }).isEmpty)          // still alive
        #expect(m.update([("500-1", unknown)], startOf: { _ in nil }) == ["500-1": claude])       // exited
    }
}

// MARK: - Leftovers and bulk stop

@Suite("Phase 4 · Leftovers and clean-up")
struct LeftoverTests {
    @Test("Leftover tool patterns", arguments: [
        ("/usr/local/bin/node", ["node", "/tmp/demo/node_modules/.bin/tsc", "-w"], Optional("tsc")),
        ("/usr/local/bin/node", ["node", "/tmp/demo/node_modules/.bin/tsc"], nil),
        ("/usr/local/bin/node", ["node", "/tmp/demo/node_modules/.bin/esbuild", "app.ts", "--watch"], "esbuild"),
        ("/usr/local/bin/node", ["node", "/tmp/demo/node_modules/vite/bin/vite.js", "build", "--watch"], "vite"),
        ("/usr/local/bin/node", ["node", "/tmp/demo/node_modules/vite/bin/vite.js"], nil),
        ("/usr/local/bin/node", ["node", "/tmp/demo/node_modules/.bin/vitest"], "vitest"),
        ("/usr/local/bin/node", ["npx", "@modelcontextprotocol/server-filesystem", "/tmp"], "server-filesystem"),
        ("/opt/demo/bin/mcp-server-git", ["mcp-server-git"], "mcp-server-git"),
        ("/usr/bin/python3", ["python3", "app.py"], nil),
    ] as [(String, [String], String?)])
    func patterns(exe: String, argv: [String], expected: String?) { #expect(isLeftoverTool(exe: exe, argv: argv) == expected) }

    @Test("An orphaned watcher of ours (own session, parent gone) is found as a confirmed leftover",
          .enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/bin/perl")))
    func findsOwnLeftover() throws {
        // perl forks a child that starts its own session and becomes `vitest` (sleep), prints its PID and exits,
        // so launchd adopts the child: a real orphan without a terminal or a port. The child drops the pipe,
        // so reading perl's output ends when perl exits.
        let perl = Process()
        perl.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        perl.arguments = ["-MPOSIX", "-e",
                          #"$| = 1; my $k = fork(); if ($k == 0) { POSIX::setsid(); open(STDOUT, ">/dev/null"); open(STDERR, ">/dev/null"); exec { "/bin/sleep" } "vitest", "60"; } print "$k\n";"#]
        let out = Pipe()
        perl.standardOutput = out
        perl.standardError = FileHandle.nullDevice
        try perl.run()
        perl.waitUntilExit()
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let pid = try #require(pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)))
        try #require(waitFor { Proc.exePath(pid) == "/bin/sleep" && Proc.bsdInfo(pid)?.ppid == 1 })
        let start = try #require(Proc.bsdInfo(pid)).start
        defer { _ = forceKill(pid: pid, start: start) }                 // our own orphan, via the core path

        var c = OrphanContext()
        let procs = Proc.all(uid: getuid())
        c.liveTTYs = liveTTYs(procs)
        let found = findLeftovers(excluding: [], ctx: c, cache: ProcessCache(), procs: procs).first { $0.process.pid == pid }
        let left = try #require(found)
        #expect(left.tool == "vitest")
        #expect(left.verdict.level == .confirmed)
        #expect(left.process.port == 0)
    }

    @Test("Bulk stop runs the safe ladder per process and refuses a process already being stopped")
    func bulk() throws {
        let a = try spawn("/bin/sleep", ["30"]), b = try spawn("/bin/sleep", ["30"])
        defer { a.terminate(); b.terminate(); a.waitUntilExit(); b.waitUntilExit() }
        let ta = StopTarget(pid: a.processIdentifier, start: try #require(Proc.identity(a.processIdentifier)).start,
                            policy: .devServer, name: "a")
        let tb = StopTarget(pid: b.processIdentifier, start: try #require(Proc.identity(b.processIdentifier)).start,
                            policy: .devServer, name: "b")
        let registry = StopRegistry()
        let busy = StopRegistry.key(pid: tb.pid, start: tb.start)
        #expect(registry.claim(busy))                                   // another flow already owns b
        let outcomes = stopAll([ta, tb], registry: registry)
        a.waitUntilExit()
        #expect(outcomes[0].error == nil && !outcomes[0].refused)
        #expect(a.terminationReason == .uncaughtSignal)
        #expect(outcomes[1].refused)
        #expect(Proc.identity(tb.pid)?.start == tb.start)             // untouched
        registry.release(busy)
    }
}

// MARK: - Doctor

@Suite("Phase 4 · Doctor")
struct DoctorTests {
    @Test("Issues for orphans, duplicates, exposed databases, suspended, idle, Docker and localhost")
    func issues() {
        let orphan = server(pid: 500, port: 3000, chain: [launchd], start: 10)
        let twin = server(pid: 600, port: 3001, chain: [anc(60, "unknown-host")], tty: 7, start: 20)
        var db = server(pid: 700, port: 5432, chain: [launchd], kind: .database, framework: "PostgreSQL")
        db.exposure = .allInterfaces; db.addresses = ["0.0.0.0"]
        let paused = server(pid: 800, port: 4000, chain: [anc(60, "unknown-host")], tty: 7, stopped: true, root: nil)
        var input = DoctorInput()
        input.dockerReachable = false
        input.localhostIPv6First = true
        input.now = Date(timeIntervalSince1970: 10_000)
        input.idleSince = [listenerKey(paused): Date(timeIntervalSince1970: 1_000)]
        var c = OrphanContext()
        c.liveTTYs = [7]
        var a = Analysis()
        a.duplicates = duplicateGroups([orphan, twin])
        c.duplicates = Set(a.duplicates.flatMap { $0.map(processKey) })
        for l in [orphan, twin, db, paused] {
            a.verdicts[processKey(l)] = analyzeOrphan(l, starter: starter(of: l.chain, isLaunchdJob: false), ctx: c)
        }
        let issues = diagnose([orphan, twin, db, paused], a, input)
        let ids = issues.map(\.id)
        #expect(ids.first == "dbexposed-700-5432")                     // critical first
        #expect(issues.first { $0.id == "orphans" }?.fix == .cleanUpLeftovers)
        #expect(issues.first { $0.id.hasPrefix("dup-") }?.fix == .stopOlder(pid: 500, start: 10))
        #expect(ids.contains("stopped-800-4000"))
        #expect(ids.contains("idle-800-4000"))
        #expect(ids.contains("docker"))
        #expect(ids.contains("localhost-v4"))                           // 127.0.0.1 only while localhost → ::1
        #expect(issues.filter { $0.id.hasPrefix("localhost") }.count == 1)  // one issue, not one per server
        #expect(issues.allSatisfy { !$0.explanation.isEmpty })
        #expect(diagnose([], Analysis(), DoctorInput()).isEmpty)
    }

    @Test("An IPv6-only server is flagged when localhost prefers IPv4")
    func ipv6Only() {
        var l = server(chain: [anc(60, "unknown-host")], tty: 7)
        l.addresses = ["::1"]
        #expect(diagnose([l], Analysis(), DoctorInput()).map(\.id) == ["localhost-v6"])
    }

    @Test("analyze() never runs launchctl with an injected job list and tags a brew service as not an orphan")
    func analyzeInjected() {
        let brew = server(pid: 900, port: 6379, chain: [launchd], kind: .database, framework: "Redis")
        let a = analyze([brew], doctor: DoctorInput(), jobs: LaunchdJobs(fixed: [900: "homebrew.mxcl.redis"]),
                        idle: IdleTracker(), memory: StarterMemory(), procs: [])
        #expect(a.verdict(brew)?.level == .notOrphan)
        #expect(a.starter(brew)?.name == "launchd job")
        #expect(!a.issues.contains { $0.id == "orphans" })
    }

    @Test("AI setup prompt lists dev ports and how to query Ports")
    func prompt() {
        let p = aiSetupPrompt([server(chain: [])])
        #expect(p.contains(":3000"))
        #expect(p.contains("demo-shop"))
        #expect(p.contains("\(Brand.cliName) preflight"))
        #expect(p.contains("\(Brand.cliName) mcp"))
    }

    @Test("Overrides written before `starred` existed still load")
    func oldOverrides() throws {
        let o = try JSONDecoder().decode(Override.self, from: Data(#"{"name":"API","favorite":true,"hidden":false,"muted":false}"#.utf8))
        #expect(o.name == "API" && o.favorite && !o.starred)
    }
}
