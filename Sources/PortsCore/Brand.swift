import Foundation

public enum Brand {
    public static let displayName = "Ports"
    public static let cliName = "ports"
    public static let bundleIdentifier = "local.portwatch.ports"
    public static let supportDirectory = "Ports"
    /// GitHub owner/repo: the opt-in update check and the About link.
    public static let repository = "hrdikpande/DEVport-watcher"
}

/// `~/Library/Application Support/<Brand>`, or `$PORTS_SUPPORT_DIR` (tests and scripted runs, so they never touch
/// the user's settings, overrides or history).
public var supportDirectoryURL: URL {
    if let d = ProcessInfo.processInfo.environment["PORTS_SUPPORT_DIR"], d.hasPrefix("/") { return URL(fileURLWithPath: d) }
    return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent(Brand.supportDirectory)
}
