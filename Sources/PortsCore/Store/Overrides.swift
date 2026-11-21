// Phase 3: user overrides (rename, move, link, note, favorite, hide, mute) and row icons.
// Overrides change how a row is shown, never how it is stopped: StopPolicy and the safety tier
// always follow the detected category.
import Foundation

public struct Override: Codable, Equatable, Sendable {
    public var name: String?
    public var kind: Kind?
    public var linkedApp: String?     // path of an .app bundle, for icon and Open
    public var note: String?
    public var favorite = false
    public var hidden = false
    public var muted = false
    public var starred = false        // never flag as orphan or duplicate suspect
    public init() {}

    enum CodingKeys: String, CodingKey { case name, kind, linkedApp, note, favorite, hidden, muted, starred }
    /// Tolerant: a file written by an older version (missing keys) still loads.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        kind = try? c.decodeIfPresent(Kind.self, forKey: .kind)
        linkedApp = try c.decodeIfPresent(String.self, forKey: .linkedApp)
        note = try c.decodeIfPresent(String.self, forKey: .note)
        favorite = try c.decodeIfPresent(Bool.self, forKey: .favorite) ?? false
        hidden = try c.decodeIfPresent(Bool.self, forKey: .hidden) ?? false
        muted = try c.decodeIfPresent(Bool.self, forKey: .muted) ?? false
        starred = try c.decodeIfPresent(Bool.self, forKey: .starred) ?? false
    }
    public var isEmpty: Bool { self == Override() }
}

/// Identifies "the same service" across restarts: executable + what it runs + where (project root or cwd).
public func serviceSignature(_ l: Listener) -> String {
    let what = identityNames(exe: l.exe, argv: l.argv).dropFirst().last ?? basename(l.exe)
    return [l.exe, what, l.project?.root ?? l.cwd].joined(separator: "|")
}

/// Overrides persisted as JSON (`~/Library/Application Support/<Brand>/overrides.json`). Thread-safe.
public final class OverrideStore: @unchecked Sendable {
    public static var defaultURL: URL {
        supportDirectoryURL.appendingPathComponent("overrides.json")
    }

    public let url: URL
    private let lock = NSLock()
    private var items: [String: Override]

    public init(url: URL = OverrideStore.defaultURL) {
        self.url = url
        let data = try? Data(contentsOf: url)
        items = data.flatMap { try? JSONDecoder().decode([String: Override].self, from: $0) } ?? [:]
    }

    public var all: [String: Override] { lock.lock(); defer { lock.unlock() }; return items }
    public func override(for signature: String) -> Override? { lock.lock(); defer { lock.unlock() }; return items[signature] }

    /// Change one entry and save; an entry with nothing left is removed.
    public func update(_ signature: String, _ change: (inout Override) -> Void) throws {
        lock.lock(); defer { lock.unlock() }
        var o = items[signature] ?? Override()
        change(&o)
        items[signature] = o.isEmpty ? nil : o
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(items).write(to: url, options: .atomic)
    }
}

extension OverrideStore {
    /// Signatures the user starred (Phase 4: never flagged).
    public var starred: Set<String> { Set(all.filter { $0.value.starred }.map(\.key)) }
}

/// Apply overrides to fresh scan results: label, displayed category, flags.
public func applyOverrides(_ ls: [Listener], _ store: OverrideStore) -> [Listener] {
    let all = store.all
    guard !all.isEmpty else { return ls }
    return ls.map { l in
        guard let o = all[serviceSignature(l)] else { return l }
        var r = l
        r.override = o
        if let name = o.name, !name.isEmpty { r.label = name }
        if let k = o.kind, k != l.kind { r.detectedKind = l.baseKind; r.kind = k }
        return r
    }
}

// MARK: - Icons

public enum IconSource: Equatable, Sendable {
    case app(String)          // .app bundle path (NSWorkspace icon)
    case favicon(String)      // image file in the project
    case symbol(String)       // SF Symbol name
}

/// The outermost `.app` bundle an executable lives in ("…/Visual Studio Code.app" for its Code Helper).
public func appBundle(of exe: String) -> String? {
    guard let r = exe.range(of: ".app/") else { return nil }
    return String(exe[..<r.lowerBound]) + ".app"
}

/// Linked app, else the owning app bundle, else the project's favicon, else the category symbol.
public func iconSource(_ l: Listener, fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) })
    -> IconSource {
    if let app = l.override?.linkedApp, !app.isEmpty { return .app(app) }
    if let app = appBundle(of: l.exe) { return .app(app) }
    if let root = l.project?.root {
        for dir in ["public", "static"] {
            for ext in ["png", "ico", "svg"] {
                let path = "\(root)/\(dir)/favicon.\(ext)"
                if fileExists(path) { return .favicon(path) }
            }
        }
    }
    return .symbol(l.kind.symbol)
}
