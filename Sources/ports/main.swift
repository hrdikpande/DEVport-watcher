import Foundation
import PortsCore

var arguments = Array(CommandLine.arguments.dropFirst())

// `ports preflight <port>`: exit 0 when free (bind probe included), 1 when taken.
// `ports next-free [--from N]`: print the first free port at or above N (default 3000).
// shortcut: hand-parsed until the Phase 11 swift-argument-parser CLI replaces it.
if arguments.first == "preflight" {
    guard arguments.count == 2, let port = Int(arguments[1]), (1...65535).contains(port) else {
        fputs("Usage: ports preflight <port>\n", stderr); exit(64)
    }
    let check = checkPort(port, listeners: scanWithContainers())
    print(check.message)
    exit(check.free ? 0 : 1)
}
if arguments.first == "next-free" {
    var from = 3000
    if arguments.count == 3, arguments[1] == "--from", let f = Int(arguments[2]), (1...65535).contains(f) { from = f }
    else if arguments.count != 1 { fputs("Usage: ports next-free [--from N]\n", stderr); exit(64) }
    guard let p = nextFreePort(from: from, listeners: scanWithContainers()) else { fputs("No free port near \(from)\n", stderr); exit(1) }
    print(p)
    exit(0)
}
if arguments.first == "list" || arguments.first == "--list" { arguments.removeFirst() }
let flags = Set(arguments)

guard flags.isSubset(of: ["--timing", "--env", "--probe"]) else {
    fputs("Usage: ports [list] [--timing] [--env] [--probe]\n", stderr)
    exit(64)
}

func ms(_ since: DispatchTime) -> Double { Double(DispatchTime.now().uptimeNanoseconds - since.uptimeNanoseconds) / 1e6 }

let t0 = DispatchTime.now()
let store = OverrideStore()
// --probe: the same read-only loopback probes the open menu runs (HTTP/TLS first, then database handshakes).
var scanned = scanWithContainers()
if flags.contains("--probe") {
    scanned = scanned.map { var l = $0; l.web = probeWeb($0); return l }
    scanned = DatabaseProbeCache().apply(scanned, probe: true)
}
let listeners = applyOverrides(scanned, store)
let full = ms(t0)
let analysis = analyze(listeners, starred: store.starred, includeLeftovers: true)

for l in listeners where l.override?.hidden != true {
    var badges = ""
    if let v = analysis.verdict(l), v.level >= .likely { badges += v.level == .confirmed ? "  ORPHAN" : "  ORPHAN?" }
    if analysis.isDuplicate(l) { badges += "  TWICE" }
    if let (db, _) = knownDatabase(l) { badges += "  DB:\(db.rawValue)" + (l.exposed ? "  NETWORK" : "") }
    print(listRow(l) + badges)
    if let why = KnownPorts.explanation(l) { print("        ↳ " + why) }
    // Environment of your own processes only; values that look like secrets are masked.
    if flags.contains("--env"), l.uid == getuid() {
        let env = maskedEnvironment(Proc.environment(l.pid))
        if env.isEmpty { print("        (environment not available: macOS withholds it for this process)") }
        for line in env { print("        " + line) }
    }
}

if !analysis.leftovers.isEmpty {
    print("\nLeftovers (orphans without a port):")
    for left in analysis.leftovers { print("  PID \(left.process.pid)  \(left.tool)  ORPHAN") }
}

if flags.contains("--timing") {
    let t1 = DispatchTime.now()
    _ = scan(docker: [:])                          // warm: per-process static data is cached
    let warm = ms(t1)
    print(String(format: "\nscan: %.1f ms warm · first scan incl. containers: %.1f ms · %d processes · %d listeners",
                 warm, full, Proc.allPIDs().count, listeners.count))
}
exit(0)
