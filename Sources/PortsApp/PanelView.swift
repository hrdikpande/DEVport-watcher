import AppKit
import PortsCore
import SwiftUI

struct PanelView: View {
    @ObservedObject var model: PanelModel
    let app: AppDelegate
    @FocusState private var searchFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            header
            if let p = model.prompt { PromptView(prompt: p, model: model) { model.prompt = nil }.padding(8) }
            Divider()
            if model.showHistory { HistoryView(model: model, close: { model.showHistory = false }) } else { list }
            Divider()
            footer
        }
        .frame(width: 480, height: 640)
        .background(.regularMaterial)
        .background(shortcuts)
        .onKeyPress(.downArrow) { model.move(1); return .handled }
        .onKeyPress(.upArrow) { model.move(-1); return .handled }
        .onKeyPress(.return) { toggle(model.focused); return .handled }
        .onKeyPress(.delete) { if let l = model.row(model.focused) { app.stop(l) }; return .handled }
        .onKeyPress(.escape) {
            if model.prompt != nil { model.prompt = nil } else if searchFocused { searchFocused = false } else { app.popover.performClose(nil) }
            return .handled
        }
        .onKeyPress(characters: ["/"]) { _ in
            guard !searchFocused else { return .ignored }
            searchFocused = true
            return .handled
        }
    }

    func toggle(_ key: String?) {
        guard let key else { return }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.15)) { model.expanded = model.expanded == key ? nil : key }
    }

    /// Hidden buttons that own the keyboard shortcuts (⌘F, ⌘1–⌘7, ⌘K, ⌘,).
    var shortcuts: some View {
        ZStack {
            Button("") { searchFocused = true }.keyboardShortcut("f", modifiers: .command)
            ForEach(PanelFilter.allCases, id: \.rawValue) { f in
                Button("") { model.filter = f }.keyboardShortcut(KeyEquivalent(Character(String(f.rawValue + 1))), modifiers: .command)
            }
            Button("") { app.killByPort() }.keyboardShortcut("k", modifiers: .command)
            Button("") { app.openSettings() }.keyboardShortcut(",", modifiers: .command)
        }
        .opacity(0)
        .accessibilityHidden(true)
    }

    var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                    TextField(L("Search ports, processes, projects…"), text: $model.search)
                        .textFieldStyle(.plain)
                        .focused($searchFocused)
                        .accessibilityLabel(L("Search"))
                    if !model.search.isEmpty {
                        Button { model.search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                            .buttonStyle(.plain).accessibilityLabel(L("Clear search"))
                    }
                }
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.quaternary.opacity(0.6)))
                Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                    .buttonStyle(.borderless).help(L("Quit Ports") + " ⌘Q").accessibilityLabel(L("Quit Ports"))
                    .keyboardShortcut("q", modifiers: .command)
                Menu {
                    Picker(L("Sort by"), selection: $model.sort) {
                        ForEach(PanelSort.allCases, id: \.self) { Text(L($0.title)).tag($0) }
                    }
                    Divider()
                    Toggle(L("Show Hidden") + " (\(model.hiddenCount))", isOn: $model.showHidden)
                } label: { Image(systemName: "line.3.horizontal.decrease.circle") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .help(L("Sort and view options")).accessibilityLabel(L("Sort and view options"))
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 3) {
                    ForEach(PanelFilter.allCases, id: \.rawValue) { f in
                        let on = model.filter == f
                        Button { model.filter = f } label: {
                            Text(L(f.title)).font(.subheadline.weight(on ? .semibold : .regular))
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .foregroundStyle(on ? Color.white : Color.primary)
                                .background(Capsule().fill(on ? Color.accentColor : Color.secondary.opacity(0.14)))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(L(f.title) + (on ? ", " + L("selected") : ""))
                        .help("⌘\(f.rawValue + 1)")
                        .accessibilityIdentifier("filter-\(f.rawValue)")
                    }
                }
            }
        }
        .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 8)
    }

    var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // Lazy: only visible rows are built (SwiftUI views are the panel's biggest memory cost).
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    if !model.analysis.issues.isEmpty {
                        Section(header: SectionHeader(title: L("Health"), count: model.analysis.issues.count)) {
                            ForEach(model.analysis.issues, id: \.id) { IssueRow(issue: $0, app: app, model: model) }
                        }
                    }
                    let sections = model.sections
                    if sections.isEmpty {
                        Text(model.filter == .developer && model.search.isEmpty ? L("No dev servers running") : L("Nothing matches"))
                            .foregroundStyle(.secondary).padding(20).frame(maxWidth: .infinity)
                    }
                    ForEach(sections, id: \.id) { s in
                        Section(header: SectionHeader(title: L(s.title), count: s.rows.count)) {
                            ForEach(s.rows, id: \.self.listenerID) { l in
                                RowView(l: l, model: model, app: app, toggle: { toggle(listenerKey(l)) }).id(listenerKey(l))
                            }
                        }
                    }
                    if !model.analysis.leftovers.isEmpty && (model.filter == .developer || model.filter == .all || model.filter == .leftovers) {
                        Section(header: SectionHeader(title: L("Leftovers"), count: model.analysis.leftovers.count)) {
                            ForEach(model.analysis.leftovers, id: \.process.pid) { LeftoverRow(left: $0, app: app) }
                        }
                    }
                }
            }
            .onChange(of: model.focused) { _, k in if let k { proxy.scrollTo(k) } }
        }
    }

    var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                if !model.selection.isEmpty {
                    Button(L("Stop") + " \(model.selection.count)…") {
                        app.stopSelected(model.listeners.filter { model.selection.contains(listenerKey($0)) })
                    }.buttonStyle(.borderedProminent).tint(.red).controlSize(.small)
                }
                FooterButton(title: L("Check Port…"), symbol: "magnifyingglass") { app.checkPortPrompt() }
                FooterButton(title: L("Free Port…"), symbol: "number") { app.findFreePort() }
                FooterButton(title: L("Clean Up…"), symbol: "sparkles") { app.cleanUp() }.disabled(app.cleanupCandidates().isEmpty)
                Spacer()
                IconButton(symbol: "clock.arrow.circlepath", help: L("History")) { model.showHistory.toggle() }
                IconButton(symbol: "text.bubble", help: L("Copy Setup Prompt for AI")) { copyToPasteboard(aiSetupPrompt(model.listeners)) }
                IconButton(symbol: "gearshape", help: L("Settings…") + " ⌘,") { app.openSettings() }
            }
            HStack(spacing: 4) {
                if let c = model.containers {
                    let names = c.answered.isEmpty ? (c.viaCLI ? "docker CLI" : L("not answering")) : c.answered.map(\.name).joined(separator: ", ")
                    Image(systemName: "shippingbox").imageScale(.small)
                    Text(names + " · " + String(c.containers.filter { $0.state == "running" }.count) + " " + L("running"))
                }
                Spacer()
                if let tag = model.updateTag { Text(L("Update available") + ": \(tag)").foregroundStyle(.blue) }
                if let t = model.lastScan { Text(L("Updated") + " " + t.formatted(date: .omitted, time: .shortened)) }
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
    }
}

struct FooterButton: View {
    let title: String
    let symbol: String
    let action: () -> Void
    var body: some View {
        Button(action: action) { Label(title, systemImage: symbol).font(.callout).lineLimit(1).fixedSize() }
            .buttonStyle(.borderless)
    }
}

struct IconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    var body: some View {
        Button(action: action) { Image(systemName: symbol).font(.body) }
            .buttonStyle(.borderless).help(help).accessibilityLabel(help)
    }
}

extension Listener { var listenerID: String { listenerKey(self) } }

struct SectionHeader: View {
    let title: String
    let count: Int
    var body: some View {
        HStack(spacing: 6) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            Text(String(count)).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                .padding(.horizontal, 5).padding(.vertical, 1).background(Capsule().fill(.quaternary))
            Spacer()
        }
        .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 4)
        .background(.regularMaterial)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier("section-\(title)")
    }
}

struct RowView: View {
    let l: Listener
    @ObservedObject var model: PanelModel
    let app: AppDelegate
    let toggle: () -> Void

    var key: String { listenerKey(l) }
    var hover: Bool { model.hoverKey == key }
    var expanded: Bool { model.expanded == key }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(nsImage: app.icon(for: l) ?? NSImage()).resizable().frame(width: 18, height: 18).accessibilityHidden(true)
                // verbatim: a port is an identifier, never "8,787".
                Text(verbatim: String(l.port)).font(.system(.body, design: .rounded).weight(.semibold).monospacedDigit())
                    .frame(width: 52, alignment: .leading)
                VStack(alignment: .leading, spacing: 2) {
                    Text(l.label).font(.body).lineLimit(1).truncationMode(.middle)
                    let sub = model.subtitle(l)
                    if !sub.isEmpty { Text(sub).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                }
                Spacer(minLength: 4)
                // Badges keep a reserved column so rows don't jump when one appears.
                HStack(spacing: 3) {
                    ForEach(model.badges(l)) { b in
                        Text(b.text).font(.system(size: 9, weight: .bold, design: .rounded)).padding(.horizontal, 5).padding(.vertical, 2)
                            .foregroundStyle(b.color).background(Capsule().fill(b.color.opacity(0.16)))
                    }
                }
                .frame(minWidth: 110, alignment: .trailing)
                if hover && l.uid == getuid() && !KnownPorts.restartsAutomatically(l) {
                    Button { app.stop(l) } label: { Image(systemName: "stop.circle.fill").font(.title3) }
                        .buttonStyle(.borderless).foregroundStyle(.red).help(L("Stop…")).accessibilityLabel(L("Stop") + " \(l.label)")
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(
                model.selection.contains(key) ? Color.accentColor.opacity(0.22)
                    : (model.focused == key || hover || expanded) ? Color.primary.opacity(0.07) : .clear))
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
            .onHover { inside in if inside { model.hoverKey = key } else if model.hoverKey == key { model.hoverKey = nil } }
            .onTapGesture {
                let flags = NSEvent.modifierFlags
                if flags.contains(.command) {
                    if model.selection.contains(key) { model.selection.remove(key) } else { model.selection.insert(key) }
                } else if flags.contains(.option) {
                    app.prompter.confirm(L("Hide all rows from") + " \(appName(l.exe))?", L("Hidden rows come back with Show Hidden."),
                                         button: L("Hide"), destructive: false) { app.hideGroup(l) }
                } else {
                    model.focused = key
                    toggle()
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(model.accessibilityLabel(l))
            .accessibilityIdentifier("row-\(l.port)-\(l.pid)")
            .accessibilityHint(L("Shows details and actions"))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(named: L("Stop")) { app.stop(l) }
            if expanded { DetailView(l: l, model: model) }
        }
    }
}

struct DetailView: View {
    let l: Listener
    @ObservedObject var model: PanelModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(model.info(l)) { line in
                Label {
                    Text(line.text).font(.caption).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                } icon: { Image(systemName: line.symbol ?? "circle.fill").font(.caption).opacity(line.symbol == nil ? 0 : 1) }
            }
            ActionGrid(actions: model.actions(l))
            DisclosureGroup(L("Customize"), isExpanded: $model.customizeOpen) { ActionGrid(actions: model.customizeActions(l)) }
                .font(.caption)
        }
        .padding(.leading, 46).padding(.trailing, 14).padding(.top, 2).padding(.bottom, 10)
    }
}

struct ActionGrid: View {
    let actions: [RowAction]
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 4)], alignment: .leading, spacing: 4) {
            ForEach(actions) { a in
                Button(action: a.run) {
                    Label(a.title, systemImage: a.checked == true ? "checkmark" : a.symbol).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.bordered).controlSize(.small)
                .tint(a.destructive ? .red : nil)
                .accessibilityLabel(a.title + (a.checked == true ? ", " + L("on") : ""))
            }
        }
    }
}

struct IssueRow: View {
    let issue: Issue
    let app: AppDelegate
    @ObservedObject var model: PanelModel
    var open: Bool { model.openIssues.contains(issue.id) }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button { if open { model.openIssues.remove(issue.id) } else { model.openIssues.insert(issue.id) } } label: {
                Label(issue.title, systemImage: ["info.circle", "exclamationmark.triangle", "exclamationmark.octagon"][issue.severity.rawValue])
                    .foregroundStyle(issue.severity == .critical ? .red : issue.severity == .warning ? .orange : .secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.buttonStyle(.plain)
            if open {
                Text(issue.explanation).font(.caption).fixedSize(horizontal: false, vertical: true)
                if let title = issue.fixTitle, let fix = issue.fix { Button(title) { app.apply(fix) }.controlSize(.small) }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(
            (issue.severity == .critical ? Color.red : issue.severity == .warning ? Color.orange : Color.secondary).opacity(0.10)))
        .padding(.horizontal, 6).padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(issue.severity.title + ": " + issue.title)
    }
}

struct LeftoverRow: View {
    let left: Leftover
    let app: AppDelegate
    var body: some View {
        HStack {
            Image(systemName: "leaf").accessibilityHidden(true)
            VStack(alignment: .leading) {
                Text("\(left.tool)\(left.process.project.map { " · " + $0.display } ?? "")")
                Text(left.verdict.evidence.first ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            Text(verbatim: "PID " + String(left.process.pid)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            Button(L("Stop…")) { app.stop(left.process) }.controlSize(.small)
        }
        .padding(.horizontal, 14).padding(.vertical, 6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L("Leftover") + " \(left.tool), PID \(left.process.pid), ORPHAN")
    }
}

struct PromptView: View {
    let prompt: InlinePrompt
    @ObservedObject var model: PanelModel
    let dismiss: () -> Void
    var text: String { model.promptText }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(prompt.title).font(.headline)
            if !prompt.message.isEmpty {
                ScrollView { Text(prompt.message).font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(maxHeight: 200)
            }
            if let img = prompt.image { Image(nsImage: img).interpolation(.none).resizable().frame(width: 200, height: 200).accessibilityLabel(img.accessibilityDescription ?? "") }
            if let f = prompt.field {
                TextField(f.placeholder, text: $model.promptText).textFieldStyle(.roundedBorder).onAppear { model.promptText = f.initial }
                    .onSubmit { if let b = prompt.buttons.first(where: { $0.role != .cancel }) { dismiss(); b.action(text) } }
            }
            HStack {
                Spacer()
                ForEach(Array(prompt.buttons.enumerated()), id: \.offset) { _, b in
                    Button(b.title) { dismiss(); b.action(text) }
                        .tint(b.role == .destructive ? .red : nil)
                        .keyboardShortcut(b.role == .cancel ? .cancelAction : nil)
                }
            }
            .controlSize(.small)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.4)))
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }
}

struct HistoryView: View {
    @ObservedObject var model: PanelModel
    let close: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(L("History")).font(.headline)
                TextField(L("Filter"), text: $model.historyFilter).textFieldStyle(.roundedBorder)
                Button(L("Done"), action: close).keyboardShortcut(.cancelAction)
            }
            List(Array(model.historyEvents.reversed().prefix(500).enumerated()), id: \.offset) { _, e in Text(e.line).font(.caption.monospaced()) }
                .accessibilityLabel(L("History events"))
        }
        .padding(8)
        .onAppear { model.loadHistory() }
    }
}
