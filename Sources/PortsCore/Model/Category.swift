import Darwin
import Foundation

public enum Kind: Int, CaseIterable, Sendable, Codable {
    case frontend, backend, database, docker, tunnel, ai, service, app, system
    public var title: String {
        ["Frontend", "Backend", "Databases", "Containers", "Tunnels & forwards", "AI & agents",
         "Background services", "Apps", "System"][rawValue]
    }
    public var symbol: String {
        ["macwindow", "server.rack", "cylinder.split.1x2", "shippingbox", "arrow.left.arrow.right.circle", "brain",
         "gearshape.2", "square.grid.2x2", "gearshape"][rawValue]
    }
    /// At most 14 characters, for the `ports list` column.
    public var shortTitle: String {
        ["Frontend", "Backend", "Databases", "Containers", "Tunnels", "AI & agents", "Services", "Apps", "System"][rawValue]
    }
    /// Stable name for settings files (rawValues may be reordered).
    public var id: String { ["frontend", "backend", "database", "container", "tunnel", "ai", "service", "app", "system"][rawValue] }
    public init?(id: String) { guard let k = Kind.allCases.first(where: { $0.id == id }) else { return nil }; self = k }
    public init(from decoder: Decoder) throws {
        let id = try decoder.singleValueContainer().decode(String.self)
        guard let k = Kind(id: id) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "unknown kind \(id)"))
        }
        self = k
    }
    public func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(id) }
    /// Developer view: things you run while developing (not apps, background services or the OS).
    public var isDeveloper: Bool { rawValue <= Kind.ai.rawValue }
}
public enum Filter: Int, Sendable { case developer, system, all }
