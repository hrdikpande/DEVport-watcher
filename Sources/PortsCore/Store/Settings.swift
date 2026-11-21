// User settings shared by the app and the CLI (`~/Library/Application Support/<Brand>/settings.json`).
// Decoding is tolerant: a file from an older version (missing or unknown keys) keeps what it can, the rest
// gets defaults.
import Foundation

/// A user-defined detection rule (Settings › Classification). Display only: like an override, it never
/// changes how a process is stopped or probed.
public struct CustomMatcher: Codable, Equatable, Sendable, Hashable {
    public enum Field: String, Codable, Sendable, CaseIterable { case exe, script, argv }
    public var name: String
    public var field: Field
    public var pattern: String          // case-insensitive substring (exe: basename; script: script/module/tool; argv: whole command)
    public var kind: Kind
    public init(name: String, field: Field, pattern: String, kind: Kind) {
        self.name = name; self.field = field; self.pattern = pattern; self.kind = kind
    }
}

public struct HotKeySetting: Codable, Equatable, Sendable {
    public var keyCode: UInt32          // Carbon virtual key code
    public var modifiers: UInt32        // Carbon modifier mask
    public init(keyCode: UInt32, modifiers: UInt32) { self.keyCode = keyCode; self.modifiers = modifiers }
    public static let `default` = HotKeySetting(keyCode: 35, modifiers: 0x0100 | 0x0800)   // ⌥⌘P (kVK_ANSI_P, cmdKey | optionKey)
}

public struct NotificationSettings: Codable, Equatable, Sendable {
    public var watchedPorts = true      // started / stopped / taken by something else
    public var newOrphan = false
    public var exposedDatabase = false
    public var containerStopped = false
    public init() {}
}

public struct Settings: Codable, Equatable, Sendable {
    // Phase 5
    public var protectedPorts: [Int] = []
    // Phase 7
    public var databaseClients: [String: String] = [:]
    // Phase 10 · General
    public var statusDisplay = "dev"             // dev | all | none: what the status item counts
    public var hotKey: HotKeySetting? = .default // nil = off
    public var updateCheck = false               // the only optional outbound request; off by default
    // Scanning
    public var refreshClosed: Double = 10        // seconds: 2, 5, 10, 30, 60
    public var refreshOpen: Double = 2
    public var pauseOnBattery = false            // on battery or Low Power Mode: pause instead of slowing down
    public var monitoredLow = 1
    public var monitoredHigh = 65535
    public var excludedPorts: [Int] = []
    public var hidePrivileged = false            // hide ports below 1024
    // Ports
    public var hiddenPorts: [Int] = []
    public var hiddenGroups: [String] = []       // executable paths hidden as a whole process group
    public var favoritePorts: [Int] = []
    public var watchedPorts: [Int] = []
    public var mutedPorts: [Int] = []
    // Classification
    public var customMatchers: [CustomMatcher] = []
    // Orphans
    public var idleThresholdMinutes: Double = 30
    public var showPossibleOrphans = false       // badges for `possible`; confirmed and likely always show
    // Containers
    public var dockerSocketOverride: String? = nil
    // Notifications and history
    public var notifications = NotificationSettings()
    public var historyRetentionDays: Double = 7
    // Command line & agents (Phase 11)
    public var mcpEnabled = false
    public var mcpAllowStop = false              // "Allow agents to stop processes": off by default

    public init() {}

    enum CodingKeys: String, CodingKey {
        case protectedPorts, databaseClients, statusDisplay, hotKey, updateCheck, refreshClosed, refreshOpen, pauseOnBattery,
             monitoredLow, monitoredHigh, excludedPorts, hidePrivileged, hiddenPorts, hiddenGroups, favoritePorts, watchedPorts,
             mutedPorts, customMatchers, idleThresholdMinutes, showPossibleOrphans, dockerSocketOverride, notifications,
             historyRetentionDays, mcpEnabled, mcpAllowStop
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Settings()
        func get<T: Decodable>(_ k: CodingKeys, _ fallback: T) -> T { ((try? c.decodeIfPresent(T.self, forKey: k)) ?? nil) ?? fallback }
        protectedPorts = get(.protectedPorts, d.protectedPorts)
        databaseClients = get(.databaseClients, d.databaseClients)
        statusDisplay = get(.statusDisplay, d.statusDisplay)
        hotKey = c.contains(.hotKey) ? ((try? c.decodeIfPresent(HotKeySetting.self, forKey: .hotKey)) ?? nil) : d.hotKey
        updateCheck = get(.updateCheck, d.updateCheck)
        refreshClosed = get(.refreshClosed, d.refreshClosed)
        refreshOpen = get(.refreshOpen, d.refreshOpen)
        pauseOnBattery = get(.pauseOnBattery, d.pauseOnBattery)
        monitoredLow = get(.monitoredLow, d.monitoredLow)
        monitoredHigh = get(.monitoredHigh, d.monitoredHigh)
        excludedPorts = get(.excludedPorts, d.excludedPorts)
        hidePrivileged = get(.hidePrivileged, d.hidePrivileged)
        hiddenPorts = get(.hiddenPorts, d.hiddenPorts)
        hiddenGroups = get(.hiddenGroups, d.hiddenGroups)
        favoritePorts = get(.favoritePorts, d.favoritePorts)
        watchedPorts = get(.watchedPorts, d.watchedPorts)
        mutedPorts = get(.mutedPorts, d.mutedPorts)
        customMatchers = get(.customMatchers, d.customMatchers)
        idleThresholdMinutes = get(.idleThresholdMinutes, d.idleThresholdMinutes)
        showPossibleOrphans = get(.showPossibleOrphans, d.showPossibleOrphans)
        dockerSocketOverride = (try? c.decodeIfPresent(String.self, forKey: .dockerSocketOverride)) ?? nil
        notifications = get(.notifications, d.notifications)
        historyRetentionDays = get(.historyRetentionDays, d.historyRetentionDays)
        mcpEnabled = get(.mcpEnabled, d.mcpEnabled)
        mcpAllowStop = get(.mcpAllowStop, d.mcpAllowStop)
    }


    /// Explicit so `hotKey: nil` (off) is written as null and not read back as the default.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(protectedPorts, forKey: .protectedPorts)
        try c.encode(databaseClients, forKey: .databaseClients)
        try c.encode(statusDisplay, forKey: .statusDisplay)
        try c.encode(hotKey, forKey: .hotKey)
        try c.encode(updateCheck, forKey: .updateCheck)
        try c.encode(refreshClosed, forKey: .refreshClosed)
        try c.encode(refreshOpen, forKey: .refreshOpen)
        try c.encode(pauseOnBattery, forKey: .pauseOnBattery)
        try c.encode(monitoredLow, forKey: .monitoredLow)
        try c.encode(monitoredHigh, forKey: .monitoredHigh)
        try c.encode(excludedPorts, forKey: .excludedPorts)
        try c.encode(hidePrivileged, forKey: .hidePrivileged)
        try c.encode(hiddenPorts, forKey: .hiddenPorts)
        try c.encode(hiddenGroups, forKey: .hiddenGroups)
        try c.encode(favoritePorts, forKey: .favoritePorts)
        try c.encode(watchedPorts, forKey: .watchedPorts)
        try c.encode(mutedPorts, forKey: .mutedPorts)
        try c.encode(customMatchers, forKey: .customMatchers)
        try c.encode(idleThresholdMinutes, forKey: .idleThresholdMinutes)
        try c.encode(showPossibleOrphans, forKey: .showPossibleOrphans)
        try c.encode(dockerSocketOverride, forKey: .dockerSocketOverride)
        try c.encode(notifications, forKey: .notifications)
        try c.encode(historyRetentionDays, forKey: .historyRetentionDays)
        try c.encode(mcpEnabled, forKey: .mcpEnabled)
        try c.encode(mcpAllowStop, forKey: .mcpAllowStop)
    }

    public func isProtected(_ port: Int) -> Bool { port > 0 && protectedPorts.contains(port) }
    /// Inside the monitored range, not excluded, and not privileged when those are hidden.
    public func isMonitored(_ port: Int) -> Bool {
        port >= monitoredLow && port <= monitoredHigh && !excludedPorts.contains(port) && !(hidePrivileged && port < 1024)
    }
    public static let refreshChoices: [Double] = [2, 5, 10, 30, 60]
}

/// "3000, 5173 8080" -> [3000, 5173, 8080] (paste-friendly; invalid entries dropped, duplicates removed).
public func parsePortList(_ text: String) -> [Int] {
    var seen = Set<Int>()
    return text.split(whereSeparator: { ", \n\t;".contains($0) }).compactMap { Int($0) }
        .filter { (1...65535).contains($0) && seen.insert($0).inserted }
}

/// Thread-safe JSON store for `Settings`.
public final class SettingsStore: @unchecked Sendable {
    public static var defaultURL: URL {
        supportDirectoryURL.appendingPathComponent("settings.json")
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
