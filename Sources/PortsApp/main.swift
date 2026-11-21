import AppKit
import PortsCore

extension AppDelegate {
    /// Settings › General › Uninstall…: removes the login item, the CLI link and the support folder, then moves
    /// the app to the Trash — after one explicit confirmation.
    func uninstall() {
        NSApp.activate()
        let a = NSAlert()
        a.alertStyle = .critical
        a.messageText = L("Uninstall") + " \(Brand.displayName)?"
        a.informativeText = L("This removes the login item, the CLI link (~/.local/bin/ports), and ~/Library/Application Support/Ports (settings, overrides, history), then moves the app to the Trash and quits.")
        a.addButton(withTitle: L("Uninstall")).hasDestructiveAction = true
        a.addButton(withTitle: L("Cancel")).keyEquivalent = "\u{1b}"
        guard a.runModal() == .alertFirstButtonReturn else { return }
        try? LoginItem.set(false)
        try? CLIInstaller.uninstall()
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Brand.supportDirectory)
        try? FileManager.default.removeItem(at: support)
        NSWorkspace.shared.recycle([Bundle.main.bundleURL]) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}

// `Ports --list` prints the table in Terminal (handy for checking classification).
if CommandLine.arguments.contains("--list") {
    let t0 = Date()
    for l in scanWithContainers() { print(listRow(l)) }
    let t1 = Date()
    _ = scan(docker: [:])
    print(String(format: "\nscan (no docker): %.0f ms · with docker: %.0f ms", Date().timeIntervalSince(t1) * 1000, t1.timeIntervalSince(t0) * 1000))
    exit(0)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)   // menu bar only, no Dock icon
    app.run()
}
