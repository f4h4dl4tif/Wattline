import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var panel: PanelWindow?
    private var settings: SettingsWindowController?
    private var tour: NSWindow?
    private var card: AccessoryCardController?
    private let hotKey = HotKey()
    private var animTimer: Timer?
    private var phase = 0.0
    private var currentMotion: StatusIcon.Motion = .none
    private var clickMonitor: Any?
    private let model = AppModel.shared
    private let prefs = Prefs.shared

    func applicationWillFinishLaunching(_ n: Notification) {
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleURL(_:reply:)),
                                                     forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    }

    @objc func handleURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let s = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue, let url = URL(string: s) else { return }
        Commands.handle(url, model: model) { openPanel() }
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.autosaveName = "WattlineBattery"
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePanel)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.imagePosition = .imageTrailing
            button.setAccessibilityTitle("Wattline")
        }
        Notifier.shared.setUp()
        Notifier.shared.onOpenPanel = { [weak self] in self?.openPanel() }
        model.onBatteryChange = { [weak self] in self?.updateStatusItem() }
        model.onAccessoryConnected = { [weak self] a in self?.showCard(a) }
        model.start()
        if Snapshot.runIfRequested(model: model) { return }
        DragGhost.shared.panelFrame = { [weak self] in self?.panel?.frame ?? .zero }

        HotKey.action = { [weak self] in self?.togglePanel() }
        if prefs.hotkeyEnabled { hotKey.register() }
        observePrefs()
        updateStatusItem()

        if !prefs.tourDone { DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self.showTour() } }
        if let i = CommandLine.arguments.firstIndex(of: "--open-panel") {
            // For testing: open the panel, and optionally close it again after a few seconds.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.openPanel() }
            if i + 1 < CommandLine.arguments.count, let secs = Double(CommandLine.arguments[i + 1]) {
                DispatchQueue.main.asyncAfter(deadline: .now() + secs) { self.closePanel() }
            }
            if let c = CommandLine.arguments.firstIndex(of: "--capture"), c + 1 < CommandLine.arguments.count {
                let path = CommandLine.arguments[c + 1]
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                    guard let v = self.panel?.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
                    v.cacheDisplay(in: v.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                }
            }
        }
    }

    /// Re-render the icon whenever a setting it depends on changes.
    private func observePrefs() {
        withObservationTracking {
            _ = (prefs.iconStyle, prefs.besideIcon, prefs.percentInside, prefs.colorfulStates,
                 prefs.chargingMotion, prefs.lastFewMotion, prefs.holdingMotion, prefs.hotkeyEnabled, model.chargeLimit)
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.prefs.hotkeyEnabled ? self.hotKey.register() : self.hotKey.unregister()
                self.updateStatusItem()
                self.observePrefs()
            }
        }
    }

    // MARK: Menu bar icon

    func updateStatusItem() {
        let b = model.battery
        let motion = StatusIcon.motion(for: b, limit: model.chargeLimit, prefs: prefs)
        if motion != currentMotion {
            currentMotion = motion
            animTimer?.invalidate(); animTimer = nil
            if motion != .none {
                let fps = StatusIcon.fps(motion)
                let t = Timer(timeInterval: 1 / fps, repeats: true) { [weak self] _ in
                    guard let self else { return }
                    let period: Double = [.breathe, .water, .calm].contains(self.currentMotion) ? 4 : ([.beat].contains(self.currentMotion) ? 1.2 : 2)
                    self.phase = (self.phase + 1 / fps / period).truncatingRemainder(dividingBy: 1)
                    self.renderIcon()
                }
                t.tolerance = 0.02
                RunLoop.main.add(t, forMode: .common)
                animTimer = t
            }
        }
        renderIcon()
        guard let button = statusItem.button else { return }
        let title = StatusIcon.title(b, prefs: prefs, timeLeft: model.timeLeft)
        button.title = title.isEmpty ? "" : (prefs.iconStyle == .text ? title : title + " ")
        button.font = .menuBarFont(ofSize: 0)
        var tip = b.hasBattery ? "\(b.percent)% · \(b.powerSource)" : "Wattline"
        if b.onBattery, model.timeLeft > 0 { tip += " · \(Fmt.duration(minutes: model.timeLeft)) left" }
        button.toolTip = tip
        button.setAccessibilityLabel(tip)
    }

    private func renderIcon() {
        guard let button = statusItem.button else { return }
        if prefs.iconStyle == .text { button.image = nil; return }
        button.image = StatusIcon.image(model.battery, prefs: prefs, motion: currentMotion, phase: phase)
    }

    // MARK: Panel

    @objc func togglePanel() {
        if panel?.isVisible == true { closePanel() } else { openPanel() }
    }

    func openPanel() {
        if panel == nil {
            panel = PanelWindow(root: PanelView(model: model, openSettings: { [weak self] pane in self?.openSettings(pane) }))
            panel?.onClose = { [weak self] in self?.closePanel() }
        }
        guard let panel else { return }
        model.panelOpen = true
        // Below the icon; if the icon is hidden (a crowded menu bar or the notch), at the top right of the screen.
        var anchor: NSRect
        if let button = statusItem.button, let bw = button.window, bw.isVisible,
           NSScreen.screens.contains(where: { $0.frame.intersects(bw.frame) }) {
            anchor = bw.convertToScreen(button.convert(button.bounds, to: nil))
            button.highlight(true)
        } else {
            let screen = NSScreen.main ?? NSScreen.screens[0]
            anchor = NSRect(x: screen.visibleFrame.maxX - Theme.panelWidth / 2 - 8, y: screen.visibleFrame.maxY, width: 1, height: 1)
        }
        panel.show(below: anchor)
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.closePanel()
        }
    }

    func closePanel() {
        guard let panel, panel.isVisible else { return }
        panel.orderOut(nil)
        statusItem.button?.highlight(false)
        if let m = clickMonitor { NSEvent.removeMonitor(m); clickMonitor = nil }
        model.panelOpen = false
        // Free the view tree while closed: nothing is kept in memory but the model.
        self.panel = nil
    }

    // MARK: Windows

    func openSettings(_ pane: SettingsPane?) {
        closePanel()
        if settings == nil { settings = SettingsWindowController(model: model, showTour: { [weak self] in self?.showTour() }) }
        settings?.show(pane: pane)
    }

    func showTour() {
        if let tour { tour.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 460), styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: WelcomeTour(model: model) { [weak self] in
            self?.prefs.tourDone = true
            self?.tour?.close()
            self?.tour = nil
            self?.openPanel()
        })
        w.center()
        tour = w
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak self] _ in
            self?.prefs.tourDone = true; self?.tour = nil
        }
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func showCard(_ a: Accessory) {
        guard prefs.accessoryCard else { return }
        if card == nil { card = AccessoryCardController() }
        card?.onClick = { [weak self] in self?.openPanel() }
        card?.show(a, anchor: statusItem.button?.window?.frame)
    }

    func showCardPreview() {
        let sample = model.accessories.first(where: { $0.isEarbuds }) ?? Accessory(id: "preview", name: "AirPods Pro", model: "AirPods Pro 3", kind: .airpodsPro,
                                       parts: [.init(label: "Left", level: 82), .init(label: "Right", level: 64), .init(label: "Case", level: 47)])
        if card == nil { card = AccessoryCardController() }
        card?.show(sample, anchor: statusItem.button?.window?.frame)
    }
}

/// A borderless panel that looks like a menu bar extra and closes when you click elsewhere.
final class PanelWindow: NSPanel {
    var onClose: (() -> Void)?
    private let hosting: NSHostingView<AnyView>

    init<V: View>(root: V) {
        hosting = NSHostingView(rootView: AnyView(root))
        super.init(contentRect: NSRect(x: 0, y: 0, width: Theme.panelWidth, height: 400),
                   styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        isMovable = false
        hidesOnDeactivate = false

        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 12
        effect.layer?.cornerCurve = .continuous
        effect.layer?.masksToBounds = true
        effect.layer?.borderWidth = 0.5
        effect.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.documentView = hosting
        scroll.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: effect.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: effect.topAnchor), scroll.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        contentView = effect
        hosting.sizingOptions = [.intrinsicContentSize]
        NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: hosting, queue: .main) { [weak self] _ in
            self?.fitToContent()
        }
        hosting.postsFrameChangedNotifications = true
    }

    override var canBecomeKey: Bool { true }

    private var anchor: NSRect = .zero

    func show(below anchor: NSRect) {
        self.anchor = anchor
        fitToContent()
        alphaValue = 0
        makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in ctx.duration = 0.12; animator().alphaValue = 1 }
    }

    func fitToContent() {
        let size = hosting.fittingSize
        hosting.frame = NSRect(origin: .zero, size: size)
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(anchor.origin) }) ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let h = min(size.height, visible.height - 12)
        var x = anchor.midX - size.width / 2
        x = max(visible.minX + 6, min(x, visible.maxX - size.width - 6))
        let top = min(anchor.minY - 4, visible.maxY)
        setFrame(NSRect(x: x, y: top - h, width: size.width, height: h), display: true)
    }

    override func cancelOperation(_ sender: Any?) { onClose?() }
}

Commands.runCLIIfRequested()
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
