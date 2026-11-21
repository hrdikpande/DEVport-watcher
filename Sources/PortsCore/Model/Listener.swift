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


import Darwin
import Foundation

public struct Listener: Equatable, Sendable {
    public let port: Int
    public let pid: pid_t
    public let start: UInt64        // process start time (µs) — identity check against PID reuse
    public let uid: uid_t
    public var exposure: Exposure
    public var addresses: [String]  // this process's own bind addresses on this port, e.g. ["127.0.0.1"], ["::1"]
    public var exposed: Bool { exposure.isNetworkReachable }   // reachable from your network
    public let exe: String          // real executable path from the kernel
    public let command: String      // argv joined (display only)
    public let argv: [String]       // tool detection only (argv can be faked; never used for safety)
    public let cwd: String
    public var container: String? = nil
    public var containerInfo: ContainerInfo? = nil      // Engine API details (Phase 6)
    public var web: WebScheme? = nil     // set by probeWeb (menu open only); nil = not HTTP-like
    public var stopped = false      // suspended (SIGSTOP / Ctrl-Z): holds the port but serves nothing
    public var kind: Kind = .system
    public var label = ""
    // Phase 2 process model
    public var ppid: pid_t = 0
    public var pgid: pid_t = 0
    public var tty: Int32? = nil           // controlling terminal device; nil = none
    public var chain: [Ancestor] = []      // parent → … → launchd
    public var memory: UInt64 = 0          // resident bytes (own processes only)
    public var cpuNanos: UInt64 = 0        // total CPU time
    public var cpuPercent: Double? = nil   // sampled only while the panel is open
    public var connections = 0             // established TCP connections on this port
    public var workers: [pid_t] = []       // worker processes folded into this row
    public var project: Project? = nil
    // Phase 3 classification
    public var framework: String? = nil    // display name from the framework table
    public var confidence = 0              // 0–100
    public var tier: SafetyTier = .warning
    public var detectedKind: Kind? = nil   // set when an override moved the row to another category
    public var override: Override? = nil
    /// The category Ports detected. Safety decisions (stop policy, probing) always use this, never an override.
    public var baseKind: Kind { detectedKind ?? kind }
    public var isIdle: Bool { connections == 0 }
    public var startCommand: String { PortsCore.startCommand(cwd: cwd, argv: argv) }

    public init(port: Int, pid: pid_t, start: UInt64, uid: uid_t, exposed: Bool,
                exposure: Exposure? = nil, exe: String, command: String, argv: [String]? = nil, cwd: String, container: String? = nil,
                kind: Kind = .system, label: String = "") {
        self.port = port
        self.pid = pid
        self.start = start
        self.uid = uid
        self.exposure = exposure ?? (exposed ? .allInterfaces : .loopback)
        switch self.exposure {
        case .loopback: addresses = ["127.0.0.1"]
        case .allInterfaces: addresses = ["0.0.0.0"]
        case .specific(let ip): addresses = [ip]
        }
        self.exe = exe
        self.command = command
        self.argv = argv ?? command.split(separator: " ").map(String.init)
        self.cwd = cwd
        self.container = container
        self.kind = kind
        self.label = label
    }
}

public let home = FileManager.default.homeDirectoryForCurrentUser.path
public func tilde(_ p: String) -> String { p.hasPrefix(home) ? "~" + p.dropFirst(home.count) : p }
func basename(_ p: String) -> String { (p as NSString).lastPathComponent }
