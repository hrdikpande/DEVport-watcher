// User settings shared by the app and the CLI (`~/Library/Application Support/<Brand>/settings.json`).
// Decoding is tolerant: a file from an older version (missing keys) keeps its values and gets defaults.
import Foundation

public struct Settings: Codable, Equatable, Sendable {
    /// Stopping a listener on one of these needs the port number typed in (Phase 5).
    public var protectedPorts: [Int] = []

    public init() {}

    enum CodingKeys: String, CodingKey { case protectedPorts }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        protectedPorts = (try? c.decodeIfPresent([Int].self, forKey: .protectedPorts)) ?? []
    }

    public func isProtected(_ port: Int) -> Bool { port > 0 && protectedPorts.contains(port) }
}

/// Thread-safe JSON store for `Settings`.
public final class SettingsStore: @unchecked Sendable {
    public static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Brand.supportDirectory).appendingPathComponent("settings.json")
    }
    public let url: URL
    private let lock = NSLock()
    private var value: Settings

    public init(url: URL = SettingsStore.defaultURL) {
        self.url = url
        value = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(Settings.self, from: $0) } ?? Settings()
    }

    public var settings: Settings { lock.lock(); defer { lock.unlock() }; return value }

    public func update(_ change: (inout Settings) -> Void) throws {
        lock.lock(); defer { lock.unlock() }
        change(&value)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(value).write(to: url, options: .atomic)
    }
}

/// A protected port is stopped only after the user types its number exactly.
public func confirmsProtectedPort(_ typed: String, port: Int) -> Bool {
    typed.trimmingCharacters(in: .whitespaces) == String(port)
}
