import AppKit
import PortsCore
import SwiftUI

/// View state of the Settings window (kept out of SwiftUI @State).
@MainActor
final class SettingsUIState: ObservableObject {
    @Published var login = LoginItem.enabled
    @Published var recording = false
    var monitor: Any?
    @Published var name = ""
    @Published var pattern = ""
    @Published var field = CustomMatcher.Field.script
    @Published var kind = Kind.backend
    @Published var cliInstalled = CLIInstaller.installed
}

struct SettingsView: View {
    let app: AppDelegate
    var body: some View {
        TabView {
            GeneralSettings(app: app, ui: app.settingsUI).tabItem { Label(L("General"), systemImage: "gearshape") }
            ScanningSettings(app: app).tabItem { Label(L("Scanning"), systemImage: "dot.radiowaves.left.and.right") }
            PortsSettings(app: app).tabItem { Label(L("Ports"), systemImage: "number") }
            ClassificationSettings(app: app, ui: app.settingsUI).tabItem { Label(L("Classification"), systemImage: "tag") }
            OrphanSettings(app: app).tabItem { Label(L("Orphans"), systemImage: "leaf") }
            DatabaseSettings(app: app).tabItem { Label(L("Databases"), systemImage: "cylinder.split.1x2") }
            ContainerSettings(app: app).tabItem { Label(L("Containers"), systemImage: "shippingbox") }
            CLISettings(app: app, ui: app.settingsUI).tabItem { Label(L("Command Line & Agents"), systemImage: "terminal") }
            PrivacySettings().tabItem { Label(L("Privacy"), systemImage: "hand.raised") }
            AboutSettings().tabItem { Label(L("About"), systemImage: "info.circle") }
        }
        .frame(width: 640, height: 500)
        .padding()
    }
}

/// A binding into the stored settings that saves on change.
@MainActor
func setting<T>(_ app: AppDelegate, _ path: WritableKeyPath<PortsCore.Settings, T>) -> Binding<T> {
    Binding(get: { app.settings[keyPath: path] }, set: { v in app.updateSettings { $0[keyPath: path] = v } })
}

@MainActor
func portList(_ app: AppDelegate, _ path: WritableKeyPath<PortsCore.Settings, [Int]>) -> Binding<String> {
    Binding(get: { app.settings[keyPath: path].map(String.init).joined(separator: ", ") },
            set: { text in app.updateSettings { s in s[keyPath: path] = parsePortList(text) } })
}

struct GeneralSettings: View {
    let app: AppDelegate
    @ObservedObject var ui: SettingsUIState
    var body: some View {
        Form {
            Toggle(L("Launch at login"), isOn: Binding(get: { ui.login }, set: { v in
                do { try LoginItem.set(v); ui.login = LoginItem.enabled } catch { app.prompter.tell(L("Couldn't change the login item"), "\(error)") }
            }))
            Picker(L("Menu bar shows"), selection: setting(app, \.statusDisplay)) {
                Text(L("Dev servers count")).tag("dev"); Text(L("All listeners count")).tag("all"); Text(L("Icon only")).tag("none")
            }
            HStack {
                Text(L("Global hot key"))
                Spacer()
                Text(app.settings.hotKey.map(HotKey.describe) ?? L("Off")).monospaced()
                Button(ui.recording ? L("Press keys…") : L("Record")) { record() }
                Button(L("Turn Off")) { app.updateSettings { $0.hotKey = nil } }
            }
            Text(L("Appearance follows the system (light, dark, increased contrast). Language: English; strings are ready for translation."))
                .font(.caption).foregroundStyle(.secondary)
            Toggle(L("Check for updates daily (GitHub releases; the only request Ports makes to the internet)"), isOn: setting(app, \.updateCheck))
            Section {
                Button(L("Uninstall…"), role: .destructive) { app.uninstall() }
                Text(L("Removes the login item, the CLI link, Ports's support folder, then moves the app to the Trash."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    func record() {
        ui.recording = true
        let ui = self.ui, app = self.app
        ui.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            MainActor.assumeIsolated {
                if let k = HotKey.setting(from: e) { app.updateSettings { $0.hotKey = k } }
                ui.recording = false
                if let m = ui.monitor { NSEvent.removeMonitor(m) }
            }
            return nil
        }
    }
}

struct ScanningSettings: View {
    let app: AppDelegate
    var body: some View {
        Form {
            Picker(L("Refresh while closed"), selection: setting(app, \.refreshClosed)) {
                ForEach(PortsCore.Settings.refreshChoices, id: \.self) { Text("\(Int($0)) s").tag($0) }
            }
            Picker(L("Refresh while open"), selection: setting(app, \.refreshOpen)) {
                ForEach([1.0, 2, 5], id: \.self) { Text("\(Int($0)) s").tag($0) }
            }
            Toggle(L("Pause scanning on battery or in Low Power Mode (otherwise it slows down 3×)"), isOn: setting(app, \.pauseOnBattery))
            HStack {
                Text(L("Monitored range"))
                TextField("1", value: setting(app, \.monitoredLow), format: .number).frame(width: 70)
                Text("–")
                TextField("65535", value: setting(app, \.monitoredHigh), format: .number).frame(width: 70)
            }
            TextField(L("Excluded ports (comma-separated)"), text: portList(app, \.excludedPorts))
            Toggle(L("Hide privileged ports (below 1024)"), isOn: setting(app, \.hidePrivileged))
            Text(L("While closed Ports only scans sockets (no CPU sampling, no probes; containers at most every 15 s). Scanning pauses while the Mac sleeps or the screen is locked."))
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct PortsSettings: View {
    let app: AppDelegate
    var body: some View {
        Form {
            TextField(L("Hidden ports"), text: portList(app, \.hiddenPorts))
            TextField(L("Favorite ports"), text: portList(app, \.favoritePorts))
            TextField(L("Watched ports (notify on start, stop, conflict)"), text: portList(app, \.watchedPorts))
            TextField(L("Muted ports (never notify)"), text: portList(app, \.mutedPorts))
            TextField(L("Protected ports (type the number to stop)"), text: portList(app, \.protectedPorts))
            HStack {
                Text(L("Hidden process groups") + ": \(app.settings.hiddenGroups.count)")
                Spacer()
                Button(L("Show All Again")) { app.updateSettings { $0.hiddenGroups = [] } }.disabled(app.settings.hiddenGroups.isEmpty)
            }
            Section(L("Notifications")) {
                Toggle(L("Watched ports start, stop, or are taken by something else"), isOn: setting(app, \.notifications.watchedPorts))
                Toggle(L("A new confirmed orphan"), isOn: setting(app, \.notifications.newOrphan))
                Toggle(L("A database becomes reachable from the network"), isOn: setting(app, \.notifications.exposedDatabase))
                Toggle(L("A container stops unexpectedly"), isOn: setting(app, \.notifications.containerStopped))
            }
            Section(L("History")) {
                Picker(L("Keep history for"), selection: setting(app, \.historyRetentionDays)) {
                    ForEach([1.0, 7, 30, 90], id: \.self) { Text("\(Int($0)) " + L("days")).tag($0) }
                }
                Button(L("Clear History"), role: .destructive) { app.history.clear() }
            }
        }
    }
}

struct ClassificationSettings: View {
    let app: AppDelegate
    @ObservedObject var ui: SettingsUIState
    var body: some View {
        Form {
            Section(L("Your overrides (rename, move, link, note, flags)")) {
                let all = app.overrides.all.sorted { $0.key < $1.key }
                if all.isEmpty { Text(L("None yet: use a row's Customize section.")).foregroundStyle(.secondary) }
                ForEach(all, id: \.key) { sig, o in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(o.name ?? (sig.split(separator: "|").dropFirst().first.map(String.init) ?? sig)).font(.body)
                            Text(sig.split(separator: "|").map(String.init).map(tilde).joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Text([o.kind?.title, o.favorite ? "★" : nil, o.hidden ? L("hidden") : nil, o.muted ? L("muted") : nil, o.starred ? L("starred") : nil]
                            .compactMap { $0 }.joined(separator: " · ")).font(.caption)
                        Button(L("Reset")) { try? app.overrides.update(sig) { $0 = Override() }; app.refresh(full: false) }
                    }
                }
            }
            Section(L("Custom matchers")) {
                ForEach(app.settings.customMatchers, id: \.self) { m in
                    HStack {
                        Text("\(m.name): \(m.field.rawValue) ∋ “\(m.pattern)” → \(m.kind.title)")
                        Spacer()
                        Button(L("Remove")) { app.updateSettings { $0.customMatchers.removeAll { $0 == m } } }
                    }
                }
                HStack {
                    TextField(L("Name"), text: $ui.name).frame(width: 110)
                    Picker("", selection: $ui.field) { ForEach(CustomMatcher.Field.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.frame(width: 90)
                    TextField(L("contains…"), text: $ui.pattern)
                    Picker("", selection: $ui.kind) { ForEach(Kind.allCases, id: \.self) { Text($0.title).tag($0) } }.frame(width: 150)
                    Button(L("Add")) {
                        let m = CustomMatcher(name: ui.name, field: ui.field, pattern: ui.pattern, kind: ui.kind)
                        app.updateSettings { $0.customMatchers.append(m) }
                        ui.name = ""; ui.pattern = ""
                    }.disabled(ui.name.isEmpty || ui.pattern.isEmpty)
                }
                Text(L("Matchers change the name and category shown, never how a process is stopped.")).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct OrphanSettings: View {
    let app: AppDelegate
    var body: some View {
        Form {
            Picker(L("Idle threshold"), selection: setting(app, \.idleThresholdMinutes)) {
                ForEach([10.0, 30, 60, 240], id: \.self) { Text("\(Int($0)) min").tag($0) }
            }
            Toggle(L("Also badge possible orphans (weak evidence)"), isOn: setting(app, \.showPossibleOrphans))
            Section(L("Starred (never flagged)")) {
                let starred = app.overrides.starred.sorted()
                if starred.isEmpty { Text(L("Nothing starred.")).foregroundStyle(.secondary) }
                ForEach(starred, id: \.self) { sig in
                    HStack {
                        Text(sig.split(separator: "|").map(String.init).map(tilde).joined(separator: " · ")).font(.caption)
                        Spacer()
                        Button(L("Unstar")) { try? app.overrides.update(sig) { $0.starred = false }; app.refresh(full: false) }
                    }
                }
            }
        }
    }
}

struct DatabaseSettings: View {
    let app: AppDelegate
    var body: some View {
        Form {
            Section(L("Client per database type")) {
                ForEach(DatabaseType.allCases.filter { $0.scheme != nil }, id: \.self) { t in
                    HStack {
                        Text(t.title)
                        Spacer()
                        Text(app.settings.databaseClients[t.rawValue].map(app.appTitle) ?? L("Ask the first time")).foregroundStyle(.secondary)
                        Button(L("Forget")) { app.updateSettings { $0.databaseClients[t.rawValue] = nil } }
                            .disabled(app.settings.databaseClients[t.rawValue] == nil)
                    }
                }
            }
        }
    }
}

struct ContainerSettings: View {
    let app: AppDelegate
    var body: some View {
        Form {
            Section(L("Detected runtimes")) {
                let rts = locateRuntimes()
                if rts.isEmpty { Text(L("No container runtime socket found.")).foregroundStyle(.secondary) }
                ForEach(rts, id: \.self) { r in
                    HStack { Text(r.name); Spacer(); Text(tilde(r.socket)).font(.caption.monospaced()).foregroundStyle(.secondary) }
                }
            }
            TextField(L("Socket path override (optional)"), text: Binding(get: { app.settings.dockerSocketOverride ?? "" },
                                                                    set: { v in app.updateSettings { $0.dockerSocketOverride = v.isEmpty ? nil : v } }))
        }
    }
}

struct CLISettings: View {
    let app: AppDelegate
    @ObservedObject var ui: SettingsUIState
    var installed: Bool { ui.cliInstalled }
    var body: some View {
        Form {
            HStack {
                Text(installed ? L("Installed at") + " \(tilde(CLIInstaller.link))" : L("Not installed"))
                Spacer()
                Button(installed ? L("Uninstall CLI") : L("Install CLI")) {
                    do { installed ? try CLIInstaller.uninstall() : try CLIInstaller.install() } catch { app.prompter.tell(L("CLI"), "\(error)") }
                    ui.cliInstalled = CLIInstaller.installed
                }
            }
            Text(L("Links ~/.local/bin/ports to the CLI inside the app (no administrator rights). Make sure ~/.local/bin is on your PATH."))
                .font(.caption).foregroundStyle(.secondary)
            Toggle(L("Enable MCP server (`ports mcp`)"), isOn: setting(app, \.mcpEnabled))
            Toggle(L("Allow agents to stop processes (only your own dev servers; never databases, containers, apps or system)"),
                   isOn: setting(app, \.mcpAllowStop)).disabled(!app.settings.mcpEnabled)
            HStack {
                Text(CLIInstaller.mcpSnippet).font(.caption.monospaced()).lineLimit(2).textSelection(.enabled)
                Button(L("Copy MCP Config")) { copyToPasteboard(CLIInstaller.mcpSnippet) }
            }
        }
    }
}

struct PrivacySettings: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text(L("Ports is local only: no telemetry, no accounts. Every probe it makes is listed here; all are read-only.")).font(.headline)
                ForEach(privacyProbes, id: \.name) { p in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(p.name).font(.body.weight(.semibold))
                        Text(L("When") + ": " + p.when).font(.caption)
                        Text(L("Where") + ": " + p.whereTo).font(.caption)
                        Text(L("Timeout") + ": " + p.timeout).font(.caption)
                        Text(p.what).font(.caption).foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct AboutSettings: View {
    var body: some View {
        VStack(spacing: 8) {
            Text(Brand.displayName).font(.largeTitle)
            Text(L("Version") + " " + UpdateCheck.currentVersion)
            Text(L("Ports tells developers what is running locally, why it is running, whether it is safe, and how to stop it — without leaving the menu bar."))
                .multilineTextAlignment(.center)
            Text(L("MIT License. Uses only Apple frameworks (and swift-argument-parser in the CLI)."))
                .font(.caption).foregroundStyle(.secondary)
            Link("github.com/\(Brand.repository)", destination: URL(string: "https://github.com/\(Brand.repository)")!)
        }.padding()
    }
}
