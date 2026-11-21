import AppKit
import Darwin
import PortsCore
import SwiftUI

struct InfoLine: Identifiable {
    let id = UUID()
    let text: String
    let symbol: String?
}

struct RowAction: Identifiable {
    let id = UUID()
    let title: String
    let symbol: String
    var destructive = false
    var checked: Bool? = nil
    let run: () -> Void
}

struct Badge: Identifiable, Equatable {
    var id: String { text }
    let text: String
    let color: Color
}

@MainActor
final class PanelModel: ObservableObject {
    weak var app: AppDelegate?
    @Published var listeners: [Listener] = []
    @Published var analysis = Analysis()
    @Published var containers: ContainerSnapshot?
    @Published var filter: PanelFilter = PanelFilter(rawValue: UserDefaults.standard.integer(forKey: "panelFilter")) ?? .developer {
        didSet { UserDefaults.standard.set(filter.rawValue, forKey: "panelFilter") }
    }
    @Published var sort: PanelSort = PanelSort(rawValue: UserDefaults.standard.string(forKey: "panelSort") ?? "") ?? .category {
        didSet { UserDefaults.standard.set(sort.rawValue, forKey: "panelSort") }
    }
    @Published var search = ""
    @Published var expanded: String?
    @Published var focused: String?
    @Published var selection = Set<String>()
    @Published var prompt: InlinePrompt?
    @Published var newKeys = Set<String>()
    @Published var lastScan: Date?
    @Published var showHidden = false
    @Published var showHistory = false
    @Published var updateTag: String?
    // View state (kept here rather than in SwiftUI @State)
    @Published var hoverKey: String?
    @Published var customizeOpen = false
    @Published var openIssues = Set<String>()
    @Published var promptText = ""
    @Published var historyFilter = "" { didSet { loadHistory() } }
    @Published var historyEvents: [HistoryEvent] = []

    func loadHistory() { historyEvents = app?.history.load(filter: historyFilter) ?? [] }
    var pendingPrompts: [String: InlinePrompt] = [:]
    private var seenAtLastOpen: Set<String>?

    var settings: PortsCore.Settings { app?.settings ?? PortsCore.Settings() }

    var sections: [PanelSection] {
        panelSections(listeners, filter: filter, search: search, sort: sort, settings: settings, analysis: analysis, showHidden: showHidden)
    }
    var visibleRows: [Listener] { sections.flatMap(\.rows) }
    var hiddenCount: Int { listeners.filter { isHidden($0, settings: settings) }.count }

    func update(listeners ls: [Listener], analysis a: Analysis?, containers c: ContainerSnapshot?) {
        lastScan = Date()
        if ls != listeners { listeners = ls }
        if let a, a.issues != analysis.issues || a.verdicts != analysis.verdicts || a.leftovers != analysis.leftovers
            || a.duplicates != analysis.duplicates || a.starters != analysis.starters { analysis = a }
        containers = c
    }

    func panelWillOpen() {
        newKeys = PortsCore.newKeys(current: listeners, seenAtLastOpen: seenAtLastOpen)
        UpdateCheck.runIfDue(enabled: settings.updateCheck) { tag in
            Task { @MainActor in self.updateTag = tag }
        }
    }

    func panelDidClose() {
        seenAtLastOpen = Set(listeners.map(listenerKey))
        prompt = nil
        selection.removeAll()
        showHistory = false
    }

    func row(_ key: String?) -> Listener? { key.flatMap { k in listeners.first { listenerKey($0) == k } } }

    /// ↑/↓ keyboard navigation over the visible rows.
    func move(_ delta: Int) {
        let keys = visibleRows.map(listenerKey)
        guard !keys.isEmpty else { return }
        let i = focused.flatMap { keys.firstIndex(of: $0) } ?? (delta > 0 ? -1 : keys.count)
        focused = keys[max(0, min(keys.count - 1, i + delta))]
    }

    // MARK: Row content

    func badges(_ l: Listener) -> [Badge] {
        var b: [Badge] = []
        let key = listenerKey(l)
        if newKeys.contains(key) { b.append(Badge(text: "NEW", color: .green)) }
        let db = knownDatabase(l) != nil
        if l.exposed { b.append(Badge(text: db ? "NETWORK" : "LAN", color: db ? .red : .orange)) }
        if let v = analysis.verdict(l), v.level >= (settings.showPossibleOrphans ? .possible : .likely) {
            b.append(Badge(text: v.level == .possible ? "ORPHAN?" : "ORPHAN", color: .purple))
        }
        if analysis.isDuplicate(l) { b.append(Badge(text: "TWICE", color: .blue)) }
        if l.stopped { b.append(Badge(text: app?.pausedByUs.contains(processKey(l)) == true ? "PAUSED" : "STOPPED", color: .yellow)) }
        if l.isIdle && (l.baseKind == .frontend || l.baseKind == .backend) && l.port > 0 { b.append(Badge(text: "IDLE", color: .gray)) }
        if l.container != nil { b.append(Badge(text: "CONTAINER", color: .teal)) }
        if db { b.append(Badge(text: "DB", color: .cyan)) }
        if l.baseKind == .tunnel { b.append(Badge(text: "TUNNEL", color: .pink)) }
        if l.exposedVia != nil || l.tunnel?.publicURL != nil { b.append(Badge(text: "PUBLIC", color: .pink)) }
        if l.webInfo?.isJSON == true { b.append(Badge(text: "JSON", color: .indigo)) }
        if !l.workers.isEmpty { b.append(Badge(text: "×\(l.workers.count + 1)", color: .secondary)) }
        return b
    }

    /// "200 · 34 ms · My App · running 2 h 3 min"
    func subtitle(_ l: Listener) -> String {
        var parts: [String] = []
        if let w = l.webInfo, !w.summary.isEmpty { parts.append(w.summary) }
        if let t = l.tunnel?.publicURL ?? l.publicURL { parts.append(t) }
        if l.start > 0 { parts.append(formatUptime(uptimeSeconds(start: l.start))) }
        return parts.joined(separator: " · ")
    }

    /// Spoken by VoiceOver for a row (and read by the UI smoke test).
    func accessibilityLabel(_ l: Listener) -> String {
        let badges = self.badges(l).map(\.text).joined(separator: ", ")
        let sub = subtitle(l)
        return "Port \(l.port), \(l.label), \(l.kind.title)" + (badges.isEmpty ? "" : ", " + badges) + (sub.isEmpty ? "" : ", " + sub)
            + ", PID \(l.pid)"
    }

    func info(_ l: Listener) -> [InfoLine] {
        var lines: [InfoLine] = []
        func add(_ t: String, _ s: String? = nil) { lines.append(InfoLine(text: t, symbol: s)) }
        add("PID \(l.pid) · " + (l.exposed ? L("Reachable from your network") : L("Local only")) + " (\(l.addresses.joined(separator: ", ")))",
            l.exposed ? "wifi.exclamationmark" : "lock")
        if let why = KnownPorts.explanation(l) { add(why, "info.circle") }
        else if let k = KnownPorts.info(port: l.port) { add("Port \(l.port): \(k.owner) — \(k.explanation)", "info.circle") }
        if let p = l.project { add(p.displayWithBranch, "folder.badge.gearshape") }
        if !l.cwd.isEmpty && l.cwd != "/" { add(tilde(l.cwd), "folder") }
        add(tilde(l.command), "terminal")
        var stats = [formatUptime(uptimeSeconds(start: l.start))]
        if l.memory > 0 { stats.append(formatBytes(l.memory)) }
        if let cpu = l.cpuPercent { stats.append(String(format: "%.1f%% CPU", cpu)) }
        add(stats.joined(separator: " · "), "clock")
        add(l.connections == 0 ? L("Idle — no open connections") : "\(l.connections) " + L("open connections"), "arrow.left.arrow.right")
        if !l.workers.isEmpty { add("\(l.workers.count) " + L("workers") + ": PID " + l.workers.map(String.init).joined(separator: ", "), "square.stack.3d.up") }
        if !l.chain.isEmpty {
            add(L("Launched by") + " " + l.chain.prefix(6).map { "\($0.command) (\($0.pid))" }.joined(separator: " ← "), "arrow.turn.left.up")
        }
        if let s = analysis.starter(l) { add(L("Started by") + ": " + (s.pid.map { "\(s.name) (PID \($0))" } ?? s.name), "person.crop.circle") }
        add("\(l.framework ?? l.kind.title) · \(l.confidence)% " + L("confident"), "checkmark.seal")
        switch l.tier {
        case .safe: add(L("Dev server you started: safe to stop"), "checkmark.shield")
        case .warning: add(L("Stop with care") + ": " + (l.baseKind == .database ? L("may lose unsaved data") : L("an app, service or engine")), "exclamationmark.shield")
        case .blocked: add(L("Protected: system or another user"), "lock.shield")
        }
        if let v = analysis.verdict(l) {
            add(L("Safe to stop?") + " \(v.safeToStop.title) · \(v.level.title)", "questionmark.circle")
            for e in v.evidence { add("• " + e) }
        }
        if let c = l.containerInfo {
            add("Container \(c.name)\(c.id.isEmpty ? "" : " (\(c.id.prefix(12)))") · \(c.image)", "shippingbox")
            if let p = c.project { add("Compose: \(p)\(c.service.map { " / " + $0 } ?? "")", "square.stack.3d.up") }
            if !c.status.isEmpty { add(c.status + (c.runtime.map { " · " + $0.name } ?? ""), "heart.text.square") }
            if c.publishedOnAllInterfaces(l.port) {
                let priv = c.ports.first { $0.publicPort == l.port }?.privatePort ?? l.port
                add("⚠️ " + L("Published on all interfaces: use") + " 127.0.0.1:\(l.port):\(priv)")
            }
        }
        if let (db, source) = knownDatabase(l) {
            add("\(db.title) (" + L("recognised by") + " \(["process": L("its process"), "image": L("its container image"), "handshake": L("a read-only handshake")][source.rawValue]!))",
                "cylinder.split.1x2")
        }
        if let t = l.tunnel { add(t.summary + " · " + L("shown only; Ports doesn't manage tunnels"), "arrow.left.arrow.right.circle") }
        if let via = l.exposedVia { add(via, "globe") }
        if l.exposure == .loopback && (l.baseKind == .frontend || l.baseKind == .backend) { add(exposeHint(l), "iphone") }
        if let note = l.override?.note { add(L("Note") + ": " + note, "note.text") }
        return lines
    }

    func actions(_ l: Listener) -> [RowAction] {
        guard let app else { return [] }
        var a: [RowAction] = []
        if let link = KnownPorts.settingsAction(l) { a.append(RowAction(title: link.title, symbol: "gearshape") { NSWorkspace.shared.open(link.url) }) }
        if let scheme = l.web, let url = browserURL(l, scheme) {
            a.append(RowAction(title: L("Open in Browser"), symbol: "safari") { NSWorkspace.shared.open(url) })
            a.append(RowAction(title: L("Copy URL"), symbol: "link") { copyToPasteboard(url.absoluteString) })
        }
        if l.port > 0 { a.append(RowAction(title: L("Copy") + " \(hostPort(l))", symbol: "doc.on.doc") { copyToPasteboard(hostPort(l)) }) }
        if let lan = lanURL(l) {
            a.append(RowAction(title: L("Copy LAN URL"), symbol: "wifi") { copyToPasteboard(lan.absoluteString) })
            a.append(RowAction(title: L("Show QR Code"), symbol: "qrcode") { app.showQR(lan) })
        }
        if let url = l.tunnel?.publicURL ?? l.publicURL { a.append(RowAction(title: L("Copy Public URL"), symbol: "globe") { copyToPasteboard(url) }) }
        if let (db, _) = knownDatabase(l) {
            if let url = connectionURL(db, l) {
                let apps = NSWorkspace.shared.urlsForApplications(toOpen: url).map(\.path)
                let remembered = settings.databaseClients[db.rawValue].flatMap { apps.contains($0) ? $0 : nil }
                let ranked = rankClients(apps, remembered: remembered)
                if let r = remembered {
                    a.append(RowAction(title: L("Open in") + " \(app.appTitle(r))", symbol: "arrow.up.forward.app") { app.open(url, with: r) })
                } else if !ranked.isEmpty {
                    a.append(RowAction(title: L("Open in Database Client…"), symbol: "arrow.up.forward.app") { app.chooseClient(db, url: url, apps: ranked) })
                }
                for other in ranked where other != remembered && remembered != nil {
                    a.append(RowAction(title: L("Open in") + " \(app.appTitle(other))", symbol: "arrow.up.forward.app") { app.open(url, with: other) })
                }
                a.append(RowAction(title: L("Copy Connection URL"), symbol: "link") { copyToPasteboard(url.absoluteString) })
            }
            if let cmd = cliCommand(db, l) { a.append(RowAction(title: L("Copy") + " “\(cmd)”", symbol: "terminal") { copyToPasteboard(cmd) }) }
        }
        if !l.cwd.isEmpty && l.cwd != "/" {
            a.append(RowAction(title: L("Show Folder in Finder"), symbol: "folder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: l.cwd)]) })
        }
        a.append(RowAction(title: L("Reveal Executable"), symbol: "magnifyingglass") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: l.exe)]) })
        a.append(RowAction(title: L("Copy PID"), symbol: "number") { copyToPasteboard("\(l.pid)") })
        if l.uid == getuid() && !l.argv.isEmpty && l.container == nil {
            a.append(RowAction(title: L("Copy Start Command"), symbol: "doc.on.clipboard") { copyToPasteboard(l.startCommand) })
            a.append(RowAction(title: L("Run in Terminal…"), symbol: "terminal") { app.runInTerminal(l) })
        }
        if l.framework == nil || l.kind == .system || l.kind == .service, let s = webSearchURL(l) {
            a.append(RowAction(title: L("Search the Web"), symbol: "magnifyingglass.circle") { NSWorkspace.shared.open(s) })
        }
        if let c = l.container {
            a.append(RowAction(title: L("Restart Container…"), symbol: "arrow.clockwise.circle") { app.restartContainer(c, port: l.port) })
            a.append(RowAction(title: L("Copy Logs Command"), symbol: "doc.text") { copyToPasteboard(logsCommand(c)) })
        }
        if let older = analysis.olderInstance(of: l) {
            a.append(RowAction(title: L("Stop the Older One") + " (:\(older.port))…", symbol: "clock.arrow.circlepath", destructive: true) { app.stop(older) })
        }
        // Stop & lifecycle
        if KnownPorts.restartsAutomatically(l) {
            a.append(RowAction(title: L("Why Can't I Stop It?"), symbol: "arrow.clockwise") { app.explainRestart(l) })
        } else if l.uid == getuid() {
            let title = l.container.map { L("Stop Container") + " “\($0)”…" } ?? (l.baseKind == .database ? L("Shut Down…") : L("Stop…"))
            a.append(RowAction(title: title, symbol: "xmark.octagon", destructive: true) { app.stop(l) })
            if l.container == nil {
                a.append(RowAction(title: l.workers.isEmpty ? L("Stop with Children…") : L("Stop All Workers…"), symbol: "arrow.triangle.branch",
                                   destructive: true) { app.stopTree(l) })
                a.append(l.stopped ? RowAction(title: L("Resume"), symbol: "play.circle") { app.setPaused(l, false) }
                                   : RowAction(title: L("Pause"), symbol: "pause.circle") { app.setPaused(l, true) })
            }
        }
        return a
    }

    func customizeActions(_ l: Listener) -> [RowAction] {
        guard let app else { return [] }
        let o = l.override ?? Override()
        var a: [RowAction] = [
            RowAction(title: L("Rename…"), symbol: "pencil") { app.rename(l) },
            RowAction(title: L("Note…"), symbol: "note.text") { app.note(l) },
            RowAction(title: o.linkedApp == nil ? L("Link to App…") : L("Unlink App"), symbol: "link") { app.linkApp(l) },
            RowAction(title: L("Favorite"), symbol: "star", checked: o.favorite) { app.customize(l) { $0.favorite.toggle() } },
            RowAction(title: L("Hide"), symbol: "eye.slash", checked: o.hidden) { app.customize(l) { $0.hidden.toggle() } },
            RowAction(title: L("Hide Process Group"), symbol: "eye.slash.circle") { app.hideGroup(l) },
            RowAction(title: L("Mute Notifications"), symbol: "bell.slash", checked: o.muted) { app.customize(l) { $0.muted.toggle() } },
            RowAction(title: L("Star (Never Flag)"), symbol: "star.circle", checked: o.starred) { app.customize(l) { $0.starred.toggle() } },
        ]
        if l.port > 0 {
            a.append(RowAction(title: L("Watch Port") + " :\(l.port)", symbol: "bell", checked: settings.watchedPorts.contains(l.port)) {
                app.togglePort(l.port, in: \.watchedPorts) })
            a.append(RowAction(title: L("Protect Port") + " :\(l.port)", symbol: "lock", checked: settings.isProtected(l.port)) {
                app.togglePort(l.port, in: \.protectedPorts) })
        }
        for k in Kind.allCases where k != l.kind {
            a.append(RowAction(title: L("Move to") + " " + k.title, symbol: "folder") { app.customize(l) { $0.kind = k == l.baseKind ? nil : k } })
        }
        if !o.isEmpty { a.append(RowAction(title: L("Reset Customizations"), symbol: "arrow.uturn.backward") { app.customize(l) { $0 = Override() } }) }
        return a
    }
}
