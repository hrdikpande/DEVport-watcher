import Darwin
import Foundation

/// Where a listening socket is bound. Anything but loopback can be reached from other machines.
public enum Exposure: Equatable, Sendable {
    case loopback
    case allInterfaces
    case specific(String)           // one interface address, e.g. "192.168.1.20" or "fe80::1"

    public var isNetworkReachable: Bool { self != .loopback }

    /// Human-readable bind address for the UI.
    public var address: String {
        switch self {
        case .loopback: "127.0.0.1 / ::1"
        case .allInterfaces: "0.0.0.0 / ::"
        case .specific(let ip): ip
        }
    }

    public init(ipv4 addr: in_addr) {
        let host = UInt32(bigEndian: addr.s_addr)
        if host == 0 { self = .allInterfaces }
        else if host >> 24 == 127 { self = .loopback }
        else { self = .specific(ntop(AF_INET, addr)) }
    }

    public init(ipv6 addr: in6_addr) {
        let b = withUnsafeBytes(of: addr) { Array($0) }
        if b.allSatisfy({ $0 == 0 }) { self = .allInterfaces; return }
        if b[0..<15].allSatisfy({ $0 == 0 }) && b[15] == 1 { self = .loopback; return }
        if b[0..<10].allSatisfy({ $0 == 0 }) && b[10] == 0xff && b[11] == 0xff {   // ::ffff:a.b.c.d
            var v4 = in_addr()
            withUnsafeMutableBytes(of: &v4) { $0.copyBytes(from: b[12..<16]) }
            self.init(ipv4: v4); return
        }
        self = .specific(ntop(AF_INET6, addr))
    }

    /// One process can bind a port on several addresses; report the widest.
    public func widest(_ other: Exposure) -> Exposure {
        func rank(_ e: Exposure) -> Int { switch e { case .loopback: 0; case .specific: 1; case .allInterfaces: 2 } }
        return rank(other) > rank(self) ? other : self
    }
}

func ntop<T>(_ family: Int32, _ addr: T) -> String {
    var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
    let ok = withUnsafeBytes(of: addr) { inet_ntop(family, $0.baseAddress, &buf, socklen_t(buf.count)) != nil }
    return ok ? String(cString: buf) : "?"
}
