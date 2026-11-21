import Foundation
import PortsCore

var arguments = Array(CommandLine.arguments.dropFirst())
if arguments.first == "list" || arguments.first == "--list" { arguments.removeFirst() }
let flags = Set(arguments)

guard flags.isSubset(of: ["--timing", "--env"]) else {
    fputs("Usage: ports [list] [--timing] [--env]\n", stderr)
    exit(64)
}

func ms(_ since: DispatchTime) -> Double { Double(DispatchTime.now().uptimeNanoseconds - since.uptimeNanoseconds) / 1e6 }

let t0 = DispatchTime.now()
let store = OverrideStore()
let listeners = applyOverrides(scanWithContainers(), store)
let full = ms(t0)
let analysis = analyze(listeners, starred: store.starred, includeLeftovers: true)

for l in listeners where l.override?.hidden != true {
    var badges = ""
    if let v = analysis.verdict(l), v.level >= .likely { badges += v.level == .confirmed ? "  ORPHAN" : "  ORPHAN?" }
    if analysis.isDuplicate(l) { badges += "  TWICE" }
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
