// Phase 5: bind probe ("is this port really free?") and next free port. Binds only, never listens;
// every socket is closed at once. Touches no other machine.
import Darwin
import Foundation

public struct BindAttempt: Equatable, Sendable {
    public let address: String       // "127.0.0.1", "::1", "0.0.0.0"
    public let inUse: Bool
}

/// Try to bind `address:port` the way a dev server would. A failure is retried with SO_REUSEADDR, so
/// lingering TIME_WAIT connections don't count as "in use". Only EADDRINUSE counts (not EACCES on < 1024).
public func tryBind(_ address: String, port: Int) -> BindAttempt {
    func attempt(reuse: Bool) -> Int32 {
        let v6 = address.contains(":")
        let fd = socket(v6 ? AF_INET6 : AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return errno }
        defer { close(fd) }
        var one: Int32 = 1
        if reuse { setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size)) }
        if v6 { setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &one, socklen_t(MemoryLayout<Int32>.size)) }
        let r: Int32
        if v6 {
            var a = sockaddr_in6()
            a.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            a.sin6_family = sa_family_t(AF_INET6)
            a.sin6_port = UInt16(port).bigEndian
            inet_pton(AF_INET6, address, &a.sin6_addr)
            r = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) } }
        } else {
            var a = sockaddr_in()
            a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            a.sin_family = sa_family_t(AF_INET)
            a.sin_port = UInt16(port).bigEndian
            a.sin_addr = in_addr(s_addr: inet_addr(address))
            r = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        }
        return r == 0 ? 0 : errno
    }
    if attempt(reuse: false) == 0 { return BindAttempt(address: address, inUse: false) }
    return BindAttempt(address: address, inUse: attempt(reuse: true) == EADDRINUSE)
}

public struct PortCheck: Equatable, Sendable {
    public let port: Int
    public let owners: [Listener]
    public let attempts: [BindAttempt]
    public var free: Bool { owners.isEmpty && attempts.allSatisfy { !$0.inUse } }
    /// Bind fails but no process shows the port: user-space networking holds it.
    public var invisibleOwner: Bool { owners.isEmpty && attempts.contains { $0.inUse } }
    public var message: String {
        if free { return "Port \(port) is free" }
        if invisibleOwner {
            return "Port \(port) can't be bound (\(attempts.filter(\.inUse).map(\.address).joined(separator: ", "))), but no process shows it. "
                + "It is held by a process macOS doesn't expose (user-space networking). Restarting the owning app or the Mac frees it."
        }
        return portReport(port, owners: owners).replacingOccurrences(of: "Still listening: ", with: "Port \(port) is used by ")
    }
}

public let probeAddresses = ["127.0.0.1", "::1", "0.0.0.0"]

/// Visible owners from `listeners` plus a bind attempt on each address.
public func checkPort(_ port: Int, listeners: [Listener]) -> PortCheck {
    PortCheck(port: port, owners: owners(ofPort: port, in: listeners), attempts: probeAddresses.map { tryBind($0, port: port) })
}

/// First free port at or above `from` (skipping visible owners and anything that won't bind), within `limit` ports.
public func nextFreePort(from: Int, listeners: [Listener], limit: Int = 1000) -> Int? {
    let taken = Set(listeners.map(\.port))
    var p = max(1, from)
    while p <= min(65535, from + limit) {
        if !taken.contains(p), probeAddresses.allSatisfy({ !tryBind($0, port: p).inUse }) { return p }
        p += 1
    }
    return nil
}
