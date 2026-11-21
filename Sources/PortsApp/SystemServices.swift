import AppKit
import Carbon.HIToolbox
import IOKit.ps
import PortsCore
import ServiceManagement
import UserNotifications

// MARK: - Notifications (each type toggleable in Settings; actions: Open, Copy address, Stop)

@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    enum Action: String { case open, copy, stop }
    var onAction: (Action, String) -> Void = { _, _ in }
    private var asked = false

    func setUp() {
        guard Bundle.main.bundleIdentifier != nil else { return }        // `swift run` has no bundle: notifications off
        let c = UNUserNotificationCenter.current()
        c.delegate = self
        let actions = [UNNotificationAction(identifier: Action.open.rawValue, title: L("Open"), options: [.foreground]),
                       UNNotificationAction(identifier: Action.copy.rawValue, title: L("Copy Address"), options: []),
                       UNNotificationAction(identifier: Action.stop.rawValue, title: L("Stop…"), options: [.foreground])]
        c.setNotificationCategories([UNNotificationCategory(identifier: "port", actions: actions, intentIdentifiers: [])])
    }

    func post(_ n: PortNotification) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let c = UNUserNotificationCenter.current()
        if !asked { asked = true; c.requestAuthorization(options: [.alert, .sound]) { _, _ in } }
        let content = UNMutableNotificationContent()
        content.title = n.title
        content.body = n.body
        content.categoryIdentifier = "port"
        content.userInfo = ["key": n.key]
        c.add(UNNotificationRequest(identifier: "\(n.kind.rawValue)-\(n.key)", content: content, trigger: nil))
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler done: @escaping () -> Void) {
        let key = response.notification.request.content.userInfo["key"] as? String ?? ""
        let action = Action(rawValue: response.actionIdentifier) ?? .open
        Task { @MainActor in self.onAction(action, key); done() }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner])
    }
}

// MARK: - Global hot key (Carbon RegisterEventHotKey: no Accessibility permission needed)

@MainActor
final class HotKey {
    private var ref: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    nonisolated(unsafe) static var action: (() -> Void)?

    func register(_ k: HotKeySetting, _ action: @escaping () -> Void) {
        Self.action = action
        if handlerRef == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                DispatchQueue.main.async { HotKey.action?() }
                return noErr
            }, 1, &spec, nil, &handlerRef)
        }
        let id = EventHotKeyID(signature: OSType(0x5052_5453), id: 1)       // 'PRTS'
        RegisterEventHotKey(k.keyCode, k.modifiers, id, GetApplicationEventTarget(), 0, &ref)
    }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
    }

    /// "⌥⌘P" for display.
    static func describe(_ k: HotKeySetting) -> String {
        var s = ""
        if k.modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if k.modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if k.modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if k.modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        let letters: [UInt32: String] = [0: "A", 11: "B", 8: "C", 2: "D", 14: "E", 3: "F", 5: "G", 4: "H", 34: "I", 38: "J", 40: "K",
                                         37: "L", 46: "M", 45: "N", 31: "O", 35: "P", 12: "Q", 15: "R", 1: "S", 17: "T", 32: "U",
                                         9: "V", 13: "W", 7: "X", 16: "Y", 6: "Z"]
        return s + (letters[k.keyCode] ?? "key \(k.keyCode)")
    }

    /// From a key-down event while recording a new shortcut in Settings.
    static func setting(from e: NSEvent) -> HotKeySetting? {
        var m: UInt32 = 0
        if e.modifierFlags.contains(.command) { m |= UInt32(cmdKey) }
        if e.modifierFlags.contains(.option) { m |= UInt32(optionKey) }
        if e.modifierFlags.contains(.control) { m |= UInt32(controlKey) }
        if e.modifierFlags.contains(.shift) { m |= UInt32(shiftKey) }
        return m == 0 ? nil : HotKeySetting(keyCode: UInt32(e.keyCode), modifiers: m)
    }
}

// MARK: - Power

enum Power {
    /// True when the Mac runs on battery (desktops without a battery: false).
    static func onBattery() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return false }
        return (type as String) == kIOPSBatteryPowerValue
    }
}

// MARK: - Launch at login, CLI install, update check

enum LoginItem {
    static var enabled: Bool { SMAppService.mainApp.status == .enabled }
    static func set(_ on: Bool) throws { on ? try SMAppService.mainApp.register() : try SMAppService.mainApp.unregister() }
}

enum CLIInstaller {
    static var bundled: String { Bundle.main.bundlePath + "/Contents/Helpers/" + Brand.cliName }
    static var link: String { home + "/.local/bin/" + Brand.cliName }

    static var installed: Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: link)) == bundled
    }

    /// `~/.local/bin/<cli>` → the CLI inside this app. Never replaces a file that isn't our link.
    static func install() throws {
        let fm = FileManager.default
        try fm.createDirectory(atPath: (link as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        if let dest = try? fm.destinationOfSymbolicLink(atPath: link) {
            guard dest.hasSuffix("/Contents/Helpers/" + Brand.cliName) else { throw CLIError.occupied(link) }
            try fm.removeItem(atPath: link)
        } else if fm.fileExists(atPath: link) {
            throw CLIError.occupied(link)
        }
        try fm.createSymbolicLink(atPath: link, withDestinationPath: bundled)
    }

    /// Removes the link only if it points into an app bundle's Helpers folder (ours).
    static func uninstall() throws {
        guard let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: link),
              dest.hasSuffix("/Contents/Helpers/" + Brand.cliName) else { return }
        try FileManager.default.removeItem(atPath: link)
    }

    enum CLIError: Error, CustomStringConvertible {
        case occupied(String)
        var description: String { "\(tilde(self.path)) already exists and isn't \(Brand.displayName)'s link; it was left alone." }
        var path: String { switch self { case .occupied(let p): p } }
    }

    /// For Claude Code / Cursor `mcpServers` config.
    static var mcpSnippet: String {
        #"{ "mcpServers": { "\#(Brand.cliName)": { "command": "\#(installed ? link : bundled)", "args": ["mcp"] } } }"#
    }
}

/// The only optional outbound request: a daily check of the latest GitHub release. Off by default.
enum UpdateCheck {
    static let lastKey = "updateCheck.last"
    static var currentVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }

    static func isNewer(_ tag: String, than current: String) -> Bool {
        func parts(_ v: String) -> [Int] { v.trimmingCharacters(in: CharacterSet(charactersIn: "v")).split(separator: ".").map { Int($0) ?? 0 } }
        let a = parts(tag), b = parts(current)
        for i in 0..<max(a.count, b.count) where (i < a.count ? a[i] : 0) != (i < b.count ? b[i] : 0) {
            return (i < a.count ? a[i] : 0) > (i < b.count ? b[i] : 0)
        }
        return false
    }

    /// Calls `found` with the newer tag, if any. Runs at most once a day and only when enabled.
    static func runIfDue(enabled: Bool, force: Bool = false, found: @escaping @Sendable (String?) -> Void) {
        guard enabled else { return }
        let last = UserDefaults.standard.double(forKey: lastKey)
        guard force || Date().timeIntervalSince1970 - last > 86_400 else { return }
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastKey)
        guard let url = URL(string: "https://api.github.com/repos/\(Brand.repository)/releases/latest") else { return }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue(Brand.displayName + "-update-check", forHTTPHeaderField: "User-Agent")
        let current = currentVersion
        URLSession.shared.dataTask(with: req) { data, _, _ in
            let tag = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["tag_name"] as? String
            found(tag.flatMap { isNewer($0, than: current) ? $0 : nil })
        }.resume()
    }
}
