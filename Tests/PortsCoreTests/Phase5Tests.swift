import Darwin
import Foundation
import Testing
@testable import PortsCore

func dev(pid: pid_t = 4300, port: Int = 3000, kind: Kind = .backend, uid: uid_t = getuid(), chain: [Ancestor] = [],
         exe: String = "/usr/local/bin/node", container: String? = nil) -> Listener {
    var l = Listener(port: port, pid: pid, start: 5, uid: uid, exposed: false, exe: exe, command: "node server.js",
                     argv: ["node", "server.js"], cwd: "/tmp/demo", container: container, kind: kind, label: "node · demo")
    l.chain = chain
    l.ppid = chain.first?.pid ?? 1
    return l
}

func supCtx(jobs: [pid_t: String] = [:], agents: [LaunchAgentPlist] = [], brew: String? = "/opt/homebrew/bin/brew",
            pm2: String? = nil, pm2List: [pid_t: (id: Int, name: String)] = [:]) -> SupervisorContext {
    var c = SupervisorContext()
    c.jobs = jobs; c.agents = agents; c.brew = brew; c.pm2 = pm2; c.pm2List = pm2List; c.procs = []
    return c
}

let unknownStarter = Starter(kind: .unknown, name: "unknown", pid: nil)

// MARK: - Process control

@Suite("Phase 5 · Pause, resume, trees")
struct ProcessControlTests {
    @Test("Pause and resume an own child; refused for PID 1 and a gone process")
    func pauseResume() throws {
        let child = try spawn("/bin/sleep", ["30"])
        defer { child.terminate(); child.waitUntilExit() }
        let start = try #require(Proc.identity(child.processIdentifier)).start
        #expect(pause(pid: child.processIdentifier, start: start) == nil)
        try #require(waitFor { Proc.isStopped(child.processIdentifier) })
        #expect(resume(pid: child.processIdentifier, start: start) == nil)
        try #require(waitFor { !Proc.isStopped(child.processIdentifier) })
        #expect(pause(pid: 1, start: 0) == .protected)
        #expect(pause(pid: child.processIdentifier, start: start + 1) == .gone)
    }

    @Test("Descendants, nearest first")
    func descendantsOrder() {
        let procs = [Proc.Brief(pid: 10, ppid: 1, tty: nil, name: "root"), Proc.Brief(pid: 11, ppid: 10, tty: nil, name: "a"),
                     Proc.Brief(pid: 12, ppid: 10, tty: nil, name: "b"), Proc.Brief(pid: 13, ppid: 11, tty: nil, name: "c"),
                     Proc.Brief(pid: 20, ppid: 1, tty: nil, name: "other"), Proc.Brief(pid: 0, ppid: 0, tty: nil, name: "kernel")]
        #expect(descendants(of: 10, in: procs) == [11, 12, 13])
        #expect(descendants(of: 20, in: procs).isEmpty)
    }

    @Test("Stopping a tree stops the parent first, then its children, through the core ladder")
    func tree() throws {
        let sh = try spawn("/bin/sh", ["-c", "/bin/sleep 30; :"])
        defer { sh.terminate(); sh.waitUntilExit() }
        var child: pid_t = 0
        try #require(waitFor {
            child = Proc.all(uid: getuid()).first { $0.ppid == sh.processIdentifier }?.pid ?? 0
            return child > 0 && Proc.exePath(child) == "/bin/sleep"
        })
        let childStart = try #require(Proc.identity(child)).start
        let root = StopTarget(pid: sh.processIdentifier, start: try #require(Proc.identity(sh.processIdentifier)).start,
                              policy: .devServer, name: "sh")
        let targets = treeTargets(root: root)
        #expect(targets.map(\.pid) == [sh.processIdentifier, child])
        #expect(execute(.tree(targets), registry: StopRegistry()) == nil)
        sh.waitUntilExit()
        #expect(waitFor { Proc.identity(child)?.start != childStart })
    }

    @Test("A fake nodemon that respawns its child stays dead: the watcher is stopped, not just the child",
          .enabled(if: FileManager.default.isExecutableFile(atPath: "/bin/zsh")))
    func nodemonDoesNotResurrect() throws {
        let watcher = try spawn("/bin/zsh", ["-c", "exec -a nodemon /bin/zsh -c 'while :; do /bin/sleep 30; done'"])
        defer { watcher.terminate(); watcher.waitUntilExit() }
        let wpid = watcher.processIdentifier
        var child: pid_t = 0
        try #require(waitFor {
            child = Proc.all(uid: getuid()).first { $0.ppid == wpid && Proc.exePath($0.pid) == "/bin/sleep" }?.pid ?? 0
            return child > 0 && Proc.arguments(wpid).first == "nodemon"
        })
        let chain = [Ancestor(pid: wpid, name: "zsh", exe: "/bin/zsh", command: "nodemon")]
            + Proc.launcherChain(parent: getpid(), cache: ProcessCache())
        let s = starter(of: chain, isLaunchdJob: false)
        #expect(s.name == "nodemon")
        var c = supCtx()
        c.procs = Proc.all(uid: getuid())
        var l = Listener(port: 0, pid: child, start: try #require(Proc.identity(child)).start, uid: getuid(), exposed: false,
                         exe: "/bin/sleep", command: "sleep 30", argv: ["/bin/sleep", "30"], cwd: "/tmp", kind: .backend)
        l.chain = chain
        l.ppid = wpid
        let methods = stopMethods(l, starter: s, ctx: c)
        guard case .tree(let ts) = methods.first else { Issue.record("expected a tree stop, got \(methods)"); return }
        #expect(ts.first?.pid == wpid)
        #expect(ts.contains { $0.pid == child })
        #expect(execute(methods[0], registry: StopRegistry()) == nil)
        watcher.waitUntilExit()
        #expect(waitFor { Proc.identity(child) == nil || Proc.bsdInfo(child)?.ppid != wpid })
        #expect(!Proc.all(uid: getuid()).contains { $0.ppid == wpid })     // nothing respawned under the watcher
    }

    @Test("A second stop within two minutes is recent; later ones are not")
    func recent() {
        let r = RecentStops(window: 120)
        let t0 = Date(timeIntervalSince1970: 1_000)
        #expect(!r.isRecent("k", now: t0))
        r.record("k", now: t0)
        #expect(r.isRecent("k", now: t0.addingTimeInterval(119)))
        #expect(!r.isRecent("k", now: t0.addingTimeInterval(121)))
    }
}

// MARK: - Supervisors

@Suite("Phase 5 · Supervisor-aware stop")
struct SupervisorTests {
    @Test("Plans for each kind of supervisor")
    func plans() {
        let launchd = Ancestor(pid: 1, name: "launchd", exe: "/sbin/launchd", uid: 0)
        #expect(stopMethods(dev(container: "web-1"), starter: unknownStarter, ctx: supCtx()) == [.container(name: "web-1")])
        let cc = dev(port: 5000, kind: .system, exe: "/System/Library/CoreServices/ControlCenter.app/Contents/MacOS/ControlCenter")
        guard case .explain = stopMethods(cc, starter: unknownStarter, ctx: supCtx()).first else { Issue.record("ControlCenter"); return }
        guard case .explain = stopMethods(dev(uid: getuid() + 1), starter: unknownStarter, ctx: supCtx()).first else {
            Issue.record("other user"); return
        }
        #expect(stopMethods(dev(chain: [launchd]), starter: unknownStarter, ctx: supCtx(jobs: [4300: "homebrew.mxcl.postgresql@16"]))
                == [.brew(formula: "postgresql@16", brew: "/opt/homebrew/bin/brew", disable: false),
                    .brew(formula: "postgresql@16", brew: "/opt/homebrew/bin/brew", disable: true)])
        let agent = LaunchAgentPlist(path: "/tmp/demo/LaunchAgents/com.demo.api.plist", label: "com.demo.api",
                                     program: ["/opt/demo/api"], keepAlive: true, runAtLoad: true)
        #expect(stopMethods(dev(chain: [launchd]), starter: unknownStarter, ctx: supCtx(jobs: [4300: "com.demo.api"], agents: [agent]))
                == [.launchAgent(label: "com.demo.api", plist: agent.path, keepAlive: true)])
        // A child of a launchd job (the top of its tree is the job).
        #expect(stopMethods(dev(chain: [Ancestor(pid: 4200, name: "sh", exe: "/bin/sh"), launchd]), starter: unknownStarter,
                            ctx: supCtx(jobs: [4200: "com.demo.api"])) == [.launchAgent(label: "com.demo.api", plist: nil, keepAlive: false)])
        let pm2 = Starter(kind: .supervisor, name: "pm2", pid: 4100)
        #expect(stopMethods(dev(), starter: pm2, ctx: supCtx(pm2: "/opt/homebrew/bin/pm2", pm2List: [4300: (id: 3, name: "api")]))
                == [.pm2(id: 3, name: "api", pm2: "/opt/homebrew/bin/pm2")])
        guard case .explain = stopMethods(dev(), starter: pm2, ctx: supCtx()).first else { Issue.record("pm2 missing"); return }
        let app = dev(kind: .app, exe: "/Applications/Demo.app/Contents/MacOS/Demo")
        guard case .app(let bundle, _) = stopMethods(app, starter: unknownStarter, ctx: supCtx()).first else { Issue.record("app"); return }
        #expect(bundle == "/Applications/Demo.app")
        #expect(stopMethods(dev(), starter: unknownStarter, ctx: supCtx()) == [.signal(StopTarget(dev()))])
    }

    @Test("Every confirmation states what, how, restart and persistence")
    func confirmations() {
        let l = dev()
        let methods: [StopMethod] = [
            .signal(StopTarget(l)), .signal(StopTarget(dev(kind: .database))),
            .tree([StopTarget(l), StopTarget(pid: 9, start: 1, policy: .devServer, name: "child")]),
            .brew(formula: "redis", brew: "/opt/homebrew/bin/brew", disable: false),
            .brew(formula: "redis", brew: "/opt/homebrew/bin/brew", disable: true),
            .launchAgent(label: "com.demo.api", plist: "/tmp/demo/com.demo.api.plist", keepAlive: true),
            .launchAgent(label: "com.demo.api", plist: nil, keepAlive: false),
            .pm2(id: 3, name: "api", pm2: "/opt/homebrew/bin/pm2"), .container(name: "web-1"),
            .app(bundle: "/Applications/Demo.app", pid: 4300),
        ]
        for m in methods {
            let c = confirmation(m, for: l)
            for part in [c.whatStops, c.how, c.restarts, c.persists, c.title] { #expect(!part.isEmpty, "\(m)") }
            for label in ["What stops:", "How:", "Restarts automatically:", "After next login:"] { #expect(c.text.contains(label)) }
        }
        #expect(confirmation(methods[0], for: l).how.contains("SIGKILL after 2 s"))
        #expect(confirmation(methods[1], for: l).how.contains("never force-killed"))
        #expect(confirmation(methods[3], for: l).persists.contains("Starts again at the next login"))
        #expect(confirmation(methods[3], for: l).how.contains("brew services kill redis"))
        #expect(confirmation(methods[4], for: l).persists.contains("Stays off at login"))
        #expect(confirmation(methods[5], for: l).persists.contains("Loads again at the next login"))
        #expect(confirmation(methods[5], for: l).how.contains("launchctl bootout gui/"))
        #expect(confirmation(methods[6], for: l).persists.contains("won't start again"))
    }

    @Test("Unsafe or unknown supervisor commands are refused before anything runs")
    func refusals() {
        let r = StopRegistry()
        #expect(execute(.brew(formula: "redis; rm", brew: "/opt/homebrew/bin/brew", disable: false), registry: r) != nil)
        #expect(execute(.brew(formula: "redis", brew: "/tmp/fake-brew", disable: false), registry: r) != nil)
        #expect(execute(.launchAgent(label: "com.apple.Finder", plist: nil, keepAlive: false), registry: r) != nil)
        #expect(execute(.launchAgent(label: "../evil", plist: nil, keepAlive: false), registry: r) != nil)
        #expect(execute(.pm2(id: 1, name: "x", pm2: "/tmp/fake-pm2"), registry: r) != nil)
        #expect(execute(.container(name: "-rm"), registry: r) != nil)
        #expect(execute(.app(bundle: "/Applications/Demo.app", pid: 1), registry: r) != nil)
        #expect(execute(.explain("no"), registry: r) == .refused("no"))
    }

    @Test("A plain signal stop goes through the registry and the ladder")
    func signal() throws {
        let child = try spawn("/bin/sleep", ["30"])
        defer { child.terminate(); child.waitUntilExit() }
        let t = StopTarget(pid: child.processIdentifier, start: try #require(Proc.identity(child.processIdentifier)).start,
                           policy: .devServer, name: "sleep")
        let r = StopRegistry()
        #expect(r.claim(StopRegistry.key(pid: t.pid, start: t.start)))
        #expect(execute(.signal(t), registry: r) != nil)                 // refused: a flow already owns it
        r.release(StopRegistry.key(pid: t.pid, start: t.start))
        #expect(execute(.signal(t), registry: r) == nil)
        child.waitUntilExit()
        #expect(child.terminationReason == .uncaughtSignal)
    }

    @Test("pm2 jlist and LaunchAgent plists parse")
    func parsing() throws {
        let list = parsePM2List(#"[{"pid": 4300, "pm_id": 3, "name": "api"}, {"pid": 0, "pm_id": 4, "name": "stopped"}]"#)
        #expect(list.count == 1 && list[4300]?.id == 3 && list[4300]?.name == "api")
        #expect(parsePM2List("not json").isEmpty)

        let dir = (NSTemporaryDirectory() as NSString).appendingPathComponent("ports-p5-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        func write(_ name: String, _ plist: [String: Any]) throws {
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: URL(fileURLWithPath: dir + "/" + name))
        }
        try write("a.plist", ["Label": "com.demo.a", "ProgramArguments": ["/opt/demo/a", "--serve"], "KeepAlive": true, "RunAtLoad": true])
        try write("b.plist", ["Label": "com.demo.b", "Program": "/opt/demo/b", "KeepAlive": ["SuccessfulExit": false]])
        try write("c.plist", ["NoLabel": true])
        try Data("garbage".utf8).write(to: URL(fileURLWithPath: dir + "/d.plist"))
        let agents = readLaunchAgents(dir: dir)
        #expect(agents.map(\.label) == ["com.demo.a", "com.demo.b"])
        #expect(agents[0].program == ["/opt/demo/a", "--serve"] && agents[0].keepAlive && agents[0].runAtLoad)
        #expect(agents[1].program == ["/opt/demo/b"] && agents[1].keepAlive)
    }

    @Test("Exec puts the given folders first on PATH")
    func pathPrefix() {
        let r = run("/bin/sh", ["-c", "echo $PATH"], timeout: 5, pathPrefix: ["/opt/demo/bin"])
        #expect(r.ok)
        #expect(r.out.hasPrefix("/opt/demo/bin:/usr/bin"))
    }
}

// MARK: - Bind probe, next free port, protected ports

@Suite("Phase 5 · Bind probe")
struct BindProbeTests {
    @Test("A port this process listens on can't be bound; with no visible owner that is an invisible owner")
    func inUse() throws {
        let s = try TestListener()
        #expect(tryBind("127.0.0.1", port: s.port).inUse)
        let hidden = checkPort(s.port, listeners: [])
        #expect(!hidden.free)
        #expect(hidden.invisibleOwner)
        #expect(hidden.message.contains("doesn't expose"))
        let visible = checkPort(s.port, listeners: [dev(pid: getpid(), port: s.port)])
        #expect(!visible.invisibleOwner)
        #expect(visible.message.contains("is used by"))
    }

    @Test("A closed port binds again; next-free skips taken ports")
    func freeAndNext() throws {
        // A parallel test may be handed the just-closed ephemeral port, so allow a few fresh ports.
        var rebound = false
        for _ in 0..<5 where !rebound {
            var port = 0
            do { let s = try TestListener(); port = s.port }            // closed when it goes out of scope
            rebound = !tryBind("127.0.0.1", port: port).inUse
        }
        #expect(rebound)
        let s = try TestListener()
        let next = try #require(nextFreePort(from: s.port, listeners: [dev(pid: getpid(), port: s.port)], limit: 50))
        #expect(next > s.port)
        #expect(nextFreePort(from: 65535, listeners: [dev(port: 65535)], limit: 0) == nil)
    }

    @Test("Settings persist, tolerate old files, and protected ports need the exact number")
    func protected() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ports-p5-\(UUID().uuidString)/settings.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = SettingsStore(url: url)
        try store.update { $0.protectedPorts = [5432] }
        #expect(SettingsStore(url: url).settings.isProtected(5432))
        #expect(!SettingsStore(url: url).settings.isProtected(0))
        #expect(try JSONDecoder().decode(Settings.self, from: Data("{}".utf8)).protectedPorts.isEmpty)
        #expect(confirmsProtectedPort(" 5432 ", port: 5432))
        #expect(!confirmsProtectedPort("543", port: 5432))
        #expect(!confirmsProtectedPort("yes", port: 5432))
    }
}
