// Phase 5: stop through whatever supervises the process (brew services, launchd, pm2, a watcher,
// Docker, an app) so it stays stopped. Every confirmation states four things: what stops, how,
// whether it restarts automatically, and whether the change persists after the next login.
import Darwin
import Foundation

/// A user LaunchAgent read from `~/Library/LaunchAgents` (read-only).
public struct LaunchAgentPlist: Equatable, Sendable {
    public let path: String
    public let label: String
    public let program: [String]
    public let keepAlive: Bool
    public let runAtLoad: Bool
}

public func readLaunchAgents(dir: String = home + "/Library/LaunchAgents") -> [LaunchAgentPlist] {
    let fm = FileManager.default
    guard let names = try? fm.contentsOfDirectory(atPath: dir) else { return [] }
    return names.filter { $0.hasSuffix(".plist") }.sorted().compactMap { name in
        let path = dir + "/" + name
        guard let data = fm.contents(atPath: path), data.count < 1_000_000,
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let label = plist["Label"] as? String else { return nil }
        let args = plist["ProgramArguments"] as? [String] ?? (plist["Program"] as? String).map { [$0] } ?? []
        let keep = (plist["KeepAlive"] as? Bool) ?? (plist["KeepAlive"] is [String: Any])
        return LaunchAgentPlist(path: path, label: label, program: args, keepAlive: keep,
                                runAtLoad: plist["RunAtLoad"] as? Bool ?? false)
    }
}

/// How to stop something so it stays stopped.
public enum StopMethod: Equatable, Sendable {
    case signal(StopTarget)                                 // the safe ladder
    case tree([StopTarget])                                 // a watcher (or parent) and its children, root first
    case brew(formula: String, brew: String, disable: Bool) // `brew services kill|stop`
    case launchAgent(label: String, plist: String?, keepAlive: Bool)
    case pm2(id: Int, name: String, pm2: String)
    case container(name: String)
    case app(bundle: String, pid: pid_t)                    // quit like ⌘Q (AppKit, in the app)
    case explain(String)                                    // Ports won't act; says why and what to do
}

public struct Confirmation: Equatable, Sendable {
    public let title: String        // button / menu title
    public let whatStops: String
    public let how: String
    public let restarts: String
    public let persists: String
    public var text: String {
        "What stops: \(whatStops)\nHow: \(how)\nRestarts automatically: \(restarts)\nAfter next login: \(persists)"
    }
}

let safeToken = #"^[A-Za-z0-9][A-Za-z0-9._@+-]{0,200}$"#
func isSafeToken(_ s: String) -> Bool { s.range(of: safeToken, options: .regularExpression) != nil }

public let brewPaths = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
public let pm2Paths = ["/opt/homebrew/bin/pm2", "/usr/local/bin/pm2", home + "/.npm-global/bin/pm2", home + "/.bun/bin/pm2"]
func firstExecutable(_ paths: [String]) -> String? { paths.first { FileManager.default.isExecutableFile(atPath: $0) } }

/// pm2's process list (`pm2 jlist`): pid -> (pm_id, name).
public func parsePM2List(_ json: String) -> [pid_t: (id: Int, name: String)] {
    guard let data = json.data(using: .utf8),
          let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [:] }
    var out: [pid_t: (Int, String)] = [:]
    for r in rows {
        guard let pid = r["pid"] as? Int, pid > 0, let id = r["pm_id"] as? Int else { continue }
        out[pid_t(pid)] = (id, r["name"] as? String ?? "app")
    }
    return out
}

/// What the supervisors around one process look like (gathered by the caller; pure input for planning).
public struct SupervisorContext: Sendable {
    public var jobs: [pid_t: String] = [:]               // your launchd jobs (`launchctl list`)
    public var agents: [LaunchAgentPlist] = []           // ~/Library/LaunchAgents
    public var brew: String? = firstExecutable(brewPaths)
    public var pm2: String? = nil
    public var pm2List: [pid_t: (id: Int, name: String)] = [:]
    public var procs: [Proc.Brief] = []
    public var uid: uid_t = getuid()
    public init() {}
}

/// Stop methods for a listener, the recommended one first.
public func stopMethods(_ l: Listener, starter: Starter, ctx: SupervisorContext) -> [StopMethod] {
    if let c = l.container { return [.container(name: c)] }
    if KnownPorts.restartsAutomatically(l) {
        return [.explain("macOS restarts \(appName(l.exe)) immediately, so stopping it won't free port \(l.port)."
                         + (KnownPorts.explanation(l).map { " " + $0 } ?? ""))]
    }
    if l.uid != ctx.uid || l.pid <= 1 {
        return [.explain("It belongs to the system or another user. Ports only stops your own processes.")]
    }
    let target = StopTarget(l)
    // launchd: the process itself, or the top of its tree, is one of your jobs.
    let top = l.chain.last { $0.pid != 1 }?.pid ?? l.pid
    if let label = ctx.jobs[l.pid] ?? (l.chain.last?.pid == 1 ? ctx.jobs[top] : nil), isSafeToken(label) {
        if label.hasPrefix("homebrew.mxcl."), let brew = ctx.brew {
            let formula = String(label.dropFirst("homebrew.mxcl.".count))
            if isSafeToken(formula) {
                return [.brew(formula: formula, brew: brew, disable: false), .brew(formula: formula, brew: brew, disable: true)]
            }
        }
        if label.hasPrefix("application.") { return [.signal(target)] }       // an app launched by launchd
        let agent = ctx.agents.first { $0.label == label }
        return [.launchAgent(label: label, plist: agent?.path, keepAlive: agent?.keepAlive ?? false)]
    }
    if starter.name == "pm2" {
        if let pm2 = ctx.pm2, let entry = ctx.pm2List[l.pid] ?? l.chain.lazy.compactMap({ ctx.pm2List[$0.pid] }).first {
            return [.pm2(id: entry.id, name: entry.name, pm2: pm2)]
        }
        return [.explain("pm2 manages it and would start it again. Run `pm2 stop <name>` (pm2 wasn't found at a known path).")]
    }
    if starter.name == "nodemon", let pid = starter.pid, let id = Proc.identity(pid) {
        let watcher = StopTarget(pid: pid, start: id.start, policy: target.policy, name: "nodemon (PID \(pid))")
        return [.tree(treeTargets(root: watcher, procs: ctx.procs))]
    }
    if l.baseKind == .app, let bundle = appBundle(of: l.exe) { return [.app(bundle: bundle, pid: l.pid), .signal(target)] }
    let tree = treeTargets(root: target, procs: ctx.procs)
    return tree.count > 1 ? [.signal(target), .tree(tree)] : [.signal(target)]
}

/// The four-part confirmation for a method.
public func confirmation(_ m: StopMethod, for l: Listener) -> Confirmation {
    let who = "\(l.label) (PID \(l.pid))" + (l.port > 0 ? " on :\(l.port)" : "")
    switch m {
    case .signal(let t):
        let ladder = t.policy.autoForce ? "SIGTERM, then SIGKILL after \(Int(t.policy.grace)) s if it hasn't exited"
            : "SIGTERM, then up to \(Int(t.policy.grace)) s to exit; never force-killed automatically (Force Quit is a separate step)"
        return Confirmation(title: t.policy == .dataStore ? "Shut Down" : "Stop", whatStops: who, how: ladder + ".",
                            restarts: "No. Nothing supervises it.", persists: "It stays stopped until you start it again.")
    case .tree(let ts):
        let n = ts.count - 1
        return Confirmation(title: "Stop with Children", whatStops: "\(ts[0].name) and its \(n) child process\(n == 1 ? "" : "es")",
                            how: "SIGTERM to \(ts[0].name) first, then to each child, each with the safe ladder.",
                            restarts: "No. The parent that would restart them is stopped first.",
                            persists: "They stay stopped until you start them again.")
    case .brew(let formula, _, let disable):
        return disable
            ? Confirmation(title: "Stop and Disable", whatStops: "\(formula) (brew service)",
                           how: "`brew services stop \(formula)`.", restarts: "No.",
                           persists: "Stays off at login too; `brew services start \(formula)` turns it back on.")
            : Confirmation(title: "Stop Until Next Login", whatStops: "\(formula) (brew service)",
                           how: "`brew services kill \(formula)`.", restarts: "No, not until you log in again.",
                           persists: "Starts again at the next login (it stays registered).")
    case .launchAgent(let label, let plist, let keepAlive):
        return Confirmation(title: "Stop LaunchAgent", whatStops: "\(who), launchd job \(label)",
                            how: "`launchctl bootout gui/\(getuid())/\(label)` (unloads the job, which ends the process).",
                            restarts: keepAlive ? "No. Its KeepAlive would have restarted a plain kill, which is why Ports unloads the job." : "No.",
                            persists: plist == nil ? "It won't start again: it isn't installed in ~/Library/LaunchAgents."
                                : "Loads again at the next login (\(tilde(plist!)) stays in place).")
    case .pm2(let id, let name, _):
        return Confirmation(title: "Stop with pm2", whatStops: "\(name) (pm2 id \(id))", how: "`pm2 stop \(id)`.",
                            restarts: "No. pm2 marks it stopped.",
                            persists: "pm2 only starts it after a reboot if you saved a list with it running (`pm2 save`).")
    case .container(let name):
        return Confirmation(title: "Stop Container", whatStops: "container \(name)", how: "`docker stop \(name)`.",
                            restarts: "Only if the container's restart policy says so.",
                            persists: "It starts again with `docker start \(name)` or `docker compose up`.")
    case .app(let bundle, _):
        let app = basename(String(bundle.dropLast(4)))
        return Confirmation(title: "Quit \(app)", whatStops: app, how: "Asks the app to quit, like ⌘Q (it may ask to save). Never force-killed first.",
                            restarts: "No.", persists: "It opens again at login only if it is a login item.")
    case .explain(let why):
        return Confirmation(title: "Why Not", whatStops: "nothing", how: why, restarts: "—", persists: "—")
    }
}

public enum SupervisorError: Error, Equatable, CustomStringConvertible {
    case refused(String), commandFailed(String)
    public var description: String {
        switch self { case .refused(let s): s; case .commandFailed(let s): s }
    }
}

/// Run a method (everything except `.app`, which the app performs with AppKit). Signals go through
/// the same core as every other stop; supervisor commands run via `Exec.run` with fixed paths.
public func execute(_ m: StopMethod, registry: StopRegistry, uid: uid_t = getuid()) -> SupervisorError? {
    switch m {
    case .signal(let t):
        let out = stopAll([t], registry: registry)[0]
        if out.refused { return .refused("A stop for PID \(t.pid) is already running.") }
        return out.error.map { .refused($0.description) }
    case .tree(let ts):
        let errs = stopAll(ts, registry: registry).compactMap { o in o.error.map { "\(o.target.name): \($0.description)" } }
        return errs.isEmpty ? nil : .commandFailed(errs.joined(separator: "\n"))
    case .brew(let formula, let brew, let disable):
        guard isSafeToken(formula), brewPaths.contains(brew) else { return .refused("Unsafe brew service name.") }
        let r = run(brew, ["services", disable ? "stop" : "kill", formula], timeout: 30)
        return r.ok ? nil : .commandFailed(r.out)
    case .launchAgent(let label, _, _):
        guard isSafeToken(label), !label.hasPrefix("com.apple.") else { return .refused("Ports doesn't unload Apple's jobs.") }
        let r = run("/bin/launchctl", ["bootout", "gui/\(uid)/\(label)"], timeout: 10)
        return r.ok ? nil : .commandFailed(r.out)
    case .pm2(let id, _, let pm2):
        guard pm2Paths.contains(pm2) else { return .refused("pm2 isn't at a known path.") }
        let r = run(pm2, ["stop", String(id)], timeout: 15, pathPrefix: [(pm2 as NSString).deletingLastPathComponent])
        return r.ok ? nil : .commandFailed(r.out)
    case .container(let name):
        guard let docker = dockerPath, isSafeContainerName(name) else { return .refused("No container CLI, or an unsafe name.") }
        let r = run(docker, ["stop", "--", name], timeout: 20)
        return r.ok ? nil : .commandFailed(r.out)
    case .app:
        return .refused("Quitting an app is done by the app (AppKit).")
    case .explain(let why):
        return .refused(why)
    }
}

/// Gather a supervisor context: launchctl and pm2 are asked only when the listener could need them.
public func supervisorContext(for l: Listener, starter: Starter, jobs: LaunchdJobs = .shared) -> SupervisorContext {
    var c = SupervisorContext()
    c.procs = Proc.all(uid: getuid())
    if l.ppid == 1 || l.chain.last?.pid == 1 {
        c.jobs = jobs.current()
        c.agents = readLaunchAgents()
    }
    if starter.name == "pm2", let pm2 = firstExecutable(pm2Paths) {
        c.pm2 = pm2
        let r = run(pm2, ["jlist"], timeout: 5, pathPrefix: [(pm2 as NSString).deletingLastPathComponent])
        if r.ok { c.pm2List = parsePM2List(r.out) }
    }
    return c
}
