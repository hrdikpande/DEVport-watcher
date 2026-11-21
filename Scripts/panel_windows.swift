// Prints the on-screen windows of one process as "id width height" (Quartz window list; no screenshots).
// Used by ui_smoke.sh and perf_check.sh to tell whether the panel is open: System Events doesn't reliably expose
// the popover.
import CoreGraphics
import Foundation

guard CommandLine.arguments.count == 2, let pid = Int32(CommandLine.arguments[1]) else {
    FileHandle.standardError.write(Data("usage: panel_windows <pid>\n".utf8)); exit(64)
}
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
for w in list where (w[kCGWindowOwnerPID as String] as? Int32) == pid {
    let b = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
    print(w[kCGWindowNumber as String] ?? 0, b["Width"] ?? 0, b["Height"] ?? 0)
}
