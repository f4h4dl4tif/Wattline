import AppKit
import SwiftUI

/// `Wattline --snapshot <dir>`: renders the panel and settings panes to PNGs, for checking the design.
enum Snapshot {
    static func runIfRequested(model: AppModel) -> Bool {
        let args = CommandLine.arguments
        if args.contains("--dump") {
            let e = EnergyMonitor()
            var b = e.baseline()
            print("baseline pids:", Proc.allPIDs().count)
            if let b = Brightness.level(), let sv = Brightness.savings(dimmingBy: 0.2) {
                print(String(format: "brightness %.0f%%, backlight ≈ %.2f W, dimming 20%% saves %.2f W", b * 100, Brightness.backlightWatts(at: b), sv.watts))
            }
            print("last wake:", WakeReasons.latest().map(WakeReasons.describe) ?? "?", "| type:", WakeReasons.wakeType() ?? "?")
            let f = Wear.forecast(battery: model.battery, history: model.history.capacity)
            print("wear forecast:", f.date.map { "\($0)" } ?? "-", "cycles left:", f.cyclesLeft ?? -1, "|", f.basis)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                let r = e.measure(since: &b, systemWatts: model.battery.systemPower)
                print(String(format: "system %.2f W, unaccounted %.2f W, dt %.2f", r.systemWatts, r.unaccountedWatts, r.interval))
                for c in r.consumers.prefix(15) { print(String(format: "%6.2f W  %@  %@  procs=%d est=%d", c.watts, c.identity.kind.rawValue, c.name, c.processes.count, c.estimated ? 1 : 0)) }
                exit(0)
            }
            return true
        }
        guard let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count else { return false }
        let dir = URL(fileURLWithPath: args[i + 1])
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        model.panelOpen = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.5) {
            render(PanelView(model: model, openSettings: { _ in }).background(Color(nsColor: .windowBackgroundColor)), to: dir.appendingPathComponent("panel.png"))
            let state = SettingsState()
            for (name, pane) in [("warmth", SettingsPane.warmth), ("shortcuts", .shortcuts), ("general", .general), ("charging", .charging), ("notifications", .notifications), ("sleep", .sleep), ("battery", .battery)] {
                state.selection = pane
                let v = SettingsRoot(state: state, model: model, showTour: {}).frame(width: 800, height: 620)
                showWindow(v, to: dir.appendingPathComponent("settings-\(name).png"))
            }
            showWindow(WelcomeTour(model: model, finish: {}), to: dir.appendingPathComponent("tour.png"))
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { exit(0) }
        }
        return true
    }

    @MainActor static func render<V: View>(_ v: V, to url: URL) {
        let r = ImageRenderer(content: v)
        r.scale = 2
        if let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
        }
    }

    /// Real windows render AppKit-backed controls properly; capture via cacheDisplay.
    @MainActor static func showWindow<V: View>(_ v: V, to url: URL) {
        let host = NSHostingView(rootView: v)
        host.frame = NSRect(origin: .zero, size: host.fittingSize.width > 10 ? host.fittingSize : NSSize(width: 800, height: 620))
        let w = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        w.contentView = host
        w.setFrameOrigin(NSPoint(x: -4000, y: -4000))
        w.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
        }
        w.orderOut(nil)
    }
}
