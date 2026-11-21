// Phase 10: what the panel shows — filters, search, sort and grouping, NEW rows, hidden ports and groups,
// custom matchers, and the status item's count/dot/tooltip. Pure functions, shared by app and tests.
import Foundation

public enum PanelFilter: Int, CaseIterable, Sendable {
    case developer, all, favorites, leftovers, containers, databases, tunnels
    public var title: String { ["Developer", "All", "Favorites", "Leftovers", "Containers", "Databases", "Tunnels"][rawValue] }
}

public enum PanelSort: String, CaseIterable, Sendable {
    case category, port, project, uptime, memory, starter
    public var title: String {
        ["category": "Category", "port": "Port", "project": "Project", "uptime": "Uptime", "memory": "Memory",
         "starter": "Started by"][rawValue]!
    }
}

public struct PanelSection: Equatable, Sendable {
    public let id: String
    public let title: String
    public let rows: [Listener]
}

/// Search by port, process, framework, project, branch, container or page title (case-insensitive; all words must match).
public func matchesSearch(_ l: Listener, _ query: String) -> Bool {
    let words = query.lowercased().split(separator: " ").map(String.init)
    guard !words.isEmpty else { return true }
    let hay = ([String(l.port), ":\(l.port)", l.label, l.exe, appName(l.exe), l.framework ?? "", l.project?.name ?? "",
                l.project?.repo ?? "", l.project?.branch ?? "", l.container ?? "", l.containerInfo?.image ?? "",
                l.webInfo?.title ?? "", l.kind.title, l.override?.note ?? ""]).joined(separator: " ").lowercased()
    return words.allSatisfy(hay.contains)
}

/// A process group to hide with Option-click: everything from one executable.
public func processGroup(_ l: Listener) -> String { l.exe }

public func isHidden(_ l: Listener, settings: Settings) -> Bool {
    l.override?.hidden == true || settings.hiddenPorts.contains(l.port) || settings.hiddenGroups.contains(processGroup(l))
        || !settings.isMonitored(l.port)
}

public func isFavorite(_ l: Listener, settings: Settings) -> Bool {
    l.override?.favorite == true || settings.favoritePorts.contains(l.port)
}

/// Rows for one filter, before sorting: hidden rows only with `showHidden`.
public func filtered(_ ls: [Listener], filter: PanelFilter, search: String, settings: Settings, analysis: Analysis,
                     showHidden: Bool) -> [Listener] {
    ls.filter { l in
        if !showHidden && isHidden(l, settings: settings) { return false }
        guard matchesSearch(l, search) else { return false }
        switch filter {
        case .developer: return showsInDeveloperView(l)
        case .all: return true
        case .favorites: return isFavorite(l, settings: settings)
        case .leftovers: return (analysis.verdict(l)?.level ?? .notOrphan) >= .likely
        case .containers: return l.baseKind == .docker || l.container != nil
        case .databases: return knownDatabase(l) != nil
        case .tunnels: return l.baseKind == .tunnel || l.exposedVia != nil
        }
    }
}

func sortKey(_ l: Listener, _ sort: PanelSort) -> [String] {
    let port = String(format: "%05d", l.port)
    switch sort {
    case .category, .starter: return [String(format: "%02d", l.kind.rawValue), port]
    case .port: return [port]
    case .project: return [l.project?.display.lowercased() ?? "~", port]
    case .uptime: return [String(format: "%020llu", l.start), port]                                // oldest first
    case .memory: return [String(format: "%020llu", UInt64.max - l.memory), port]                  // biggest first
    }
}

/// Sections: Favorites first (unless filtering favorites), then one section per category — or per starter
/// with `.starter` — or one flat list for port/project/uptime/memory.
public func panelSections(_ ls: [Listener], filter: PanelFilter, search: String, sort: PanelSort, settings: Settings,
                          analysis: Analysis, showHidden: Bool = false) -> [PanelSection] {
    let rows = filtered(ls, filter: filter, search: search, settings: settings, analysis: analysis, showHidden: showHidden)
        .sorted { sortKey($0, sort).lexicographicallyPrecedes(sortKey($1, sort)) }
    var out: [PanelSection] = []
    let favs = filter == .favorites ? [] : rows.filter { isFavorite($0, settings: settings) }
    if !favs.isEmpty { out.append(PanelSection(id: "favorites", title: "Favorites", rows: favs)) }
    let rest = rows.filter { filter == .favorites || !isFavorite($0, settings: settings) }
    switch sort {
    case .category:
        for k in Kind.allCases {
            let r = rest.filter { $0.kind == k }
            if !r.isEmpty { out.append(PanelSection(id: k.id, title: k.title, rows: r)) }
        }
    case .starter:
        var groups: [String: [Listener]] = [:]
        for l in rest {
            let name = analysis.starter(l).map { $0.kind == .unknown ? "Unknown launcher" : $0.name } ?? "Unknown launcher"
            groups[name, default: []].append(l)
        }
        for name in groups.keys.sorted(by: { ($0 == "Unknown launcher" ? 1 : 0, $0) < ($1 == "Unknown launcher" ? 1 : 0, $1) }) {
            out.append(PanelSection(id: "starter-" + name, title: name, rows: groups[name]!))
        }
    default:
        if !rest.isEmpty { out.append(PanelSection(id: "all", title: sort.title, rows: rest)) }
    }
    return out
}

/// Listeners that appeared since the panel was last opened.
public func newKeys(current: [Listener], seenAtLastOpen: Set<String>?) -> Set<String> {
    guard let seen = seenAtLastOpen else { return [] }          // first open: nothing is "new"
    return Set(current.map(listenerKey)).subtracting(seen)
}

/// Apply custom matchers (display only: the detected kind is kept for safety decisions).
public func applyCustomMatchers(_ ls: [Listener], _ matchers: [CustomMatcher]) -> [Listener] {
    guard !matchers.isEmpty else { return ls }
    return ls.map { l in
        let names = identityNames(exe: l.exe, argv: l.argv)
        for m in matchers where !m.pattern.isEmpty {
            let p = m.pattern.lowercased()
            let hit: Bool
            switch m.field {
            case .exe: hit = basename(l.exe).lowercased().contains(p)
            case .script: hit = names.dropFirst().contains { $0.contains(p) }
            case .argv: hit = l.command.lowercased().contains(p)
            }
            guard hit else { continue }
            var r = l
            if r.kind != m.kind { r.detectedKind = l.baseKind; r.kind = m.kind }
            r.framework = m.name
            r.confidence = 100
            if l.override?.name == nil { r.label = rowLabel(kind: m.kind, tool: m.name, cwd: l.cwd, project: l.project) }
            return r
        }
        return l
    }
}

public struct StatusSummary: Equatable, Sendable {
    public let title: String        // " 3" or ""
    public let dot: Bool            // Doctor issues or a confirmed orphan
    public let tooltip: String
}

/// The status item: count of dev listeners (or all, or none), a red dot for problems, and a one-line tooltip.
public func statusSummary(_ ls: [Listener], analysis: Analysis, settings: Settings) -> StatusSummary {
    let visible = ls.filter { !isHidden($0, settings: settings) }
    let dev = visible.filter { $0.kind.isDeveloper }
    let n = settings.statusDisplay == "all" ? visible.count : dev.count
    let orphan = ls.contains { analysis.verdict($0)?.level == .confirmed } || !analysis.leftovers.isEmpty
    let problems = analysis.issues.filter { $0.severity >= .warning }.count
    var tip = "\(Brand.displayName): \(dev.count) dev server\(dev.count == 1 ? "" : "s"), \(visible.count) listening"
    if problems > 0 { tip += " · \(problems) issue\(problems == 1 ? "" : "s")" }
    return StatusSummary(title: settings.statusDisplay == "none" || n == 0 ? "" : " \(n)", dot: problems > 0 || orphan, tooltip: tip)
}
