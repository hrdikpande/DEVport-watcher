import AppKit
import Darwin
import PortsCore
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let popover = NSPopover()
    let scanQueue = DispatchQueue(label: "ports.scan", qos: .utility)
    let model = PanelModel()
    lazy var settingsUI = SettingsUIState()
    let prompter = Prompter()
    let stops = StopRegistry()
    let overrides = OverrideStore()
    let settingsStore = SettingsStore()
    let history = HistoryStore()
    let notifier = Notifier()
    let hotKey = HotKey()
    let watchedOwners = WatchedOwners()
    var icons: [String: NSImage] = [:]
    var pausedByUs = Set<String>()          // processKey of processes Ports paused
    var containersStoppedByUs = Set<String>()
    var cadence = CadenceInput()
    var timer: Timer?
    var scanning = false
    var pendingFullRefresh = false
    var dockerReachable: Bool?
    var settingsWindow: NSWindow?
    var outsideClicks: Any?
    var closedByOutsideClick = Date.distantPast
    var lastStatus: StatusSummary?
    var lastHistoryPrune = Date.distantPast
    let localhostIPv6First = localhostPrefersIPv6()

    var settings: PortsCore.Settings { settingsStore.settings }

    func applicationDidFinishLaunching(_ note: Notification) {
        if let button = status.button {
            button.image = statusImage(dot: false)
            button.imagePosition = .imageLeading
            button.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            button.target = self
            button.action = #selector(statusClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.setAccessibilityLabel(Brand.displayName)
        }
        // Closed by a click anywhere outside (global monitor) or Esc; `.transient` also closed it whenever macOS
        // declined to activate an accessory app, which made the panel flicker shut.
        popover.behavior = .applicationDefined
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        popover.delegate = self
        popover.contentSize = NSSize(width: 460, height: 620)
        model.app = self
        prompter.showInline = { [weak self] p in
            guard let self, self.popover.isShown else { return false }
            self.model.prompt = p
            return true
        }
        notifier.onAction = { [weak self] action, key in self?.notificationAction(action, key: key) }
        notifier.setUp()
        registerHotKey()
        observeSystem()
        refresh(full: true)
        reschedule()
    }

    // MARK: Status item

    func statusImage(dot: Bool) -> NSImage? {
        guard let base = NSImage(systemSymbolName: "point.3.connected.trianglepath.dotted", accessibilityDescription: Brand.displayName)
        else { return nil }
        guard dot else { base.isTemplate = true; return base }
        // A small red dot when Doctor has issues or a confirmed orphan exists (the rest stays a template).
        let size = NSSize(width: 18, height: 16)
        let img = NSImage(size: size, flipped: false) { rect in
            base.isTemplate = true
            NSColor.labelColor.set()
            base.draw(in: NSRect(x: 0, y: 1, width: 15, height: 14), from: .zero, operation: .sourceOver, fraction: 1)
            NSColor.systemRed.setFill()
            NSBezierPath(ovalIn: NSRect(x: rect.maxX - 6, y: rect.maxY - 6, width: 6, height: 6)).fill()
            return true
        }
        img.isTemplate = false
        img.accessibilityDescription = Brand.displayName + ", " + L("needs attention")
        return img
    }

    func renderStatus() {
        let s = statusSummary(model.listeners, analysis: model.analysis, settings: settings)
        guard s != lastStatus else { return }          // no redraw (and no wake-up of the menu bar) when nothing changed
        lastStatus = s
        status.button?.title = s.title
        status.button?.image = statusImage(dot: s.dot)
        status.button?.toolTip = s.tooltip
        status.button?.setAccessibilityValue(s.tooltip)
    }

    @objc func statusClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp || NSApp.currentEvent?.modifierFlags.contains(.control) == true {
            showContextMenu()
        } else {
            togglePanel()
        }
    }

    /// Right-click: a small classic menu.
    func showContextMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: L("Refresh"), action: #selector(menuRefresh), keyEquivalent: "r").target = self
        let pause = menu.addItem(withTitle: cadence.userPaused ? L("Resume Scanning") : L("Pause Scanning"),
                                 action: #selector(menuPause), keyEquivalent: "")
        pause.target = self
        menu.addItem(withTitle: L("Settings…"), action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: L("Quit") + " " + Brand.displayName, action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        status.menu = menu
        status.button?.performClick(nil)
        status.menu = nil
    }
    @objc func menuRefresh() { refresh(full: true) }
    @objc func menuPause() { cadence.userPaused.toggle(); reschedule() }

    func togglePanel() {
        // A click on the status item can also reach the outside-click monitor: don't reopen what it just closed.
        if !popover.isShown && Date().timeIntervalSince(closedByOutsideClick) < 0.4 { return }
        if popover.isShown { popover.performClose(nil); return }
        guard let button = status.button else { return }
        NSApp.activate()
        // The SwiftUI panel exists only while shown (built on open, released on close: lower idle memory).
        popover.contentViewController = NSHostingController(rootView: PanelView(model: model, app: self))
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    func popoverDidShow(_ notification: Notification) {
        outsideClicks = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated {
                // Only a close that really happened may block the status item's own click from reopening it.
                guard let self, self.popover.isShown else { return }
                self.closedByOutsideClick = Date()
                self.popover.performClose(nil)
            }
        }
    }

    func popoverWillShow(_ notification: Notification) {
        model.panelWillOpen()
        cadence.panelOpen = true
        refresh(full: true)
        reschedule()
    }

    func popoverDidClose(_ notification: Notification) {
        if let m = outsideClicks { NSEvent.removeMonitor(m); outsideClicks = nil }
        popover.contentViewController = nil
        icons.removeAll()
        // Give the panel's freed memory back to the system once SwiftUI has torn it down.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { _ = malloc_zone_pressure_relief(nil, 0) }
        model.panelDidClose()
        cadence.panelOpen = false
        reschedule()
    }

    // MARK: Scanning

    /// One scan on a utility-QoS queue: sockets always; while the panel is open also CPU sampling, web/DB
    /// probes, tunnel APIs and the orphan analysis; the UI updates only when something changed.
    func refresh(full: Bool) {
        guard !scanning else { if full { pendingFullRefresh = true }; return }
        scanning = true
        let open = popover.isShown
        let settings = self.settings
        let ipv6First = localhostIPv6First
        let previous = model.listeners
        let previousAnalysis = model.analysis
        let stoppedByUs = containersStoppedByUs
        scanQueue.async {
            // One socket scan (CPU sampling only while open). Engines: every open scan; while closed at most once a
            // minute, or at once when the runtime's proxy listeners change.
            // Closed: processes that listened on nothing are re-checked every 30 s, not every scan (energy).
            var result = scan(docker: [:], sampleCPU: open, quietRecheck: open || full ? 0 : 30)
            let snap = ContainerDirectory.shared.current(listeners: result, maxAge: full || open ? 0 : 60)
            result = applyContainers(result, snap)
            result = DatabaseProbeCache.shared.apply(WebProbeCache.shared.apply(result, probe: open), probe: open)
            result = TunnelProbeCache.shared.apply(result, probe: open, reverse: reverseForwards(sshArgvs()))
            result = applyCustomMatchers(applyOverrides(result, self.overrides), settings.customMatchers)
            var input = DoctorInput()
            input.dockerReachable = snap.map(\.reachable)
            input.localhostIPv6First = ipv6First
            input.idleThreshold = settings.idleThresholdMinutes * 60
            // Verdicts need the launchd job list, read only while the panel is open: a closed scan keeps the last one.
            let a: Analysis? = open ? analyze(result, starred: self.overrides.starred, includeLeftovers: true, doctor: input) : nil
            let events = previous.isEmpty ? [] : diffEvents(previous: previous, current: result)
            let notes = previous.isEmpty ? [] : notifications(previous: previous, current: result, previousAnalysis: previousAnalysis,
                                                               analysis: a ?? previousAnalysis, settings: settings,
                                                               owners: self.watchedOwners, stoppedByUs: stoppedByUs)
            self.history.append(events)
            RunLoop.main.perform(inModes: [.common]) {
                MainActor.assumeIsolated {
                    self.scanning = false
                    defer { if self.pendingFullRefresh { self.pendingFullRefresh = false; self.refresh(full: true) } }
                    self.dockerReachable = snap?.reachable
                    self.model.update(listeners: result, analysis: a, containers: snap)
                    self.renderStatus()
                    for n in notes { self.notifier.post(n) }
                    self.pruneHistoryDaily()
                }
            }
        }
    }

    func pruneHistoryDaily() {
        guard Date().timeIntervalSince(lastHistoryPrune) > 86_400 else { return }
        lastHistoryPrune = Date()
        let days = settings.historyRetentionDays
        scanQueue.async { self.history.prune(retentionDays: days) }
    }

    /// Re-arm the scan timer for the current state; tolerance ≥ 50 % so macOS can coalesce wake-ups.
    func reschedule() {
        timer?.invalidate()
        timer = nil
        cadence.onBattery = Power.onBattery()
        cadence.lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        guard let interval = scanInterval(cadence, settings: settings) else { return }
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let battery = Power.onBattery(), low = ProcessInfo.processInfo.isLowPowerModeEnabled
                if battery != self.cadence.onBattery || low != self.cadence.lowPower { self.reschedule() }
                self.refresh(full: false)
            }
        }
        t.tolerance = timerTolerance(interval)
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Pause while asleep or locked; a full rescan on wake/unlock.
    func observeSystem() {
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.cadence.asleep = true; self?.reschedule() }
        }
        ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.cadence.asleep = false; self?.refresh(full: true); self?.reschedule() }
        }
        let dn = DistributedNotificationCenter.default()
        dn.addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.cadence.screenLocked = true; self?.reschedule() }
        }
        dn.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.cadence.screenLocked = false; self?.refresh(full: true); self?.reschedule() }
        }
        NotificationCenter.default.addObserver(forName: Notification.Name.NSProcessInfoPowerStateDidChange, object: nil,
                                               queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.reschedule() } }
    }

    /// Run `work` off the main thread, then hand a fresh full scan back to the UI.
    func afterWork(_ work: @escaping () -> Void, then done: @escaping ([Listener]) -> Void) {
        let settings = self.settings
        scanQueue.async {
            work()
            var fresh = scanWithContainers()
            fresh = TunnelProbeCache.shared.apply(DatabaseProbeCache.shared.apply(WebProbeCache.shared.apply(fresh, probe: false), probe: false),
                                                  probe: false, reverse: reverseForwards(sshArgvs()))
            fresh = applyCustomMatchers(applyOverrides(fresh, self.overrides), settings.customMatchers)
            let a = analyze(fresh, starred: self.overrides.starred, includeLeftovers: true)
            RunLoop.main.perform(inModes: [.common]) {
                MainActor.assumeIsolated {
                    self.model.update(listeners: fresh, analysis: a, containers: ContainerDirectory.shared.last)
                    self.renderStatus()
                    done(fresh)
                }
            }
        }
    }

    // MARK: Hot key, notifications, settings

    func registerHotKey() {
        hotKey.unregister()
        if let k = settings.hotKey { hotKey.register(k) { [weak self] in self?.togglePanel() } }
    }

    func notificationAction(_ action: Notifier.Action, key: String) {
        let l = model.listeners.first { listenerKey($0) == key }
        switch action {
        case .open:
            if !popover.isShown { togglePanel() }
            if let l { model.expanded = listenerKey(l) }
        case .copy:
            if let l { copyToPasteboard(hostPort(l)) }
        case .stop:
            if let l { stop(l) }
        }
    }

    @objc func openSettings() {
        popover.performClose(nil)
        if settingsWindow == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(app: self, ui: settingsUI)))
            w.title = Brand.displayName + " " + L("Settings")
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            w.titlebarAppearsTransparent = true
            w.toolbarStyle = .unified
            w.isReleasedWhenClosed = false
            w.setFrameAutosaveName("PortsSettings")
            settingsWindow = w
        }
        NSApp.activate()
        settingsWindow?.center()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    func updateSettings(_ change: (inout PortsCore.Settings) -> Void) {
        do { try settingsStore.update(change) } catch { prompter.tell(L("Couldn't save the setting"), "\(error)") }
        registerHotKey()
        reschedule()
        model.objectWillChange.send()
        refresh(full: false)
    }
}

func copyToPasteboard(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}
