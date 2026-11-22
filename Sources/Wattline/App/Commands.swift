import AppKit

/// Actions for Shortcuts, Terminal and scripts: `wattline://…` URLs, and command-line flags that print a result.
enum Commands {
    /// `Wattline --time-left` and friends: run, print, exit, without starting the menu bar app.
    static func runCLIIfRequested() {
        let args = CommandLine.arguments
        let reader = BatteryReader()
        func timeLeft(_ b: BatteryState) -> Double {
            if let m = b.minutesToEmpty { return Double(m) }
            guard b.systemPower > 0.5 else { return 0 }
            return Double(b.remainingCapacity) * b.voltage / 1000 / b.systemPower * 60
        }
        if args.contains("--time-left") {
            let b = reader.read()
            if !b.hasBattery { print("No battery") }
            else if b.externalConnected { print(b.minutesToFull.map { "Charging, \(Fmt.duration(minutes: Double($0))) to full" } ?? "Plugged in, \(b.percent)%") }
            else { print(Fmt.duration(minutes: timeLeft(b))) }
            exit(0)
        }
        if args.contains("--status") {
            let b = reader.read()
            let d: [String: Any] = ["percent": b.percent, "charging": b.isCharging, "pluggedIn": b.externalConnected,
                                    "minutesLeft": b.onBattery ? Int(timeLeft(b)) : NSNull(), "minutesToFull": b.minutesToFull ?? NSNull(),
                                    "watts": NSDecimalNumber(string: String(format: "%.1f", b.systemPower)),
                                    "temperature": b.temperature.map { NSDecimalNumber(string: String(format: "%.1f", $0)) } ?? NSNull(),
                                    "health": b.maxCapacityPercent, "cycles": b.cycleCount, "lowPowerMode": b.lowPowerMode,
                                    "chargeLimit": ChargeLimit.shared.current() ?? NSNull()]
            if let data = try? JSONSerialization.data(withJSONObject: d, options: [.prettyPrinted, .sortedKeys]) { print(String(decoding: data, as: UTF8.self)) }
            exit(0)
        }
        if let i = args.firstIndex(of: "--charge-limit"), i + 1 < args.count {
            let v = args[i + 1].lowercased() == "none" ? 100 : (Int(args[i + 1].replacingOccurrences(of: "%", with: "")) ?? -1)
            let ok = ChargeLimit.shared.set(v)
            print(ok ? "Charge limit: \(v == 100 ? "none" : "\(v)%")" : "Couldn't set it. Choices: \(ChargeLimit.shared.levels().map { $0 == 100 ? "none" : "\($0)" }.joined(separator: ", "))")
            exit(ok ? 0 : 1)
        }
        if args.contains("--quit-hungriest") {
            print(quitHungriest() ?? "Nothing to quit")
            exit(0)
        }
    }

    /// Measures for two seconds and quits the app or command using the most energy. Never macOS's own work or hidden apps.
    @discardableResult
    static func quitHungriest() -> String? {
        let e = EnergyMonitor()
        var b = e.baseline()
        Thread.sleep(forTimeInterval: 2)
        let r = e.measure(since: &b, systemWatts: 0)
        let hidden = Set(UserDefaults(suiteName: "local.wattline.Wattline")?.stringArray(forKey: "hiddenApps") ?? Prefs.shared.hiddenApps)
        guard let c = r.consumers.first(where: { ($0.identity.kind == .app || $0.identity.kind == .command) && $0.identity.canQuit
                                                    && !hidden.contains($0.id) && $0.watts >= 0.2 && !$0.name.hasPrefix("Wattline")
                                                    && $0.identity.appPID != getpid() }) else { return nil }
        if c.identity.kind == .app, let pid = c.identity.appPID, let app = NSRunningApplication(processIdentifier: pid) { app.terminate() }
        else if let pid = c.identity.appPID { let g = getpgid(pid); if g > 1 { killpg(g, SIGINT) } else { kill(pid, SIGINT) } }
        return "Quit \(c.name) (\(Fmt.watts(c.watts)))"
    }

    /// `wattline://charge-limit/80`, `wattline://low-power/toggle`, …
    static func handle(_ url: URL, model: AppModel, openPanel: () -> Void) {
        guard url.scheme == "wattline" else { return }
        let parts = [url.host ?? ""] + url.pathComponents.filter { $0 != "/" }
        let arg = parts.count > 1 ? parts[1].lowercased() : ""
        switch parts[0].lowercased() {
        case "open": openPanel()
        case "charge-limit":
            let v = arg == "none" || arg == "100" ? 100 : (Int(arg) ?? 0)
            if model.chargeLevels.contains(v) || ChargeLimit.shared.levels().contains(v) { model.setChargeLimit(v) } else { NSSound.beep() }
        case "full-once": model.chargeToFullOnce()
        case "low-power":
            let on = arg == "on" ? true : (arg == "off" ? false : !model.battery.lowPowerMode)
            model.setLowPower(on)
        case "quit-hungriest":
            DispatchQueue.global(qos: .userInitiated).async {
                let msg = quitHungriest()
                DispatchQueue.main.async { Notifier.shared.post(id: "shortcut", title: msg ?? "Nothing to quit", body: msg == nil ? "No app is using much energy right now." : "From your shortcut.") }
            }
        case "dim":
            model.dimScreen(by: Double(Int(arg) ?? 20) / 100)
        default: NSSound.beep()
        }
    }
}
