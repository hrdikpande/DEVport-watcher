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
    @Published var pane: SettingsPane? = .general
}

enum SettingsPane: String, CaseIterable, Identifiable {
    case general, scanning, ports, classification, orphans, databases, containers, agents, privacy, about
    var id: String { rawValue }
    var title: String {
        ["general": "General", "scanning": "Scanning", "ports": "Ports & Notifications", "classification": "Classification",
         "orphans": "Orphans", "databases": "Databases", "containers": "Containers", "agents": "Command Line & Agents",
         "privacy": "Privacy", "about": "About"][rawValue]!
    }
    var symbol: String {
        ["general": "gearshape", "scanning": "dot.radiowaves.left.and.right", "ports": "bell.badge", "classification": "tag",
         "orphans": "leaf", "databases": "cylinder.split.1x2", "containers": "shippingbox", "agents": "terminal",
         "privacy": "hand.raised", "about": "info.circle"][rawValue]!
    }
    var tint: Color {
        ["general": .gray, "scanning": .blue, "ports": .red, "classification": .purple, "orphans": .green, "databases": .teal,
         "containers": .indigo, "agents": .orange, "privacy": .blue, "about": .gray][rawValue]!
    }
}

/// System Settings–style window: a vertical list of panes on the left, a grouped form on the right.
struct SettingsView: View {
    let app: AppDelegate
    @ObservedObject var ui: SettingsUIState

    var body: some View {
        NavigationSplitView {
            List(SettingsPane.allCases, selection: $ui.pane) { pane in
                Label {
                    Text(L(pane.title))
                } icon: {
                    Image(systemName: pane.symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                        .frame(width: 20, height: 20)
                        .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(pane.tint.gradient))
                }
                .tag(pane)
                .padding(.vertical, 2)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 260)
        } detail: {
            detail(ui.pane ?? .general)
                .formStyle(.grouped)
                .navigationTitle(L((ui.pane ?? .general).title))
        }
        .frame(minWidth: 760, idealWidth: 820, minHeight: 540, idealHeight: 600)
    }

    @ViewBuilder func detail(_ pane: SettingsPane) -> some View {
        switch pane {
        case .general: GeneralSettings(app: app, ui: ui)
        case .scanning: ScanningSettings(app: app)
        case .ports: PortsSettings(app: app)
        case .classification: ClassificationSettings(app: app, ui: ui)
        case .orphans: OrphanSettings(app: app)
        case .databases: DatabaseSettings(app: app)
        case .containers: ContainerSettings(app: app)
        case .agents: CLISettings(app: app, ui: ui)
        case .privacy: PrivacySettings()
        case .about: AboutSettings()
        }
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
            Section {
                Toggle(L("Launch at login"), isOn: Binding(get: { ui.login }, set: { v in
                    do { try LoginItem.set(v); ui.login = LoginItem.enabled } catch { app.prompter.tell(L("Couldn't change the login item"), "\(error)") }
                }))
                Picker(L("Menu bar shows"), selection: setting(app, \.statusDisplay)) {
                    Text(L("Number of dev servers")).tag("dev")
                    Text(L("Number of all listeners")).tag("all")
                    Text(L("Icon only")).tag("none")
                }
            }
            Section {
                LabeledContent(L("Open the panel")) {
                    HStack(spacing: 8) {
                        Text(app.settings.hotKey.map(HotKey.describe) ?? L("Off"))
                            .font(.body.monospaced()).padding(.horizontal, 8).padding(.vertical, 2)
                            .background(RoundedRectangle(cornerRadius: 5).fill(.quaternary))
                        Button(ui.recording ? L("Press a shortcut…") : L("Record")) { record() }
                        Button(L("Clear")) { app.updateSettings { $0.hotKey = nil } }.disabled(app.settings.hotKey == nil)
                    }
                }
            } header: { Text(L("Keyboard Shortcut")) } footer: {
                Text(L("Works from any app. No Accessibility permission is needed.")).foregroundStyle(.secondary).multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
            }
            Section {
                Toggle(L("Check for updates daily"), isOn: setting(app, \.updateCheck))
            } header: { Text(L("Updates")) } footer: {
                Text(L("Asks GitHub for the latest release once a day. This is the only request Ports makes to the internet, and it is off by default."))
                    .foregroundStyle(.secondary).multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
            }
            Section {
                LabeledContent(L("Remove Ports from this Mac")) {
                    Button(L("Uninstall…"), role: .destructive) { app.uninstall() }
                }
            } footer: {
                Text(L("Removes the login item, the CLI link and Ports's settings and history, then moves the app to the Trash.")).foregroundStyle(.secondary).multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
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
            Section {
                Picker(L("While the panel is closed"), selection: setting(app, \.refreshClosed)) {
                    ForEach(PortsCore.Settings.refreshChoices, id: \.self) { Text(String(Int($0)) + " s").tag($0) }
                }
                Picker(L("While the panel is open"), selection: setting(app, \.refreshOpen)) {
                    ForEach([1.0, 2, 5], id: \.self) { Text(String(Int($0)) + " s").tag($0) }
                }
                Toggle(L("Pause on battery and in Low Power Mode"), isOn: setting(app, \.pauseOnBattery))
            } header: { Text(L("Refresh")) } footer: {
                Text(L("While closed, Ports only reads sockets: no probes, no CPU sampling. Without the pause option, scanning slows to a third on battery. It always pauses while the Mac sleeps or the screen is locked."))
                    .foregroundStyle(.secondary).multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
            }
            Section {
                LabeledContent(L("Ports from")) {
                    HStack {
                        TextField("", value: setting(app, \.monitoredLow), format: .number.grouping(.never)).frame(width: 70)
                        Text(L("to"))
                        TextField("", value: setting(app, \.monitoredHigh), format: .number.grouping(.never)).frame(width: 70)
                    }.labelsHidden()
                }
                TextField(L("Excluded ports"), text: portList(app, \.excludedPorts), prompt: Text("e.g. 3000, 5432"))
                Toggle(L("Hide privileged ports (below 1024)"), isOn: setting(app, \.hidePrivileged))
            } header: { Text(L("Monitored Ports")) }
        }
    }
}

struct PortsSettings: View {
    let app: AppDelegate
    var body: some View {
        Form {
            Section {
                TextField(L("Favorites"), text: portList(app, \.favoritePorts), prompt: Text("3000, 5173"))
                TextField(L("Watched"), text: portList(app, \.watchedPorts), prompt: Text("8080"))
                TextField(L("Protected"), text: portList(app, \.protectedPorts), prompt: Text("5432"))
                TextField(L("Hidden"), text: portList(app, \.hiddenPorts), prompt: Text("631"))
                TextField(L("Muted"), text: portList(app, \.mutedPorts), prompt: Text("—"))
                LabeledContent(L("Hidden process groups")) {
                    HStack {
                        Text(String(app.settings.hiddenGroups.count)).foregroundStyle(.secondary)
                        Button(L("Show All")) { app.updateSettings { $0.hiddenGroups = [] } }.disabled(app.settings.hiddenGroups.isEmpty)
                    }
                }
            } header: { Text(L("Port Lists")) } footer: {
                Text(L("Comma-separated. Watched ports notify when they start, stop or are taken by something else. Protected ports must be typed to be stopped. Muted ports never notify."))
                    .foregroundStyle(.secondary).multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
            }
            Section(L("Notifications")) {
                Toggle(L("Watched ports start, stop or change owner"), isOn: setting(app, \.notifications.watchedPorts))
                Toggle(L("A new orphaned process is found"), isOn: setting(app, \.notifications.newOrphan))
                Toggle(L("A database becomes reachable from the network"), isOn: setting(app, \.notifications.exposedDatabase))
                Toggle(L("A container stops unexpectedly"), isOn: setting(app, \.notifications.containerStopped))
            }
            Section(L("History")) {
                Picker(L("Keep history for"), selection: setting(app, \.historyRetentionDays)) {
                    ForEach([1.0, 7, 30, 90], id: \.self) { Text(String(Int($0)) + " " + L("days")).tag($0) }
                }
                LabeledContent(L("Port and stop events")) {
                    Button(L("Clear History…"), role: .destructive) {
                        app.prompter.confirm(L("Clear history?"), L("Every recorded port and stop event is deleted."), button: L("Clear")) { app.history.clear() }
                    }
                }
            }
        }
    }
}

struct ClassificationSettings: View {
    let app: AppDelegate
    @ObservedObject var ui: SettingsUIState
    var body: some View {
        Form {
            Section {
                let all = app.overrides.all.sorted { $0.key < $1.key }
                if all.isEmpty {
                    Text(L("None yet. Expand a row in the panel and use Customize.")).foregroundStyle(.secondary)
                }
                ForEach(all, id: \.key) { sig, o in
                    LabeledContent {
                        HStack {
                            Text([o.kind?.title, o.favorite ? "★" : nil, o.hidden ? L("hidden") : nil, o.muted ? L("muted") : nil,
                                  o.starred ? L("starred") : nil].compactMap { $0 }.joined(separator: " · ")).foregroundStyle(.secondary)
                            Button(L("Reset")) { try? app.overrides.update(sig) { $0 = Override() }; app.refresh(full: false) }
                        }
                    } label: {
                        Text(o.name ?? (sig.split(separator: "|").dropFirst().first.map(String.init) ?? sig))
                        Text(sig.split(separator: "|").map(String.init).map(tilde).joined(separator: " · ")).lineLimit(1)
                    }
                }
            } header: { Text(L("Customized Services")) }
            Section {
                ForEach(app.settings.customMatchers, id: \.self) { m in
                    LabeledContent {
                        Button(L("Remove"), role: .destructive) { app.updateSettings { $0.customMatchers.removeAll { $0 == m } } }
                    } label: {
                        Text(m.name)
                        Text("\(m.field.rawValue) contains “\(m.pattern)” → \(m.kind.title)")
                    }
                }
                TextField(L("Name"), text: $ui.name, prompt: Text("Billing API"))
                Picker(L("Match"), selection: $ui.field) {
                    Text(L("Executable name")).tag(CustomMatcher.Field.exe)
                    Text(L("Script or tool")).tag(CustomMatcher.Field.script)
                    Text(L("Full command")).tag(CustomMatcher.Field.argv)
                }
                TextField(L("Contains"), text: $ui.pattern, prompt: Text("billing-server"))
                Picker(L("Category"), selection: $ui.kind) { ForEach(Kind.allCases, id: \.self) { Text($0.title).tag($0) } }
                HStack {
                    Spacer()
                    Button(L("Add Matcher")) {
                        let m = CustomMatcher(name: ui.name, field: ui.field, pattern: ui.pattern, kind: ui.kind)
                        app.updateSettings { $0.customMatchers.append(m) }
                        ui.name = ""; ui.pattern = ""
                    }.disabled(ui.name.isEmpty || ui.pattern.isEmpty)
                }
            } header: { Text(L("Custom Matchers")) } footer: {
                Text(L("Matchers change the name and category shown. They never change how a process is stopped or probed.")).foregroundStyle(.secondary).multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

struct OrphanSettings: View {
    let app: AppDelegate
    var body: some View {
        Form {
            Section {
                Picker(L("Call a server idle after"), selection: setting(app, \.idleThresholdMinutes)) {
                    ForEach([10.0, 30, 60, 240], id: \.self) { Text(String(Int($0)) + " min").tag($0) }
                }
                Toggle(L("Badge possible orphans (weak evidence)"), isOn: setting(app, \.showPossibleOrphans))
            } header: { Text(L("Detection")) } footer: {
                Text(L("Confirmed and likely orphans are always badged. Launchd jobs, brew services, pm2, containers and apps are never flagged."))
                    .foregroundStyle(.secondary).multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
            }
            Section {
                let starred = app.overrides.starred.sorted()
                if starred.isEmpty { Text(L("Nothing starred.")).foregroundStyle(.secondary) }
                ForEach(starred, id: \.self) { sig in
                    LabeledContent {
                        Button(L("Unstar")) { try? app.overrides.update(sig) { $0.starred = false }; app.refresh(full: false) }
                    } label: {
                        Text(sig.split(separator: "|").map(String.init).map(tilde).joined(separator: " · ")).lineLimit(2)
                    }
                }
            } header: { Text(L("Never Flagged")) }
        }
    }
}

struct DatabaseSettings: View {
    let app: AppDelegate
    var body: some View {
        Form {
            Section {
                ForEach(DatabaseType.allCases.filter { $0.scheme != nil }, id: \.self) { t in
                    LabeledContent(t.title) {
                        HStack {
                            Text(app.settings.databaseClients[t.rawValue].map(app.appTitle) ?? L("Ask the first time")).foregroundStyle(.secondary)
                            Button(L("Reset")) { app.updateSettings { $0.databaseClients[t.rawValue] = nil } }
                                .disabled(app.settings.databaseClients[t.rawValue] == nil)
                        }
                    }
                }
            } header: { Text(L("Database Clients")) } footer: {
                Text(L("Open in Database Client uses the app you choose the first time for each database type.")).foregroundStyle(.secondary).multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

struct ContainerSettings: View {
    let app: AppDelegate
    var body: some View {
        Form {
            Section {
                let rts = locateRuntimes()
                if rts.isEmpty { Text(L("No container runtime found.")).foregroundStyle(.secondary) }
                ForEach(rts, id: \.self) { r in
                    LabeledContent(r.name) { Text(tilde(r.socket)).font(.callout.monospaced()).foregroundStyle(.secondary).textSelection(.enabled) }
                }
            } header: { Text(L("Detected Runtimes")) } footer: {
                Text(L("Docker Desktop, OrbStack, Colima, Lima, Rancher Desktop and Podman are found automatically. Ports reads their local socket only.")).foregroundStyle(.secondary).multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
            }
            Section(L("Advanced")) {
                TextField(L("Socket path"), text: Binding(get: { app.settings.dockerSocketOverride ?? "" },
                                                          set: { v in app.updateSettings { $0.dockerSocketOverride = v.isEmpty ? nil : v } }),
                          prompt: Text("~/.docker/run/docker.sock"))
            }
        }
    }
}

struct CLISettings: View {
    let app: AppDelegate
    @ObservedObject var ui: SettingsUIState
    var installed: Bool { ui.cliInstalled }
    var body: some View {
        Form {
            Section {
                LabeledContent(L("ports command")) {
                    HStack {
                        Text(installed ? tilde(CLIInstaller.link) : L("Not installed")).foregroundStyle(.secondary)
                        Button(installed ? L("Uninstall") : L("Install")) {
                            do { installed ? try CLIInstaller.uninstall() : try CLIInstaller.install() } catch { app.prompter.tell(L("Command line tool"), "\(error)") }
                            ui.cliInstalled = CLIInstaller.installed
                        }
                    }
                }
            } header: { Text(L("Command Line Tool")) } footer: {
                Text(L("Links ~/.local/bin/ports to the tool inside the app. No administrator password is needed; make sure ~/.local/bin is on your PATH."))
                    .foregroundStyle(.secondary).multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
            }
            Section {
                Toggle(L("Enable MCP server"), isOn: setting(app, \.mcpEnabled))
                Toggle(L("Allow agents to stop processes"), isOn: setting(app, \.mcpAllowStop)).disabled(!app.settings.mcpEnabled)
                LabeledContent(L("Agent configuration")) {
                    Button(L("Copy MCP Config")) { copyToPasteboard(CLIInstaller.mcpSnippet) }
                }
            } header: { Text(L("Coding Agents (MCP)")) } footer: {
                Text(L("Agents can list ports, explain them and find free ports. Stopping is off by default. When allowed, it applies only to dev servers you started; databases, containers, apps and system processes are never stopped by an agent."))
                    .foregroundStyle(.secondary).multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

struct PrivacySettings: View {
    var body: some View {
        Form {
            Section {
                Label(L("No telemetry, no account, no analytics. Every probe is read-only and listed below."), systemImage: "lock.shield")
            }
            ForEach(privacyProbes, id: \.name) { p in
                Section(p.name) {
                    LabeledContent(L("When"), value: p.when)
                    LabeledContent(L("Where"), value: p.whereTo)
                    LabeledContent(L("Timeout"), value: p.timeout)
                    Text(p.what).foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct AboutSettings: View {
    var body: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 96, height: 96)
            Text(Brand.displayName).font(.largeTitle.weight(.semibold))
            Text(L("Version") + " " + UpdateCheck.currentVersion).foregroundStyle(.secondary)
            Text(L("Ports tells developers what is running locally, why it is running, whether it is safe, and how to stop it — without leaving the menu bar."))
                .multilineTextAlignment(.center).frame(maxWidth: 420).padding(.top, 6)
            Link(L("Source code and issues on GitHub"), destination: URL(string: "https://github.com/\(Brand.repository)")!).padding(.top, 4)
            Spacer()
            Text(L("MIT License. Built only on Apple frameworks, plus swift-argument-parser for the command line tool."))
                .font(.caption).foregroundStyle(.secondary).padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity)
    }
}
