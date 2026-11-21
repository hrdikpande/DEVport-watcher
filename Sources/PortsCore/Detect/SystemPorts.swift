import Darwin
import Foundation

// MARK: - System processes on dev ports

public enum KnownPorts {
    /// Ports dev servers usually want. A system process here is the likely cause of "address in use".
    public static let commonDevPorts: Set<Int> = [3000, 3001, 3306, 4000, 4200, 4321, 5000, 5001, 5173, 5432,
                                                  6006, 6379, 7000, 8000, 8001, 8080, 8081, 8443, 8888, 9000,
                                                  9229, 27017]

    /// System processes launchd starts again at once: killing them never frees the port.
    public static let restartedByLaunchd: Set<String> = ["ControlCenter", "rapportd", "sharingd", "remoted",
                                                         "AirPlayXPCHelper", "mDNSResponder", "identityservicesd"]

    public static func restartsAutomatically(_ l: Listener) -> Bool {
        l.baseKind == .system && restartedByLaunchd.contains(appName(l.exe))
    }

    public static var currentOSMajor: Int { ProcessInfo.processInfo.operatingSystemVersion.majorVersion }

    /// The General pane holding AirPlay Receiver: "AirDrop & Handoff" through macOS 15 (Apple's macOS 13 guide);
    /// renamed "AirDrop & Continuity" in macOS 26 Tahoe (the only version confirmed renamed).
    public static func airPlayPane(osMajor: Int = currentOSMajor) -> String {
        osMajor >= 26 ? "AirDrop & Continuity" : "AirDrop & Handoff"
    }

    public static let airPlaySettingsURL = URL(string: "x-apple.systempreferences:com.apple.AirDrop-Handoff-Settings.extension")!

    static func isAirPlayReceiver(_ l: Listener) -> Bool {
        l.baseKind == .system && appName(l.exe) == "ControlCenter" && (l.port == 5000 || l.port == 7000)
    }

    /// The settings action that actually frees the port, if there is one.
    public static func settingsAction(_ l: Listener) -> (title: String, url: URL)? {
        isAirPlayReceiver(l) ? ("Open AirPlay Settings", airPlaySettingsURL) : nil
    }

    /// Why a system process holds a common dev port, and how to free it.
    public static func explanation(_ l: Listener, osMajor: Int = currentOSMajor) -> String? {
        guard !l.baseKind.isDeveloper, commonDevPorts.contains(l.port) else { return nil }
        let app = appName(l.exe)
        if isAirPlayReceiver(l) {
            return "AirPlay Receiver (ControlCenter) uses port \(l.port). To free it, turn off System Settings › "
                + "General › \(airPlayPane(osMajor: osMajor)) › AirPlay Receiver."
        }
        return "\(app) is using port \(l.port), a common dev-server port, so a dev server can't bind it."
    }
}

/// Developer view: dev kinds, plus any system process sitting on a common dev port (never hidden).
public func showsInDeveloperView(_ l: Listener) -> Bool {
    l.kind.isDeveloper || KnownPorts.explanation(l) != nil
}
