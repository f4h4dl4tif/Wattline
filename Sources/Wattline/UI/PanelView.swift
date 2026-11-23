import AppKit
import SwiftUI

/// The panel: like the system's own Battery menu, plus the part macOS leaves out.
struct PanelView: View {
    var model: AppModel
    var openSettings: (SettingsPane?) -> Void
    @State private var hovered: String?
    @State private var selected: String?
    @State private var historyTab = 0
    @State private var selectedDay: Int32?
    @State private var confirmLPM = false
    private var prefs: Prefs { model.prefs }

    var body: some View {
        let b = model.battery
        VStack(alignment: .leading, spacing: 8) {
            header(b)
            if b.hasBattery {
                if b.onBattery {
                    SliceBattery(model: model, hovered: $hovered, selected: $selected)
                } else {
                    ChargeBattery(model: model)
                }
                if let sel = selected { SliceDetail(model: model, sliceID: sel) { withAnimation { selected = nil } }.transition(.opacity) }
                if !b.onBattery { pluggedConsumers }
                banners
                details(b)
            } else {
                noBatteryNote
            }
            if prefs.showSleep && b.hasBattery { Divider(); sleepSection }
            if prefs.showHistory && b.hasBattery { Divider(); historySection }
            if prefs.showAccessories && (!model.accessories.isEmpty || !b.hasBattery) { Divider(); accessorySection }
            Divider()
            VStack(spacing: 0) {
                MenuRow(title: "Battery Settings…") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Battery-Settings.extension")!)
                }
                MenuRow(title: "Wattline Settings…") { openSettings(nil) }
                MenuRow(title: "Quit Wattline") { NSApp.terminate(nil) }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .frame(width: Theme.panelWidth)
        .environment(\.glassPanel, prefs.useGlass)
        .onChange(of: model.panelOpen) { _, open in if !open { selected = nil; hovered = nil; selectedDay = nil } }
    }

    // MARK: Header

    private func header(_ b: BatteryState) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Battery").font(.system(size: 13, weight: .bold))
                Spacer()
                if b.hasBattery { Text("\(b.percent)%").font(.system(size: 13)).monospacedDigit().foregroundStyle(.panelSecondary) }
            }
            Text("Power Source: \(b.powerSource)").font(.system(size: 11)).foregroundStyle(.panelSecondary)
        }
    }

    // MARK: On the charger: who's drawing what

    @ViewBuilder
    private var pluggedConsumers: some View {
        let list = Array(model.consumers.prefix(prefs.sliceCount))
        if !list.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Using the most energy").font(.system(size: 11)).foregroundStyle(.panelSecondary)
                ForEach(list) { c in
                    Button { withAnimation { selected = selected == c.id ? nil : c.id } } label: {
                        HStack(spacing: 7) {
                            ConsumerIcon(identity: c.identity, size: 16)
                            Text(c.name).font(.system(size: 12)).lineLimit(1)
                            Spacer()
                            Text((c.estimated ? "≈ " : "") + Fmt.watts(c.watts)).font(.system(size: 11)).monospacedDigit().foregroundStyle(.panelSecondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: Banners

    @ViewBuilder
    private var banners: some View {
        if let msg = model.quitMessage {
            Banner(symbol: "exclamationmark.bubble", title: msg, detail: nil, tint: .orange) {
                Button("Show") {
                    if let app = NSWorkspace.shared.runningApplications.first(where: { msg.hasPrefix(($0.localizedName ?? "\u{0}") + " ") }) { app.activate() }
                    model.quitMessage = nil
                }
            }
        }
        if model.lowPowerSuggestion {
            Banner(symbol: "battery.25percent", title: "Battery at \(model.battery.percent)%", detail: "Low Power Mode makes it last longer.", tint: .yellow) {
                Button("Turn On") { model.setLowPower(true) }
            }
        }
        if prefs.showInsights {
            ForEach(model.insights) { i in
                Banner(symbol: i.id == "warm" ? "thermometer.high" : (i.id.hasPrefix("budget") ? "hourglass" : (i.id.hasPrefix("new") ? "sparkles" : "chart.line.uptrend.xyaxis")),
                       title: i.title, detail: i.detail, tint: i.id == "warm" ? .red : .orange) {
                    if i.id == "warm" { Button("Why?") { openSettings(.warmth) } }
                    if let key = i.quitKey, let name = i.quitName { Button("Quit \(name)") { model.quit(key: key, force: false) } }
                }
            }
        }
        if let note = chargerNote(model.battery) {
            Banner(symbol: note.symbol, title: note.title, detail: note.detail, tint: note.tint) { EmptyView() }
        }
    }

    // MARK: Details

    @ViewBuilder
    private func details(_ b: BatteryState) -> some View {
        VStack(spacing: 1) {
            if b.onBattery {
                InfoRow(label: hoveredSlice.map { "Without \($0.name)" } ?? "Time left") {
                    HStack(spacing: 6) {
                        Text(model.timeLeft > 0 ? Fmt.duration(minutes: model.timeLeft) : "Calculating…").monospacedDigit()
                        if let s = hoveredSlice, s.minutes >= 1 {
                            Text("+" + Fmt.duration(minutes: s.minutes)).monospacedDigit().foregroundStyle(Theme.green).transition(.opacity)
                        }
                    }
                }
                .animation(.easeOut(duration: 0.12), value: hovered)
            } else if b.isCharging, let m = b.minutesToFull {
                InfoRow(label: "Time to \(min(100, model.chargeLimit ?? 100))%") { Text(Fmt.duration(minutes: Double(m))).monospacedDigit() }
            }
            InfoRow(label: "Battery Health") { Text("\(b.condition) · \(b.maxCapacityPercent)% · \(b.cycleCount) cycles").monospacedDigit() }
            if prefs.showChargeLimit && !model.chargeLevels.isEmpty {
                InfoRow(label: "Charge Limit") {
                    Menu {
                        ForEach(model.chargeLevels.reversed(), id: \.self) { l in
                            Button(l == 100 ? "None" : "\(l)%") { model.setChargeLimit(l) }
                        }
                    } label: {
                        Text(model.fullOnce ? "100% Once" : ((model.chargeLimit ?? 100) >= 100 ? "None" : "\(model.chargeLimit!)%"))
                            .font(.system(size: 12))
                    }
                    .menuStyle(.borderlessButton).fixedSize()
                }
                if b.externalConnected && ((model.chargeLimit ?? 100) < 100 || model.fullOnce) {
                    InfoRow(label: model.fullOnce ? "Charging to 100% once" : "Charge to Full Once") {
                        Button(model.fullOnce ? "Cancel" : "Charge") { model.fullOnce ? model.cancelFullOnce() : model.chargeToFullOnce() }
                            .controlSize(.small)
                    }
                }
            }
            if b.externalConnected && (b.adapterRating > 0 || b.adapterInput > 0) {
                InfoRow(label: "Charger") {
                    Text(b.adapterRating > 0 ? "\(Int(b.adapterInput.rounded())) W of \(b.adapterRating) W" : "\(Int(b.adapterInput.rounded())) W").monospacedDigit()
                }
            }
            if prefs.showReadings {
                if let t = b.temperature { InfoRow(label: "Temperature") { Text("\(Int(t.rounded()))°C").monospacedDigit() } }
                InfoRow(label: "Voltage & Current") {
                    Text(String(format: "%.2f V · %.2f A %@", b.voltage, abs(b.amperage), b.amperage >= 0 ? "in" : "out")).monospacedDigit()
                }
                InfoRow(label: "Power Draw") { Text(Fmt.watts(b.systemPower)).monospacedDigit() }
            }
            if let g = model.dimmingGain, g.minutes >= 1 {
                InfoRow(label: "Screen") {
                    HStack(spacing: 6) {
                        Text("dimming 20% gives").foregroundStyle(.panelSecondary)
                        Text("+" + Fmt.duration(minutes: g.minutes)).monospacedDigit().foregroundStyle(Theme.green)
                        Button("Dim") { model.dimScreen(by: 0.2) }.controlSize(.mini)
                    }
                }
            }
            InfoRow(label: "Low Power Mode") {
                Toggle("", isOn: Binding(get: { b.lowPowerMode }, set: { model.setLowPower($0) }))
                    .toggleStyle(.switch).controlSize(.mini).labelsHidden()
            }
        }
    }

    private var hoveredSlice: Slice? {
        guard let h = hovered else { return nil }
        return model.slices.first { $0.id == h && !$0.isSystem }
    }

    // MARK: Sleep

    private var sleepSection: some View {
        VStack(alignment: .leading, spacing: 1) {
            SectionTitle(text: "Sleep")
            if let last = model.history.sleeps.last {
                InfoRow(label: "Last Sleep") {
                    Text("\(Fmt.hoursMinutes(last.hours * 60)) · \(last.plugged ? "plugged in" : "\(last.used)% used")").monospacedDigit()
                }
            } else {
                InfoRow(label: "Last Sleep") { Text("Not yet").foregroundStyle(.panelSecondary) }
            }
            InfoRow(label: "Kept Awake By") {
                if model.keptAwake.isEmpty {
                    Text("Nothing").foregroundStyle(.panelSecondary)
                } else {
                    HStack(spacing: 4) {
                        ForEach(model.keptAwake.prefix(2)) { a in
                            if let p = a.bundlePath { Image(nsImage: IconCache.icon(path: p)).resizable().frame(width: 14, height: 14) }
                            Text(a.name).lineLimit(1)
                            Image(systemName: a.symbol).font(.system(size: 9)).foregroundStyle(.panelSecondary).help(a.reason)
                        }
                    }
                }
            }
        }
    }

    // MARK: History

    private var historySection: some View {
        let _ = model.historyVersion
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                SectionTitle(text: historyTab == 0 ? "Last 24 Hours" : "Last 10 Days")
                Button { openSettings(.history) } label: { Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.panelSecondary) }
                    .buttonStyle(.plain).help("Open History in Settings")
            }
            Picker("", selection: $historyTab) { Text("24 Hours").tag(0); Text("10 Days").tag(1) }
                .pickerStyle(.segmented).labelsHidden().controlSize(.small)
                .onChange(of: historyTab) { _, _ in selectedDay = nil }
            if historyTab == 0 {
                LevelBarsChart(bars: model.history.levelBars(current: model.battery))
                if let since = model.sinceUnplugged {
                    InfoRow(label: "On battery") {
                        Text(Fmt.duration(minutes: since.minutes) + (since.perHour > 0 ? " · \(Int(since.perHour.rounded()))% an hour" : "")).monospacedDigit()
                    }
                }
                topApps(model.history.appUse(in: model.history.hours(lastDays: 1)), title: "Used the most battery")
            } else {
                let days = model.history.days(10)
                DayBarsChart(days: days, selected: selectedDay) { d in selectedDay = selectedDay == d ? nil : d }
                let active = days.filter { $0.batteryMinutes > 0 }
                if selectedDay == nil, !active.isEmpty {
                    let avgMin = active.reduce(0) { $0 + $1.batteryMinutes } / Double(active.count)
                    let avgUsed = active.reduce(0) { $0 + $1.used } / Double(active.count)
                    InfoRow(label: "Average day") { Text("\(Fmt.duration(minutes: avgMin)) on battery · \(Int(avgUsed.rounded()))% used").monospacedDigit() }
                }
                if let d = selectedDay {
                    topApps(model.history.appUse(in: model.history.hours(onLocalDay: d)),
                            title: HistoryStore.localDayDate(d).formatted(.dateTime.weekday(.wide).day().month()))
                } else {
                    topApps(model.history.appUse(in: model.history.hours(lastDays: 10)), title: "Used the most battery")
                }
            }
        }
    }

    @ViewBuilder
    private func topApps(_ apps: [AppUse], title: String) -> some View {
        Text(title).font(.system(size: 11)).foregroundStyle(.panelSecondary).padding(.top, 2)
        if apps.isEmpty {
            Text("Apps are measured every five minutes while on battery.").font(.system(size: 11)).foregroundStyle(.panelTertiary)
        } else {
            let top = apps.prefix(3)
            let maxShare = top.first?.share ?? 1
            ForEach(Array(top)) { a in
                Button { openSettings(.app(a.ref.key)) } label: {
                    VStack(spacing: 3) {
                        HStack(spacing: 7) {
                            ConsumerIcon(identity: GroupIdentity(key: a.ref.key, kind: a.ref.kind, name: a.ref.name, bundlePath: a.ref.path, symbol: a.ref.symbol, terminalBadge: a.ref.badge ?? false), size: 16)
                            Text(a.ref.name).font(.system(size: 12)).lineLimit(1)
                            Spacer()
                            Text(Fmt.duration(minutes: a.minutes)).font(.system(size: 11)).monospacedDigit().foregroundStyle(.panelSecondary)
                        }
                        GeometryReader { g in
                            Capsule().fill(Color.accentColor.opacity(0.8)).frame(width: max(4, g.size.width * CGFloat(a.share / maxShare)), height: 3)
                        }
                        .frame(height: 3).padding(.leading, 23)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: Accessories

    private var accessorySection: some View {
        VStack(alignment: .leading, spacing: 5) {
            SectionTitle(text: "Accessories")
            if model.accessories.isEmpty {
                Text("No accessories connected.").font(.system(size: 11)).foregroundStyle(.panelSecondary)
            }
            ForEach(model.accessories) { a in AccessoryRow(accessory: a) }
        }
    }

    private var noBatteryNote: some View {
        Text("This Mac has no battery of its own. Wattline still shows your accessories.")
            .font(.system(size: 11)).foregroundStyle(.panelSecondary).fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Charger notes

    /// When plugged in but not charging or charging slowly, a note that says why. No visible reason: no note.
    private func chargerNote(_ b: BatteryState) -> (symbol: String, title: String, detail: String, tint: Color)? {
        guard b.externalConnected, b.hasBattery else { return nil }
        let limit = model.chargeLimit ?? 100
        let rating = Double(b.adapterRating)
        if !b.isCharging {
            if b.percent >= limit - 1 && limit < 100 { return nil }
            if let t = b.temperature, t >= 40 {
                return ("thermometer.high", "Too warm to charge", "macOS pauses charging above about 40 °C, and carries on once the battery cools.", .orange)
            }
            if b.percent >= 93 {
                return ("checkmark.circle", "Nearly full", "“Not Charging” at \(b.percent)% is nothing to worry about: macOS lets a full battery drift down before topping it up.", .green)
            }
            if rating > 0, b.amperage < -0.05, b.systemPower < rating * 0.5 {
                return ("cable.connector", "Running on battery while plugged in", "A \(b.adapterRating) W charger, a Mac using \(String(format: "%.1f", b.systemPower)) W, and the battery still running down: the cable or port isn't giving full power.", .orange)
            }
            if rating > 0, b.systemPower >= rating * 0.85 {
                return ("bolt.trianglebadge.exclamationmark", "The charger can't keep up", "Your Mac is using about \(Int(b.systemPower)) W, about all the \(b.adapterRating) W charger can give, so there's none left for the battery. A more powerful charger, or quitting busy apps, helps.", .orange)
            }
            return nil
        }
        if rating > 0, b.batteryPowerWatts > 0, b.batteryPowerWatts < rating * 0.15, b.systemPower > rating * 0.6, b.percent < 80 {
            return ("tortoise", "Charging slowly", "The Mac takes most of what the charger gives, leaving little for the battery.", .yellow)
        }
        return nil
    }
}

struct Banner<Actions: View>: View {
    var symbol: String
    var title: String
    var detail: String?
    var tint: Color
    @ViewBuilder var actions: Actions
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: symbol).font(.system(size: 13)).foregroundStyle(tint).frame(width: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 12, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                    if let detail { Text(detail).font(.system(size: 11)).foregroundStyle(.panelSecondary).fixedSize(horizontal: false, vertical: true) }
                }
            }
            HStack { Spacer(); actions }.controlSize(.small)
        }
        .padding(9)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(tint.opacity(0.1)))
    }
}

struct AccessoryRow: View {
    var accessory: Accessory
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: NSImage(systemSymbolName: accessory.symbol, accessibilityDescription: nil) == nil ? "headphones" : accessory.symbol)
                .font(.system(size: 14)).frame(width: 20)
            VStack(alignment: .leading, spacing: 0) {
                Text(accessory.name).font(.system(size: 12)).lineLimit(1)
                if let m = accessory.model, m != accessory.name { Text(m).font(.system(size: 10)).foregroundStyle(.panelSecondary).lineLimit(1) }
            }
            Spacer()
            HStack(spacing: 8) {
                ForEach(accessory.parts) { p in
                    HStack(spacing: 3) {
                        if !p.label.isEmpty { Text(p.label == "Case" ? "Case" : String(p.label.prefix(1))).font(.system(size: 9, weight: .semibold)).foregroundStyle(.panelSecondary) }
                        MiniRing(level: p.level).frame(width: 13, height: 13)
                        Text("\(p.level)%").font(.system(size: 11)).monospacedDigit()
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct MiniRing: View {
    var level: Int
    var body: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.15), lineWidth: 2)
            Circle().trim(from: 0, to: CGFloat(level) / 100).rotation(.degrees(-90))
                .stroke(level <= 20 ? Theme.red : Theme.green, style: StrokeStyle(lineWidth: 2, lineCap: .round))
        }
    }
}
