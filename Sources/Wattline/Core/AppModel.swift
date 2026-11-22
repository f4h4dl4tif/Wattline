import AppKit
import IOKit.pwr_mgt
import Observation
import WidgetKit

struct Insight: Identifiable, Equatable {
    var id: String
    var title: String
    var detail: String
    var quitKey: String?
    var quitName: String?
    var lowPower = false
}

struct AwakeReason: Identifiable, Equatable {
    var id: String { name }
    var name: String
    var reason: String
    var bundlePath: String?
    var symbol: String
}

/// A slice of the battery, ready to draw.
struct Slice: Identifiable, Equatable {
    var id: String
    var consumer: Consumer?          // nil for Display & System
    var watts: Double
    var minutes: Double              // battery time it costs
    var name: String { consumer?.name ?? "Display & System" }
    var isSystem: Bool { consumer == nil }
}

@Observable
final class AppModel {
    static let shared = AppModel()

    // Live state
    private(set) var battery = BatteryState()
    private(set) var reading = EnergyReading()
    private(set) var smoothed: [String: Double] = [:]
    private(set) var chargeLimit: Int?
    private(set) var chargeLevels: [Int] = []
    private(set) var fullOnce = UserDefaults.standard.integer(forKey: "restoreLimit") > 0
    private(set) var accessories: [Accessory] = []
    private(set) var keptAwake: [AwakeReason] = []
    private(set) var insights: [Insight] = []
    private(set) var historyVersion = 0
    var quitMessage: String?
    var panelOpen = false { didSet { panelOpen ? startLive() : stopLive() } }

    // Engines
    @ObservationIgnored let prefs = Prefs.shared
    @ObservationIgnored let history = HistoryStore()
    @ObservationIgnored private let reader = BatteryReader()
    @ObservationIgnored private let energy = EnergyMonitor()
    @ObservationIgnored let accessoryMonitor = AccessoryMonitor()
    @ObservationIgnored let meetings = MeetingWatch()
    @ObservationIgnored private var liveBaseline = EnergyMonitor.Baseline()
    @ObservationIgnored private var historyBaseline = EnergyMonitor.Baseline()
    @ObservationIgnored private var liveTimer: Timer?
    @ObservationIgnored private var sampleTimer: Timer?
    @ObservationIgnored private var lastSample = Date()
    @ObservationIgnored var onBatteryChange: (() -> Void)?
    @ObservationIgnored var onAccessoryConnected: ((Accessory) -> Void)?

    // Notification state
    @ObservationIgnored private var firedLow: Set<Int> = []
    @ObservationIgnored private var firedCharged = false
    @ObservationIgnored private var firedAccessory: Set<String> = []
    @ObservationIgnored private var hot: [String: Int] = [:]          // consecutive heavy samples
    @ObservationIgnored private var firedRunaway: Set<String> = []
    @ObservationIgnored private var firedInsights: Set<String> = []
    @ObservationIgnored private var firedMeeting: Date?
    @ObservationIgnored private var sleepStart: (Date, Int, Bool)?
    @ObservationIgnored private var unpluggedAt: Date?
    @ObservationIgnored private var unpluggedPct = 0
    @ObservationIgnored private var firedBudgets: Set<String> = []
    @ObservationIgnored private var autoLPMOn = UserDefaults.standard.bool(forKey: "autoLPMOn")
    @ObservationIgnored private var autoLPMTimer: Timer?
    @ObservationIgnored private var warnedNoHelper = false
    @ObservationIgnored private var calendarChargedFor: Date?
    @ObservationIgnored private var sleepWakes: [WakeEvent] = []
    @ObservationIgnored private var powerPort: IONotificationPortRef?
    @ObservationIgnored private var powerNotifier: io_object_t = 0
    @ObservationIgnored fileprivate var rootPort: io_connect_t = 0
    @ObservationIgnored private var lastWidgetWrite = Date.distantPast
    private(set) var lastWakeReason: String?

    private init() {}

    func start() {
        battery = reader.read()
        if !battery.externalConnected { unpluggedAt = Date(); unpluggedPct = battery.percent }
        history.recordLevel(battery)
        reader.onChange = { [weak self] in self?.batteryChanged() }
        reader.startListening()
        historyBaseline = energy.baseline()
        refreshChargeLimit()

        // A sample every five minutes; the Mac may coalesce it with other work.
        let t = Timer(timeInterval: 300, repeats: true) { [weak self] _ in self?.takeSample() }
        t.tolerance = 60
        RunLoop.main.add(t, forMode: .common)
        sampleTimer = t

        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            let b = reader.read()
            sleepStart = (Date(), b.percent, b.externalConnected)
        }
        ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in self?.didWake() }
        NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
            self?.batteryChanged()
        }

        registerSystemPower()
        if battery.onBattery { scheduleAutoLPMTimer() }
        writeWidget()

        accessoryMonitor.onChange = { [weak self] list, fresh in self?.accessoriesChanged(list, fresh: fresh) }
        accessoryMonitor.start()
        Notifier.shared.onQuit = { [weak self] key in self?.quit(key: key, force: false) }
        Notifier.shared.onLowPower = { [weak self] in self?.setLowPower(true) }
    }

    // MARK: Battery events

    private func batteryChanged() {
        let old = battery
        battery = reader.read()
        history.recordLevel(battery)
        if old.externalConnected != battery.externalConnected, old.hasBattery {
            Chime.play(pluggedIn: battery.externalConnected)
            if battery.externalConnected {
                firedLow.removeAll()
                autoLPMTimer?.invalidate(); autoLPMTimer = nil
                if autoLPMOn && prefs.autoLPMOffWhenPlugged && battery.lowPowerMode {
                    LowPower.set(false, prompt: false) { [weak self] _ in self?.battery = self?.reader.read() ?? BatteryState() }
                }
                setAutoLPM(false)
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.checkCalendarCharging() }
            } else {
                unpluggedAt = Date(); unpluggedPct = battery.percent
                firedCharged = false
                if fullOnce { endFullOnce() }
                scheduleAutoLPMTimer()
            }
            refreshChargeLimit()
        }
        checkLevelNotifications()
        checkAutoLPM()
        writeWidget()
        onBatteryChange?()
    }

    private func didWake() {
        battery = reader.read()
        guard let (start, pct, plugged) = sleepStart else { return }
        sleepStart = nil
        var wakes = sleepWakes.filter { $0.date >= start }
        if let raw = WakeReasons.latest() {
            lastWakeReason = WakeReasons.describe(raw)
            wakes.append(WakeEvent(date: Date(), dark: false, reason: WakeReasons.describe(raw)))
        }
        sleepWakes.removeAll()
        let rec = SleepRecord(start: start, end: Date(), startPct: pct, endPct: battery.percent, plugged: plugged || battery.externalConnected, wakes: wakes)
        history.recordSleep(rec)
        historyVersion += 1
        guard prefs.notifySleepDrain, !rec.plugged, rec.hours > 1, rec.used >= 5 else { return }
        let typical = typicalSleepRate
        if rec.perHour > max(2, typical * 3) {
            let times = typical > 0 ? Int((rec.perHour / typical).rounded()) : 0
            let dark = wakes.filter(\.dark)
            let cause = Dictionary(grouping: dark, by: \.reason).max { $0.value.count < $1.value.count }
            let why = cause.map { "It woke \(dark.count) times, mostly for: \($0.key)." } ?? "Something may be waking it: a Bluetooth device, Wake for network access, or an app."
            Notifier.shared.post(id: "sleep", title: "Your Mac used \(rec.used)% while asleep",
                                 body: "In \(Int(rec.hours.rounded())) hours\(times > 1 ? ", about \(times) times faster than usual" : ""). \(why) Open Settings › Sleep for every wake.")
        }
        onBatteryChange?()
    }

    var typicalSleepRate: Double {
        let rates = history.sleeps.filter { !$0.plugged && $0.hours > 1 }.map(\.perHour).sorted()
        return rates.isEmpty ? 0 : rates[rates.count / 2]
    }

    // MARK: Sampling

    private func startLive() {
        battery = reader.read()
        liveBaseline = energy.baseline()
        refreshChargeLimit()
        refreshKeptAwake()
        accessoryMonitor.refresh()
        evaluateInsights()
        // First reading quickly, then every two seconds while the panel is open.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.liveTick() }
        let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.liveTick() }
        t.tolerance = 0.3
        RunLoop.main.add(t, forMode: .common)
        liveTimer = t
    }

    private func stopLive() {
        liveTimer?.invalidate(); liveTimer = nil
        liveBaseline = EnergyMonitor.Baseline()
        smoothed.removeAll(keepingCapacity: false)
        reading = EnergyReading(systemWatts: reading.systemWatts)
        history.save()
    }

    private func liveTick() {
        guard panelOpen else { return }
        battery = reader.read()
        let r = energy.measure(since: &liveBaseline, systemWatts: battery.systemPower)
        guard r.interval > 0 else { return }
        // Smooth so slices don't jump about; new apps come in at their full value.
        var next: [String: Double] = [:]
        for c in r.consumers where c.watts > 0.01 {
            let prev = smoothed[c.id]
            next[c.id] = prev.map { $0 * 0.55 + c.watts * 0.45 } ?? c.watts
        }
        smoothed = next
        reading = r
        if Int(Date().timeIntervalSince1970) % 10 < 2 { refreshKeptAwake() }
    }

    private func takeSample() {
        let minutes = Date().timeIntervalSince(lastSample) / 60
        lastSample = Date()
        battery = reader.read()
        // Apps count toward battery history only on battery; plugged in, just the busiest one is kept, for "why is it warm".
        let reading = energy.measure(since: &historyBaseline, systemWatts: battery.systemPower)
        let r: EnergyReading? = reading.interval > 0 ? reading : nil
        history.recordSample(battery, reading: r, intervalMinutes: minutes)
        historyVersion += 1
        if let r, battery.onBattery { checkRunaway(r) }
        if battery.onBattery { evaluateInsights(latest: r); checkMeeting(); checkBudgets() }
        else { evaluateInsights(latest: r) }
        checkAutoLPM()
        checkCalendarCharging()
        writeWidget(force: true)
        onBatteryChange?()
    }

    // MARK: Derived

    /// Minutes left on battery, macOS's estimate when it has one.
    var timeLeft: Double {
        if let m = battery.minutesToEmpty { return Double(m) }
        guard battery.systemPower > 0.5, battery.remainingCapacity > 0 else { return 0 }
        return Double(battery.remainingCapacity) * battery.voltage / 1000 / battery.systemPower * 60
    }

    var consumers: [Consumer] {
        reading.consumers.map { c in var c = c; c.watts = smoothed[c.id] ?? c.watts; return c }
            .filter { !prefs.isHidden($0) && $0.watts >= 0.1 }
            .sorted { $0.watts > $1.watts }
    }

    var slices: [Slice] {
        let list = consumers
        let accountedNow = reading.consumers.reduce(0) { $0 + (smoothed[$1.id] ?? $1.watts) }
        let system = max(battery.systemPower, reading.systemWatts, accountedNow + 0.8)
        let t = timeLeft
        var out = list.prefix(prefs.sliceCount).map {
            Slice(id: $0.id, consumer: $0, watts: $0.watts, minutes: Cost.minutes(timeLeft: t, app: $0.watts, system: system))
        }
        let rest = max(0, system - accountedNow)
        if !reading.consumers.isEmpty, rest > 0.1 {
            // Without the screen and macOS the Mac couldn't run at all, so its slice is kept in proportion.
            let m = min(Cost.minutes(timeLeft: t, app: rest, system: system), t * 1.5)
            out.append(Slice(id: "system", consumer: nil, watts: rest, minutes: m))
        }
        return out
    }

    var lowPowerSuggestion: Bool {
        prefs.suggestLowPower && battery.onBattery && battery.percent <= 20 && !battery.lowPowerMode
    }

    // MARK: Actions

    func quit(key: String, force: Bool) {
        let c = reading.consumers.first { $0.id == key }
        if c == nil, key.hasPrefix("app:") {
            let bundleID = String(key.dropFirst(4))
            NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).forEach { if force { $0.forceTerminate() } else { $0.terminate() } }
            return
        }
        guard let c else { return }
        quit(c, force: force)
    }

    func quit(_ c: Consumer, force: Bool) {
        let id = c.identity
        guard id.canQuit else { return }
        switch id.kind {
        case .app:
            guard let pid = id.appPID else { return }
            if let app = NSRunningApplication(processIdentifier: pid) {
                if force { app.forceTerminate() } else { app.terminate() }
                if !force { watchQuit(app, name: c.name) }
            } else {
                kill(pid, force ? SIGKILL : SIGTERM)
            }
        case .command:
            // Like Ctrl-C: the signal goes to the command's process group. Force Quit is kill -9.
            guard let pid = id.appPID else { return }
            let pgid = getpgid(pid)
            if force { c.processes.forEach { kill($0.pid, SIGKILL) }; kill(pid, SIGKILL) }
            else if pgid > 1 { killpg(pgid, SIGINT) } else { kill(pid, SIGINT) }
        case .background:
            c.processes.forEach { kill($0.pid, force ? SIGKILL : SIGTERM) }
        case .service, .system:
            return
        }
        smoothed[c.id] = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.liveTick() }
    }

    /// If an app is still there after a moment, it's probably asking about unsaved changes.
    private func watchQuit(_ app: NSRunningApplication, name: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard let self, !app.isTerminated else { return }
            quitMessage = "\(name) didn't quit. It may be asking about unsaved changes."
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
                if self?.quitMessage?.hasPrefix(name) == true { self?.quitMessage = nil }
            }
        }
    }

    func setLowPower(_ on: Bool) {
        LowPower.set(on) { [weak self] _ in self?.batteryChanged() }
    }

    func refreshChargeLimit() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let levels = ChargeLimit.shared.levels()
            let cur = ChargeLimit.shared.current()
            DispatchQueue.main.async { self?.chargeLevels = levels; self?.chargeLimit = cur }
        }
    }

    func setChargeLimit(_ level: Int) {
        if fullOnce { UserDefaults.standard.removeObject(forKey: "restoreLimit"); fullOnce = false }
        chargeLimit = level
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            ChargeLimit.shared.set(level)
            self?.refreshChargeLimit()
        }
    }

    /// Charges all the way once; the limit comes back when you unplug.
    func chargeToFullOnce() {
        guard let limit = chargeLimit, limit < 100 else { return }
        UserDefaults.standard.set(limit, forKey: "restoreLimit")
        fullOnce = true
        chargeLimit = 100
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in ChargeLimit.shared.set(100); self?.refreshChargeLimit() }
    }

    func cancelFullOnce() { endFullOnce() }

    private func endFullOnce() {
        let restore = UserDefaults.standard.integer(forKey: "restoreLimit")
        UserDefaults.standard.removeObject(forKey: "restoreLimit")
        fullOnce = false
        if restore > 0 { setChargeLimit(restore) }
    }

    func toggleHidden(_ key: String) {
        if let i = prefs.hiddenApps.firstIndex(of: key) { prefs.hiddenApps.remove(at: i) } else { prefs.hiddenApps.append(key) }
    }

    // MARK: Kept awake by

    private func refreshKeptAwake() {
        var out: [AwakeReason] = []
        var dict: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&dict) == kIOReturnSuccess, let byPID = dict?.takeRetainedValue() as? [NSNumber: [[String: Any]]] else {
            keptAwake = []; return
        }
        let ignore: Set<String> = ["powerd", "WindowServer", "coreaudiod", "sharingd", "useractivityd", "bluetoothd", "Wattline"]
        let wanted: Set<String> = ["PreventUserIdleSystemSleep", "PreventUserIdleDisplaySleep", "NoIdleSleepAssertion", "PreventSystemSleep", "NoDisplaySleepAssertion"]
        for (pidNum, list) in byPID {
            for a in list {
                guard let type = a["AssertType"] as? String, wanted.contains(type) else { continue }
                let behalf = (a["AssertionOnBehalfOfPID"] as? NSNumber)?.int32Value
                let pid = behalf ?? pidNum.int32Value
                let rpid = Proc.responsible(pid)
                let app = NSRunningApplication(processIdentifier: rpid)
                let name = app?.localizedName ?? Proc.short(pid)?.comm ?? "pid \(pid)"
                if ignore.contains(name) || out.contains(where: { $0.name == name }) { continue }
                let assertName = ((a["AssertName"] as? String) ?? "").lowercased()
                let reason: String, symbol: String
                if assertName.contains("audio") || assertName.contains("playing") || assertName.contains("music") {
                    reason = "Playing audio"; symbol = "speaker.wave.2.fill"
                } else if assertName.contains("call") || assertName.contains("microphone") || assertName.contains("conference") {
                    reason = "On a call"; symbol = "mic.fill"
                } else if type.contains("Display") {
                    reason = "Keeping the display on"; symbol = "display"
                } else {
                    reason = "Keeping the Mac awake"; symbol = "cup.and.saucer.fill"
                }
                out.append(AwakeReason(name: name, reason: reason, bundlePath: app?.bundleURL?.path, symbol: symbol))
            }
        }
        keptAwake = out.sorted { $0.name < $1.name }
    }

    // MARK: Notifications

    private func checkLevelNotifications() {
        let b = battery
        guard b.hasBattery else { return }
        if b.onBattery {
            for level in prefs.lowLevels.sorted(by: >) where b.percent <= level && !firedLow.contains(level) {
                firedLow.insert(level)
                let top = consumers.first ?? heaviestNow()
                var body = "About \(Fmt.duration(minutes: timeLeft)) left."
                if let top {
                    let gain = Cost.minutes(timeLeft: timeLeft, app: top.watts, system: b.systemPower)
                    body += " \(top.name) is using the most energy."
                    if gain >= 1 { body += " Quitting it would give you about \(Fmt.duration(minutes: gain)) more." }
                }
                let canQuit = top?.identity.canQuit == true && top?.identity.kind == .app
                Notifier.shared.post(id: "low\(level)", title: "Battery at \(b.percent)%", body: body,
                                     quitKey: canQuit ? top?.id : nil, quitName: canQuit ? top?.name : nil,
                                     lowPower: !canQuit && !b.lowPowerMode && level <= 20)
                break
            }
        }
        let target = min(prefs.chargedLevel, chargeLimit ?? 100)
        if prefs.notifyCharged, b.externalConnected, b.percent >= target, !firedCharged {
            firedCharged = true
            Notifier.shared.post(id: "charged", title: "Charged to \(b.percent)%",
                                 body: target < 100 ? "Unplug now to keep the battery between 20% and \(target)%, where it wears the least." : "The battery is full. You can unplug.")
        }
    }

    private func checkRunaway(_ r: EnergyReading) {
        guard prefs.notifyRunaway else { return }
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier.map { "app:\($0)" }
        let heavy = Set(r.consumers.filter { $0.watts >= max(3, r.systemWatts * 0.3) && $0.identity.canQuit }.map(\.id))
        for key in Array(hot.keys) where !heavy.contains(key) { hot[key] = nil; firedRunaway.remove(key) }
        for c in r.consumers where heavy.contains(c.id) {
            hot[c.id, default: 0] += 1
            guard hot[c.id]! >= 3, c.id != front, !firedRunaway.contains(c.id) else { continue }
            firedRunaway.insert(c.id)
            let gain = Cost.minutes(timeLeft: timeLeft, app: c.watts, system: r.systemWatts)
            Notifier.shared.post(id: "runaway:\(c.id)", title: "\(c.name) is using a lot of energy",
                                 body: "For \(hot[c.id]! * 5) minutes now. Quitting it would give you about \(Fmt.duration(minutes: gain)) more.",
                                 quitKey: c.id, quitName: c.name)
        }
    }

    private func accessoriesChanged(_ list: [Accessory], fresh: [Accessory]) {
        accessories = list
        for a in fresh where a.isEarbuds || a.kind == .airpodsMax || a.kind == .headphones { onAccessoryConnected?(a) }
        guard prefs.notifyAccessoryLow else { return }
        for a in list {
            guard let low = a.lowest else { continue }
            if low <= prefs.accessoryLevel, !firedAccessory.contains(a.id) {
                firedAccessory.insert(a.id)
                let hint = a.isEarbuds ? "Put them in their case to charge." : (a.kind == .keyboard || a.kind == .mouse || a.kind == .trackpad ? "Connect its cable to charge it." : "Charge it soon.")
                Notifier.shared.post(id: "acc:\(a.id)", title: "\(a.name) at \(low)%", body: hint)
            } else if low > prefs.accessoryLevel + 10 {
                firedAccessory.remove(a.id)      // comes again only once it has charged
            }
        }
    }

    private func checkMeeting() {
        guard prefs.meetingWarning, let m = meetings.nextMeeting(within: prefs.meetingLead), firedMeeting != m.start else { return }
        let lastsUntil = Date().addingTimeInterval(timeLeft * 60)
        guard lastsUntil < m.end else { return }
        firedMeeting = m.start
        let f = DateFormatter(); f.timeStyle = .short; f.dateStyle = .none
        Notifier.shared.post(id: "meeting", title: "Charge before your \(f.string(from: m.start)) meeting",
                             body: "The battery should last until about \(f.string(from: lastsUntil)), and the meeting runs until \(f.string(from: m.end)).",
                             lowPower: !battery.lowPowerMode)
    }

    // MARK: Insights

    /// With two weeks of history, says when today is different. It says nothing rather than guess.
    func evaluateInsights(latest: EnergyReading? = nil) {
        var out: [Insight] = []
        // Running warm: say what's busiest, plugged in or not.
        if prefs.warmBanner, let t = battery.temperature, t >= 38 {
            let top = (latest?.consumers ?? reading.consumers).first { !prefs.isHidden($0) && $0.watts >= 0.5 }
            var detail = battery.isCharging ? "Charging warms the battery, and macOS slows charging above about 40 °C." : "Heat wears the battery faster."
            if let top { detail = "\(top.name) is the busiest app right now (\(Fmt.watts(top.watts))). " + detail }
            out.append(Insight(id: "warm", title: "Running warm, \(Int(t.rounded()))°C", detail: detail,
                               quitKey: top?.identity.canQuit == true ? top?.id : nil, quitName: top?.identity.canQuit == true ? top?.name : nil))
        }
        // Budgets already passed today.
        for (key, limit) in prefs.budgets where battery.onBattery {
            let used = todayMinutes(key)
            if used >= Double(limit), let name = history.index(of: key).flatMap({ history.app($0) })?.name {
                out.append(Insight(id: "budget:\(key)", title: "\(name) is over its budget",
                                   detail: "\(Fmt.hoursMinutes(used)) of battery today, against \(Fmt.hoursMinutes(Double(limit))).",
                                   quitKey: key.hasPrefix("app:") || key.hasPrefix("cmd:") ? key : nil, quitName: name))
            }
        }
        guard battery.onBattery else { insights = out; return }
        let hours = history.hours
        let now = Int32(Date().timeIntervalSinceReferenceDate / 3600)
        let past = hours.filter { $0.h < now - 1 && $0.h >= now - 24 * 14 && $0.batWN > 0 }
        let days = Set(past.map { $0.h / 24 }).count
        let current = reading.systemWatts > 0 ? reading.systemWatts : battery.systemPower
        let top = (latest?.consumers ?? reading.consumers).first { !prefs.isHidden($0) && $0.identity.canQuit }

        if prefs.insightMoreThanUsual, days >= 7 {
            let hourOfDay = Calendar.current.component(.hour, from: Date())
            let same = past.filter { Calendar.current.component(.hour, from: HistoryStore.hourDate($0.h)) == hourOfDay }
            let usual = same.isEmpty ? 0 : same.reduce(Float(0)) { $0 + $1.batW / max(1, $1.batWN) } / Float(same.count)
            if usual > 0.5, current > Double(usual) * 1.3, current - Double(usual) > 2 {
                let pct = Int(((current / Double(usual)) - 1) * 100 / 5) * 5
                var detail = "About \(pct)% more than at this time on most days"
                if let top { detail += ", mostly because of \(top.name)." } else { detail += "." }
                out.append(Insight(id: "more", title: "Using more power than usual", detail: detail, quitKey: top?.id, quitName: top?.name))
            }
        }
        if prefs.insightNewApp, days >= 7, let latestTop = (latest?.consumers ?? reading.consumers).prefix(3).first(where: { $0.watts >= 1 && $0.identity.canQuit && !prefs.isHidden($0) }) {
            let idx = history.index(of: latestTop.id)
            let total = past.reduce(Float(0)) { $0 + $1.apps.values.reduce(0, +) }
            let mine = idx.map { i in past.reduce(Float(0)) { $0 + ($1.apps[i] ?? 0) } } ?? 0
            if total > 0, mine / total < 0.01 {
                out.append(Insight(id: "new:\(latestTop.id)", title: "\(latestTop.name) is new, and using a lot of battery",
                                   detail: "It hadn't used much battery in the last two weeks, and is now among the apps using the most.",
                                   quitKey: latestTop.id, quitName: latestTop.name))
            }
        }
        insights = out
        if prefs.insightsNotify {
            for i in out where !firedInsights.contains(i.id) {
                firedInsights.insert(i.id)
                Notifier.shared.post(id: "insight:\(i.id)", title: i.title, body: i.detail, quitKey: i.quitKey, quitName: i.quitName)
            }
        }
    }

    /// The app using the most since the last sample, measured on a copy so the history window isn't disturbed.
    private func heaviestNow() -> Consumer? {
        guard !historyBaseline.isEmpty else { return nil }
        var copy = historyBaseline
        return energy.measure(since: &copy, systemWatts: battery.systemPower).consumers.first { !prefs.isHidden($0) && $0.identity.canQuit }
    }

    // MARK: Budgets

    func todayMinutes(_ key: String) -> Double {
        let today = HistoryStore.localDay(Int32(Date().timeIntervalSinceReferenceDate / 3600))
        return history.appUse(in: history.hours(onLocalDay: today)).first { $0.ref.key == key }?.minutes ?? 0
    }

    private func checkBudgets() {
        let today = HistoryStore.localDay(Int32(Date().timeIntervalSinceReferenceDate / 3600))
        for (key, limit) in prefs.budgets {
            let tag = "\(key)|\(today)"
            guard !firedBudgets.contains(tag) else { continue }
            let used = todayMinutes(key)
            guard used >= Double(limit), let ref = history.index(of: key).flatMap({ history.app($0) }) else { continue }
            firedBudgets.insert(tag)
            let running = reading.consumers.contains { $0.id == key } || key.hasPrefix("app:")
            Notifier.shared.post(id: "budget:\(key)", title: "\(ref.name) used its battery budget",
                                 body: "\(Fmt.hoursMinutes(used)) of battery today, against the \(Fmt.hoursMinutes(Double(limit))) you set.",
                                 quitKey: running ? key : nil, quitName: running ? ref.name : nil)
        }
    }

    // MARK: Automatic Low Power Mode

    private func setAutoLPM(_ on: Bool) { autoLPMOn = on; UserDefaults.standard.set(on, forKey: "autoLPMOn") }

    private func scheduleAutoLPMTimer() {
        autoLPMTimer?.invalidate(); autoLPMTimer = nil
        guard prefs.autoLPMAfter, let at = unpluggedAt else { return }
        let fire = at.addingTimeInterval(TimeInterval(prefs.autoLPMAfterMinutes * 60))
        let t = Timer(fire: max(fire, Date().addingTimeInterval(1)), interval: 0, repeats: false) { [weak self] _ in self?.checkAutoLPM() }
        t.tolerance = 30
        RunLoop.main.add(t, forMode: .common)
        autoLPMTimer = t
    }

    func autoLPMSettingsChanged() { if battery.onBattery { scheduleAutoLPMTimer(); checkAutoLPM() } }

    private func checkAutoLPM() {
        let b = battery
        guard b.onBattery, !b.lowPowerMode, !autoLPMOn else { return }
        var reason: String?
        if prefs.autoLPMBelow, b.percent <= prefs.autoLPMLevel { reason = "the battery is at \(b.percent)%" }
        if reason == nil, prefs.autoLPMAfter, let at = unpluggedAt, Date().timeIntervalSince(at) >= Double(prefs.autoLPMAfterMinutes * 60) {
            reason = "you've been on battery for \(Fmt.hoursMinutes(Double(prefs.autoLPMAfterMinutes)))"
        }
        guard let reason else { return }
        setAutoLPM(true)
        LowPower.set(true, prompt: false) { [weak self] ok in
            guard let self else { return }
            self.battery = self.reader.read()
            if ok {
                Notifier.shared.post(id: "autolpm", title: "Low Power Mode is on", body: "Turned on because \(reason).\(self.prefs.autoLPMOffWhenPlugged ? " It goes off again when you plug in." : "")")
            } else {
                self.setAutoLPM(false)
                if !self.warnedNoHelper {
                    self.warnedNoHelper = true
                    Notifier.shared.post(id: "autolpm", title: "Turn on Low Power Mode?",
                                         body: "Wattline would have turned it on because \(reason), but switching it automatically needs the installer package's helper rule.",
                                         lowPower: true)
                }
            }
            self.onBatteryChange?()
        }
    }

    // MARK: Calendar-aware charging

    /// Plugged in with a charge limit, and a long day of meetings (or meetings somewhere else) coming up:
    /// charge to 100% once. The limit comes back when you unplug.
    func checkCalendarCharging() {
        guard prefs.calendarCharging, battery.externalConnected, meetings.authorized, !fullOnce,
              let limit = chargeLimit, limit < 100 else { return }
        let now = Date()
        let load = meetings.load(from: now, to: now.addingTimeInterval(16 * 3600))
        guard let first = load.first, calendarChargedFor != first else { return }
        let long = load.hours >= Double(prefs.calendarHours)
        let away = prefs.calendarCountLocations && load.hasLocation
        guard long || away else { return }
        calendarChargedFor = first
        chargeToFullOnce()
        let f = DateFormatter(); f.dateFormat = Calendar.current.isDateInToday(first) ? "HH:mm" : "EEEE HH:mm"
        let why = long ? "\(Fmt.hoursMinutes(load.hours * 60)) of meetings" : "meetings away from your desk"
        Notifier.shared.post(id: "calcharge", title: "Charging to 100% for \(why)",
                             body: "Starting \(Calendar.current.isDateInToday(first) ? "at" : "on") \(f.string(from: first)). Your \(limit)% limit comes back when you unplug.")
    }

    var calendarChargingActive: Bool { calendarChargedFor != nil && fullOnce }

    // MARK: Screen brightness

    /// "Dimming 20% gives +25m": the battery time a dimmer screen would give back.
    var dimmingGain: (minutes: Double, watts: Double, to: Double)? {
        guard battery.onBattery, let s = Brightness.savings(dimmingBy: 0.2), s.watts > 0.05 else { return nil }
        let system = max(battery.systemPower, reading.systemWatts)
        return (Cost.minutes(timeLeft: timeLeft, app: s.watts, system: system), s.watts, s.to)
    }

    func dimScreen(by step: Double) {
        guard let b = Brightness.level() else { return }
        Brightness.set(b - step)
    }

    // MARK: Sleep and wake

    /// Power notifications from the kernel: they also arrive on dark wakes, when the screen stays off.
    private func registerSystemPower() {
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        rootPort = IORegisterForSystemPower(ctx, &powerPort, { ctx, _, message, arg in
            guard let ctx else { return }
            let me = Unmanaged<AppModel>.fromOpaque(ctx).takeUnretainedValue()
            switch message {
            case 0xE000_0270, 0xE000_0280:   // can sleep, will sleep
                IOAllowPowerChange(me.rootPort, Int(bitPattern: arg))
            case 0xE000_0300:                // has powered on (also dark wakes)
                let raw = WakeReasons.latest() ?? "unknown"
                let dark = Brightness.builtIn == nil || (WakeReasons.wakeType() ?? "").lowercased().contains("dark")
                DispatchQueue.main.async { me.noteWake(raw: raw, dark: dark) }
            default: break
            }
        }, &powerNotifier)
        if let port = powerPort {
            CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(port).takeUnretainedValue(), .commonModes)
        }
    }

    private func noteWake(raw: String, dark: Bool) {
        guard sleepStart != nil else { return }
        sleepWakes.append(WakeEvent(date: Date(), dark: dark, reason: WakeReasons.describe(raw)))
        if sleepWakes.count > 200 { sleepWakes.removeFirst(sleepWakes.count - 200) }
    }

    /// Reads macOS's power log for every wake during a sleep. Takes a few seconds, so it runs only when asked.
    func lookUpWakes(for rec: SleepRecord, done: @escaping () -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let wakes = WakeReasons.fromPowerLog(between: rec.start, and: rec.end.addingTimeInterval(60))
            DispatchQueue.main.async {
                self?.history.updateSleep(rec.start, wakes: wakes)
                self?.historyVersion += 1
                done()
            }
        }
    }

    // MARK: Widget

    func writeWidget(force: Bool = false) {
        guard force || Date().timeIntervalSince(lastWidgetWrite) > 60 else { return }
        lastWidgetWrite = Date()
        let today = HistoryStore.localDay(Int32(Date().timeIntervalSinceReferenceDate / 3600))
        let live = reading.consumers
        let apps = history.appUse(in: history.hours(onLocalDay: today)).prefix(3).map { a in
            WidgetSnapshot.App(name: a.ref.name, path: a.ref.path, symbol: a.ref.symbol, minutes: a.minutes,
                               watts: live.first { $0.id == a.ref.key }?.watts ?? 0)
        }
        let snap = WidgetSnapshot(date: Date(), percent: battery.percent, charging: battery.isCharging, plugged: battery.externalConnected,
                                  minutesLeft: battery.onBattery ? timeLeft : Double(battery.minutesToFull ?? 0), apps: Array(apps))
        DispatchQueue.global(qos: .utility).async {
            if let data = try? JSONEncoder().encode(snap) { try? data.write(to: WidgetSnapshot.url, options: .atomic) }
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    // MARK: Since unplugged

    var sinceUnplugged: (minutes: Double, perHour: Double)? {
        guard battery.onBattery, let at = unpluggedAt else { return nil }
        let m = Date().timeIntervalSince(at) / 60
        guard m > 1 else { return nil }
        let used = Double(max(0, unpluggedPct - battery.percent))
        return (m, m > 10 ? used / (m / 60) : 0)
    }
}

