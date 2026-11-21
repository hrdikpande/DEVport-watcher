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
        .frame(width: 460, height: 620)
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
        VStack(spacing: 6) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                TextField(L("Search ports, processes, projects, branches…"), text: $model.search)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .accessibilityLabel(L("Search"))
                Menu {
                    Picker(L("Sort"), selection: $model.sort) {
                        ForEach(PanelSort.allCases, id: \.self) { Text(L($0.title)).tag($0) }
                    }
                    Toggle(L("Show Hidden") + " (\(model.hiddenCount))", isOn: $model.showHidden)
                } label: { Image(systemName: "arrow.up.arrow.down.circle") }
                    .menuStyle(.borderlessButton).fixedSize().accessibilityLabel(L("Sort and view options"))
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(PanelFilter.allCases, id: \.rawValue) { f in
                        Button(L(f.title)) { model.filter = f }
                            .buttonStyle(.bordered)
                            .tint(model.filter == f ? .accentColor : nil)
                            .controlSize(.small)
                            .accessibilityLabel(L(f.title) + (model.filter == f ? ", " + L("selected") : ""))
                            .help("⌘\(f.rawValue + 1)")
                            .accessibilityIdentifier("filter-\(f.rawValue)")
                    }
                }
            }
        }
        .padding(8)
    }

    var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // Not lazy: every row stays in the accessibility tree (VoiceOver, UI tests); row counts are small.
                VStack(alignment: .leading, spacing: 0) {
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
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if !model.selection.isEmpty {
                    Button(L("Stop Selected") + " (\(model.selection.count))…") {
                        app.stopSelected(model.listeners.filter { model.selection.contains(listenerKey($0)) })
                    }.tint(.red)
                }
                Button(L("Check Port…")) { app.checkPortPrompt() }
                Button(L("Find Free Port…")) { app.findFreePort() }
                Button(L("Clean Up…")) { app.cleanUp() }.disabled(app.cleanupCandidates().isEmpty)
                Spacer()
                Button { model.showHistory.toggle() } label: { Image(systemName: "clock.arrow.circlepath") }
                    .help(L("History")).accessibilityLabel(L("History"))
                Button { copyToPasteboard(aiSetupPrompt(model.listeners)) } label: { Image(systemName: "text.bubble") }
                    .help(L("Copy Setup Prompt for AI")).accessibilityLabel(L("Copy Setup Prompt for AI"))
                Button { app.openSettings() } label: { Image(systemName: "gearshape") }
                    .help(L("Settings…") + " ⌘,").accessibilityLabel(L("Settings"))
            }
            .controlSize(.small)
            HStack {
                if let c = model.containers {
                    let names = c.answered.isEmpty ? (c.viaCLI ? "docker CLI" : L("not answering")) : c.answered.map(\.name).joined(separator: ", ")
                    Label(L("Containers") + ": \(names) · \(c.containers.filter { $0.state == "running" }.count) " + L("running"), systemImage: "shippingbox")
                }
                Spacer()
                if let tag = model.updateTag { Text(L("Update available") + ": \(tag)").foregroundStyle(.blue) }
                if let t = model.lastScan { Text(L("Scanned") + " " + t.formatted(date: .omitted, time: .standard)) }
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .padding(8)
    }
}

extension Listener { var listenerID: String { listenerKey(self) } }

struct SectionHeader: View {
    let title: String
    let count: Int
    var body: some View {
        HStack { Text(title).font(.caption.weight(.semibold)); Text("\(count)").font(.caption).foregroundStyle(.secondary); Spacer() }
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(.bar)
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
                Image(nsImage: app.icon(for: l) ?? NSImage()).resizable().frame(width: 16, height: 16).accessibilityHidden(true)
                Text(":\(l.port)").font(.system(.body, design: .monospaced).weight(.semibold)).frame(width: 62, alignment: .leading)
                VStack(alignment: .leading, spacing: 1) {
                    Text(l.label).lineLimit(1).truncationMode(.middle)
                    Text(model.subtitle(l)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                // Badges keep a reserved column so rows don't jump when one appears.
                HStack(spacing: 3) {
                    ForEach(model.badges(l)) { b in
                        Text(b.text).font(.system(size: 9, weight: .bold)).padding(.horizontal, 4).padding(.vertical, 1)
                            .foregroundStyle(b.color).overlay(RoundedRectangle(cornerRadius: 3).stroke(b.color.opacity(0.6)))
                    }
                }
                .frame(minWidth: 110, alignment: .trailing)
                if hover && l.uid == getuid() && !KnownPorts.restartsAutomatically(l) {
                    Button { app.stop(l) } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless).foregroundStyle(.red).help(L("Stop…")).accessibilityLabel(L("Stop") + " \(l.label)")
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(model.selection.contains(key) ? Color.accentColor.opacity(0.18) : model.focused == key ? Color.secondary.opacity(0.12) : .clear)
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
        .padding(.leading, 34).padding(.trailing, 10).padding(.bottom, 8)
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
        .padding(.horizontal, 10).padding(.vertical, 4)
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
            Text("PID \(left.process.pid)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            Button(L("Stop…")) { app.stop(left.process) }.controlSize(.small)
        }
        .padding(.horizontal, 10).padding(.vertical, 4)
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
