import Darwin
import Foundation
import Testing
@testable import PortsCore

func p10(_ port: Int, kind: Kind = .frontend, pid: pid_t = 100, start: UInt64 = 1, exe: String = "/usr/local/bin/vite",
         memory: UInt64 = 0, project: String? = nil) -> Listener {
    var l = Listener(port: port, pid: pid, start: start, uid: getuid(), exposed: false, exe: exe, command: basename(exe),
                     argv: [basename(exe)], cwd: "/tmp/demo", kind: kind, label: "\(basename(exe)) · demo")
    l.memory = memory
    if let project { l.project = Project(root: "/tmp/\(project)", name: project) }
    if kind == .database { l.framework = "PostgreSQL" }
    return l
}

@Suite("Phase 10 · Settings")
struct SettingsTests10 {
    @Test("Defaults: MCP stop off, update check off, hot key ⌥⌘P, watched-port notifications on, others off")
    func defaults() {
        let s = Settings()
        #expect(!s.mcpAllowStop && !s.mcpEnabled && !s.updateCheck)
        #expect(s.hotKey == .default)
        #expect(s.notifications.watchedPorts && !s.notifications.newOrphan && !s.notifications.exposedDatabase && !s.notifications.containerStopped)
        #expect(s.refreshClosed == 10 && s.refreshOpen == 2 && s.historyRetentionDays == 7)
    }

    @Test("Old or partial files keep their values; bad values fall back; hotKey null means off")
    func tolerant() throws {
        let s = try JSONDecoder().decode(Settings.self, from: Data(#"{"protectedPorts":[5432],"refreshClosed":"oops","hotKey":null,"mystery":1}"#.utf8))
        #expect(s.protectedPorts == [5432] && s.refreshClosed == 10 && s.hotKey == nil)
        let round = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(s))
        #expect(round == s)
    }

    @Test("Port lists and the monitored range")
    func ports() {
        #expect(parsePortList("3000, 5173 8080;3000\n70000 abc 1") == [3000, 5173, 8080, 1])
        var s = Settings()
        s.monitoredLow = 1000; s.monitoredHigh = 9000; s.excludedPorts = [3000]
        #expect(s.isMonitored(5173) && !s.isMonitored(3000) && !s.isMonitored(9001) && !s.isMonitored(80))
        s = Settings(); s.hidePrivileged = true
        #expect(!s.isMonitored(631) && s.isMonitored(1024))
    }

    @Test("Update check compares versions numerically")
    func versions() {
        #expect(versionIsNewer("v1.10.0", than: "1.9.2"))
        #expect(!versionIsNewer("v1.2", than: "1.2.0"))
        #expect(!versionIsNewer("1.0.0", than: "1.0.1"))
    }
}

@Suite("Phase 10 · Panel")
struct PanelTests10 {
    let rows = [p10(5173, project: "shop"), p10(8000, kind: .backend, pid: 101, start: 5, exe: "/usr/bin/python3", memory: 900),
                p10(5432, kind: .database, pid: 102, start: 2, exe: "/opt/homebrew/bin/postgres", memory: 50),
                p10(631, kind: .system, pid: 103, exe: "/usr/sbin/cupsd")]

    @Test("Search matches port, process, project; every word must match")
    func search() {
        #expect(matchesSearch(rows[0], ":5173") && matchesSearch(rows[0], "shop vite") && !matchesSearch(rows[0], "shop python"))
        #expect(matchesSearch(rows[1], "PYTHON") && matchesSearch(rows[1], ""))
    }

    @Test("Filters: developer hides system; databases; favorites by port")
    func filters() {
        var s = Settings(); s.favoritePorts = [8000]
        let a = Analysis()
        #expect(filtered(rows, filter: .developer, search: "", settings: s, analysis: a, showHidden: false).map(\.port) == [5173, 8000, 5432])
        #expect(filtered(rows, filter: .databases, search: "", settings: s, analysis: a, showHidden: false).map(\.port) == [5432])
        #expect(filtered(rows, filter: .favorites, search: "", settings: s, analysis: a, showHidden: false).map(\.port) == [8000])
        #expect(filtered(rows, filter: .all, search: "", settings: s, analysis: a, showHidden: false).count == 4)
    }

    @Test("Hidden ports and process groups come back with Show Hidden")
    func hidden() {
        var s = Settings(); s.hiddenPorts = [5173]; s.hiddenGroups = ["/usr/bin/python3"]
        #expect(filtered(rows, filter: .all, search: "", settings: s, analysis: Analysis(), showHidden: false).map(\.port) == [5432, 631])
        #expect(filtered(rows, filter: .all, search: "", settings: s, analysis: Analysis(), showHidden: true).count == 4)
    }

    @Test("Sections: favorites first, then categories; sort by memory and uptime; group by starter")
    func sections() {
        var s = Settings(); s.favoritePorts = [5432]
        let secs = panelSections(rows, filter: .all, search: "", sort: .category, settings: s, analysis: Analysis())
        #expect(secs.map(\.id) == ["favorites", "frontend", "backend", "system"])
        let mem = panelSections(rows, filter: .all, search: "", sort: .memory, settings: Settings(), analysis: Analysis())
        #expect(mem.first?.rows.map(\.port).prefix(2) == [8000, 5432])
        let up = panelSections(rows, filter: .all, search: "", sort: .uptime, settings: Settings(), analysis: Analysis())
        #expect(up.first?.rows.first?.start == 1)
        var a = Analysis()
        a.starters[processKey(rows[0])] = Starter(kind: .agent, name: "Claude Code", pid: 9)
        let st = panelSections(rows, filter: .all, search: "", sort: .starter, settings: Settings(), analysis: a)
        #expect(st.map(\.title) == ["Claude Code", "Unknown launcher"])
    }

    @Test("NEW: only rows that appeared since the last open; nothing on first open")
    func newBadge() {
        #expect(newKeys(current: rows, seenAtLastOpen: nil).isEmpty)
        #expect(newKeys(current: rows, seenAtLastOpen: Set(rows.dropFirst().map(listenerKey))) == [listenerKey(rows[0])])
    }

    @Test("Custom matchers rename and move, but stop policy and probing keep the detected kind")
    func matchers() {
        let m = CustomMatcher(name: "Billing DB", field: .exe, pattern: "postgres", kind: .backend)
        let r = applyCustomMatchers(rows, [m])
        let db = r.first { $0.port == 5432 }!
        #expect(db.kind == .backend && db.framework == "Billing DB" && db.baseKind == .database)
        #expect(StopPolicy(db) == .dataStore && !isWebCandidate(db))
        #expect(applyCustomMatchers(rows, [CustomMatcher(name: "x", field: .argv, pattern: "", kind: .app)]) == rows)
    }

    @Test("Status item: dev count, all count, none; dot for warnings or orphans")
    func status() {
        var s = Settings()
        #expect(statusSummary(rows, analysis: Analysis(), settings: s).title == " 3")
        s.statusDisplay = "all"
        #expect(statusSummary(rows, analysis: Analysis(), settings: s).title == " 4")
        s.statusDisplay = "none"
        #expect(statusSummary(rows, analysis: Analysis(), settings: s).title.isEmpty)
        var a = Analysis()
        a.issues = [Issue(id: "x", severity: .warning, title: "t", explanation: "e", fix: nil)]
        #expect(statusSummary(rows, analysis: a, settings: Settings()).dot)
        #expect(!statusSummary(rows, analysis: Analysis(), settings: Settings()).dot)
    }
}

@Suite("Phase 10 · History")
struct HistoryTests10 {
    func store(maxBytes: Int = 2_000_000) -> HistoryStore {
        HistoryStore(url: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ports-p10-\(UUID().uuidString)/history.jsonl"),
                     maxBytes: maxBytes)
    }

    @Test("Appeared and disappeared events from two scans")
    func diff() {
        let a = p10(3000), b = p10(4000, pid: 2)
        let e = diffEvents(previous: [a], current: [b], now: Date(timeIntervalSince1970: 0))
        #expect(e.map(\.kind) == [.disappeared, .appeared] && e.map(\.port) == [3000, 4000])
        #expect(diffEvents(previous: [a], current: [a]).isEmpty)
    }

    @Test("Append, load with filter, prune by age and size, clear")
    func store() {
        let h = store(maxBytes: 400)
        defer { h.clear() }
        let now = Date(timeIntervalSince1970: 1_000_000)
        h.append([HistoryEvent(at: now.addingTimeInterval(-10 * 86_400), kind: .appeared, port: 1, pid: 1, name: "old"),
                  HistoryEvent(at: now, kind: .stop, port: 3000, pid: 2, name: "vite", by: "app", method: "signal ladder", result: "stopped")])
        #expect(h.load().count == 2)
        #expect(h.load(filter: "ladder").map(\.name) == ["vite"])
        #expect(h.load().last?.line.contains("by app · signal ladder · stopped") == true)
        h.prune(retentionDays: 7, now: now)
        #expect(h.load().map(\.name) == ["vite"])
        h.append((0..<20).map { (i: Int) in HistoryEvent(at: now, kind: .appeared, port: i, pid: 1, name: "row\(i)") })
        h.prune(retentionDays: 7, now: now)
        let left = h.load()
        #expect(left.last?.name == "row19", "\(left.map(\.name))")
        #expect(!left.isEmpty && left.count < 21 && left.last?.name == "row19")      // oldest dropped to fit 400 bytes
        h.clear()
        #expect(h.load().isEmpty)
    }
}

@Suite("Phase 10 · Energy and notifications")
struct EnergyTests10 {
    @Test("Cadence: open fast, closed slow, battery slower or paused, sleep/lock/user pause stop it")
    func cadence() {
        var i = CadenceInput()
        var s = Settings()
        #expect(scanInterval(i, settings: s) == 10)
        i.panelOpen = true
        #expect(scanInterval(i, settings: s) == 2)
        i.panelOpen = false; i.onBattery = true
        #expect(scanInterval(i, settings: s) == 30)
        s.pauseOnBattery = true
        #expect(scanInterval(i, settings: s) == nil)
        i = CadenceInput(); i.lowPower = true
        #expect(scanInterval(i, settings: Settings()) == 30)
        for set in [\CadenceInput.asleep, \.screenLocked, \.userPaused] {
            var j = CadenceInput(); j[keyPath: set] = true; j.panelOpen = true
            #expect(scanInterval(j, settings: Settings()) == nil)
        }
        #expect(timerTolerance(10) == 5)
    }

    @Test("Watched port start, stop, conflict; muted never notifies")
    func watched() {
        var s = Settings(); s.watchedPorts = [3000]
        let owners = WatchedOwners()
        let vite = p10(3000)
        let start = notifications(previous: [p10(9)], current: [p10(9), vite], previousAnalysis: Analysis(), analysis: Analysis(),
                                  settings: s, owners: owners)
        #expect(start.map(\.kind) == [.watchedStarted])
        let stop = notifications(previous: [vite], current: [p10(9)], previousAnalysis: Analysis(), analysis: Analysis(), settings: s, owners: owners)
        #expect(stop.map(\.kind) == [.watchedStopped])
        let other = p10(3000, kind: .backend, pid: 7, exe: "/usr/bin/python3")
        let conflict = notifications(previous: [p10(9)], current: [other], previousAnalysis: Analysis(), analysis: Analysis(), settings: s, owners: owners)
        #expect(conflict.map(\.kind) == [.watchedConflict])
        s.mutedPorts = [3000]
        #expect(notifications(previous: [p10(9)], current: [vite], previousAnalysis: Analysis(), analysis: Analysis(), settings: s, owners: owners).isEmpty)
        s.mutedPorts = []; s.notifications.watchedPorts = false
        #expect(notifications(previous: [p10(9)], current: [vite], previousAnalysis: Analysis(), analysis: Analysis(), settings: s, owners: owners).isEmpty)
    }

    @Test("Opt-in types: new orphan, exposed database, container stopped (not when Ports stopped it)")
    func optIn() {
        var s = Settings()
        s.notifications.newOrphan = true; s.notifications.exposedDatabase = true; s.notifications.containerStopped = true
        let l = p10(3000)
        var a = Analysis()
        a.verdicts[processKey(l)] = OrphanVerdict(level: .confirmed, evidence: ["parent exited"], safeToStop: .green)
        var db = p10(5432, kind: .database, pid: 5, exe: "/opt/homebrew/bin/postgres")
        db.framework = "PostgreSQL"; db.exposure = .allInterfaces
        var c = p10(55432, kind: .docker, pid: 6, exe: "/opt/homebrew/bin/gvproxy"); c.container = "demo-db"
        let n = notifications(previous: [c], current: [l, db], previousAnalysis: Analysis(), analysis: a, settings: s, owners: WatchedOwners())
        #expect(Set(n.map(\.kind)) == [.newOrphan, .exposedDatabase, .containerStopped])
        let ours = notifications(previous: [c], current: [], previousAnalysis: Analysis(), analysis: Analysis(), settings: s,
                                 owners: WatchedOwners(), stoppedByUs: ["demo-db"])
        #expect(ours.isEmpty)
        #expect(notifications(previous: [c], current: [l, db], previousAnalysis: Analysis(), analysis: a, settings: Settings(), owners: WatchedOwners()).isEmpty)
    }

    @Test("Privacy list names every probe with when, where (loopback or local) and a timeout")
    func privacy() {
        let names = privacyProbes.map(\.name)
        for n in ["HTTP probe", "TLS hello", "Database handshake", "Docker Engine socket", "ngrok agent API"] { #expect(names.contains(n)) }
        for p in privacyProbes { #expect(!p.when.isEmpty && !p.whereTo.isEmpty && !p.timeout.isEmpty) }
        #expect(privacyProbes.filter { $0.whereTo.contains("api.github.com") }.count == 1)
    }
}
