import Darwin
import Foundation

// MARK: - Native process info (libproc / sysctl)

public enum Proc {
    public static func allPIDs() -> [pid_t] {
        let n = proc_listallpids(nil, 0)
        guard n > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(n) + 128)
        let got = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        return got > 0 ? Array(pids.prefix(Int(got))).filter { $0 > 0 } : []
    }

    public struct Identity: Equatable {
        public let uid: uid_t
        public let start: UInt64
    }
    public static func identity(_ pid: pid_t) -> Identity? {
        var bi = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bi, size) == size else { return nil }
        return Identity(uid: bi.pbi_uid, start: bi.pbi_start_tvsec &* 1_000_000 &+ bi.pbi_start_tvusec)
    }

    /// True when the process is suspended (kinfo_proc p_stat == SSTOP).
    public static func isStopped(_ pid: pid_t) -> Bool { state(pid).stopped }

    public static func exePath(_ pid: pid_t) -> String {
        var buf = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        return n > 0 ? String(decoding: buf.prefix(Int(n)), as: UTF8.self) : ""
    }

    public static func cwd(_ pid: pid_t) -> String {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return "" }
        return withUnsafeBytes(of: &info.pvi_cdir.vip_path) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }

    /// argv via KERN_PROCARGS2: [argc:int32][exec path\0][padding \0…][argv0\0][argv1\0]…
    public static func commandLine(_ pid: pid_t) -> String { arguments(pid).joined(separator: " ") }

    public static func arguments(_ pid: pid_t) -> [String] { procArgs(pid).args }

    public struct BoundPort: Equatable {
        public let port: Int
        public let exposure: Exposure
        public let address: String          // the exact bound address, e.g. "127.0.0.1", "::1", "0.0.0.0"
        public var exposed: Bool { exposure.isNetworkReachable }
    }

    /// Listening TCP sockets of one process, with the address each is bound to.
    public static func listeningPorts(_ pid: pid_t) -> [BoundPort] { sockets(pid).listening }
}
