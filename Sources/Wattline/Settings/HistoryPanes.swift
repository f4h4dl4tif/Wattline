import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - History: every app, every day, a year back

struct HistoryPane: View {
    var model: AppModel
    @Binding var appKey: String?
    @State private var period: Period = .week
    @State private var day: Int32?
    @Bindable private var prefs = Prefs.shared

    var body: some View {
        let _ = model.historyVersion
        if let key = appKey {
            AppHistoryPage(model: model, key: key, period: period) { appKey = nil }
        } else {
            overview
        }
    }

    private var overview: some View {
        let store = model.history
        let days = store.days(period.days)
        let active = days.filter { $0.batteryMinutes > 0 }
        let totalMin = active.reduce(0) { $0 + $1.batteryMinutes }
        let totalUsed = active.reduce(0) { $0 + $1.used }
        let hrs = day.map { store.hours(onLocalDay: $0) } ?? store.hours(lastDays: period.days)
        let apps = store.appUse(in: hrs)
        return Form {
            Section {
                Picker("", selection: $period) {
                    ForEach([Period.week, .twoWeeks, .month, .quarter, .year]) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
                .onChange(of: period) { _, _ in day = nil }
                HStack(alignment: .top) {
                    stat("Daily Average", active.isEmpty ? "—" : Fmt.hoursMinutes(totalMin / Double(active.count)), "on battery")
                    Spacer()
                    stat("Used a Day", active.isEmpty ? "—" : "\(Int((totalUsed / Double(active.count)).rounded()))%", "of the battery")
                    Spacer()
                    stat("Total", Fmt.hoursMinutes(totalMin), String(format: "· %.1f charges", totalUsed / 100))
                }
                DayBarsChart(days: days, selected: day, height: 120,
                             labelStyle: period.days <= 14 ? .dateTime.weekday(.abbreviated) : .dateTime.day()) { d in day = day == d ? nil : d }
                if let day { Text(HistoryStore.localDayDate(day).formatted(.dateTime.weekday(.wide).day().month().year())).font(.caption).foregroundStyle(.secondary) }
            } header: { Text("Battery Use") }

            Section(day == nil ? "Apps" : "Apps that day") {
                if apps.isEmpty { Text("Apps are measured every five minutes while on battery.").foregroundStyle(.secondary) }
                ForEach(apps.prefix(40)) { a in
                    Button { appKey = a.ref.key } label: {
                        HStack(spacing: 8) {
                            ConsumerIcon(identity: identity(a.ref), size: 20)
                            Text(a.ref.name)
                            Spacer()
                            Text("\(Int((a.share * 100).rounded()))%").monospacedDigit().foregroundStyle(.secondary).frame(width: 44, alignment: .trailing)
                            Text(Fmt.hoursMinutes(a.minutes)).monospacedDigit().frame(width: 70, alignment: .trailing)
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
            }

            Section {
                Picker("Keep history for", selection: $prefs.retentionDays) {
                    Text("2 weeks").tag(14); Text("1 month").tag(30); Text("3 months").tag(90); Text("1 year").tag(365)
                }
                HStack {
                    Text("Export")
                    Spacer()
                    Button("Hourly CSV…") { export(store.exportCSV(perApp: false).data(using: .utf8), name: "Wattline hourly.csv", type: .commaSeparatedText) }
                    Button("Apps per Day CSV…") { export(store.exportCSV(perApp: true).data(using: .utf8), name: "Wattline apps.csv", type: .commaSeparatedText) }
                    Button("Everything as JSON…") { export(store.exportJSON(), name: "Wattline history.json", type: .json) }
                }
            } footer: { Text("Hourly summaries take a few kilobytes a day, and none of it ever leaves your Mac.").font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading) }
        }
        .formStyle(.grouped)
    }

    private func stat(_ title: String, _ value: String, _ sub: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: 22, weight: .semibold, design: .rounded)).monospacedDigit()
            Text(sub).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func export(_ data: Data?, name: String, type: UTType) {
        guard let data else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.allowedContentTypes = [type]
        if panel.runModal() == .OK, let url = panel.url { try? data.write(to: url) }
    }
}

func identity(_ r: AppRef) -> GroupIdentity {
    GroupIdentity(key: r.key, kind: r.kind, name: r.name, bundlePath: r.path, symbol: r.symbol, terminalBadge: r.badge ?? false)
}

/// One app: what it cost, when it's busiest, and whether it's getting hungrier.
struct AppHistoryPage: View {
    var model: AppModel
    var key: String
    var period: Period
    var back: () -> Void

    var body: some View {
        let store = model.history
        let idx = store.index(of: key)
        let ref = idx.flatMap { store.app($0) }
        let now = store.hours(lastDays: period.days)
        let before = store.hours(lastDays: period.days, offsetDays: period.days)
        let use = store.appUse(in: now).first { $0.ref.key == key }
        let prevUse = store.appUse(in: before).first { $0.ref.key == key }
        let daily = dailyMinutes(idx, store: store)
        Form {
            Section {
                HStack(spacing: 12) {
                    Button(action: back) { Image(systemName: "chevron.left") }.buttonStyle(.borderless)
                    if let ref { ConsumerIcon(identity: identity(ref), size: 36) }
                    VStack(alignment: .leading) {
                        Text(ref?.name ?? key).font(.title2.bold())
                        Text("Last \(period.days) days").foregroundStyle(.secondary)
                    }
                }
            }
            Section("What it cost") {
                LabeledContent("Battery time", value: Fmt.hoursMinutes(use?.minutes ?? 0))
                LabeledContent("Share of the battery", value: "\(Int(((use?.share ?? 0) * 100).rounded()))%")
                LabeledContent("Energy", value: String(format: "%.1f Wh", (use?.wattMinutes ?? 0) / 60))
                LabeledContent("Trend") { trend(now: use, before: prevUse) }
            }
            Section {
                Picker("Daily budget", selection: Binding(get: { Prefs.shared.budgets[key] ?? 0 }, set: { v in
                    Prefs.shared.budgets[key] = v == 0 ? nil : v; if v > 0 { Notifier.shared.requestPermission() }
                })) {
                    Text("None").tag(0)
                    ForEach([15, 30, 60, 120, 180, 240], id: \.self) { Text(Fmt.hoursMinutes(Double($0)) + " a day").tag($0) }
                }
                if let limit = Prefs.shared.budgets[key] {
                    let used = model.todayMinutes(key)
                    ProgressView(value: min(used, Double(limit)), total: Double(limit)) {
                        Text("\(Fmt.hoursMinutes(used)) used today").font(.caption)
                    }.tint(used >= Double(limit) ? Theme.orange : .accentColor)
                }
            } header: { Text("Budget") } footer: { Text("A notification once a day when it uses more battery time than this.").font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading) }
            Section("Each day") {
                DayBarsChart(days: daily, selected: nil, height: 90, labelStyle: period.days <= 14 ? .dateTime.weekday(.narrow) : .dateTime.day())
            }
            Section {
                let tod = store.throughTheDay(app: idx, in: now)
                HourOfDayChart(values: tod)
                if let peak = tod.indices.max(by: { tod[$0] < tod[$1] }), tod[peak] > 0 {
                    Text(String(format: "Busiest around %02d:00, drawing about %.1f W.", peak, tod[peak])).font(.callout).foregroundStyle(.secondary)
                }
            } header: { Text("Through the day") }
        }
        .formStyle(.grouped)
    }

    /// Battery minutes per day for this app, drawn on the day-bar chart as a percentage of that day's battery time.
    private func dailyMinutes(_ idx: Int32?, store: HistoryStore) -> [DayUse] {
        store.days(period.days).map { d in
            let hrs = store.hours(onLocalDay: d.day)
            let share = store.appUse(in: hrs).first { $0.index == idx }?.share ?? 0
            return DayUse(day: d.day, used: share * 100, batteryMinutes: d.batteryMinutes)
        }
    }

    /// Under a tenth either way is steady, so it never cries wolf.
    @ViewBuilder
    private func trend(now: AppUse?, before: AppUse?) -> some View {
        let a = now?.share ?? 0, b = before?.share ?? 0
        if b <= 0.001 && a > 0.001 {
            Text("New this period").foregroundStyle(Theme.orange)
        } else if b > 0 {
            let change = (a - b) / b
            if abs(change) < 0.1 { Text("Steady").foregroundStyle(.secondary) }
            else if change > 0 { Label("Getting hungrier, \(Int((change * 100).rounded()))%", systemImage: "arrow.up.right").foregroundStyle(Theme.orange) }
            else { Label("Lighter, \(Int((change * 100).rounded()))%", systemImage: "arrow.down.right").foregroundStyle(Theme.green) }
        } else { Text("—").foregroundStyle(.secondary) }
    }
}

// MARK: - Battery Health: your battery, over time

enum Vital: String, CaseIterable, Identifiable { case temperature = "Temperature", charge = "Charge Level", power = "Power", voltage = "Voltage", health = "Health"; var id: String { rawValue }
    var symbol: String { switch self { case .temperature: "thermometer.medium"; case .charge: "battery.75percent"; case .power: "bolt.fill"; case .voltage: "waveform.path.ecg"; case .health: "heart.fill" } }
    var tint: Color { switch self { case .temperature: .orange; case .charge: .green; case .power: .yellow; case .voltage: .blue; case .health: .pink } }
}

struct BatteryHealthPane: View {
    var model: AppModel
    @State private var period: Period = .week
    @State private var filter: PowerFilter = .all
    @State private var compare = false
    @State private var open: Vital?

    var body: some View {
        let _ = model.historyVersion
        Form {
            Section {
                Picker("", selection: $period) { ForEach([Period.day, .week, .month, .quarter, .year]) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden()
                HStack {
                    Picker("", selection: $filter) { ForEach(PowerFilter.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented).labelsHidden().frame(width: 280)
                    Spacer()
                    Toggle("Compare with before", isOn: $compare)
                }
            }
            if let v = open {
                detail(v)
            } else {
                Section {
                    ForEach(Vital.allCases) { v in
                        Button { withAnimation { open = v } } label: { row(v) }.buttonStyle(.plain)
                    }
                } header: { Text("Battery Health") } footer: {
                    Text("Read every five minutes, plugged in or not: a few registry reads each time. Maximum capacity and cycles are read once a day and kept for good.").font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                }
            }
        }
        .formStyle(.grouped)
    }

    // Buckets: hours for 24H, days otherwise.
    private func buckets(offsetDays: Int = 0) -> [[Hour]] {
        let hrs = model.history.hours(lastDays: period.days, offsetDays: offsetDays).filter { h in
            switch filter { case .all: true; case .battery: h.bat >= h.ac && h.bat > 0; case .plugged: h.ac > h.bat }
        }
        if period == .day {
            let now = Int32(Date().timeIntervalSinceReferenceDate / 3600) - Int32(offsetDays * 24)
            return (0..<24).map { i in hrs.filter { $0.h == now - 23 + Int32(i) } }
        }
        let today = HistoryStore.localDay(Int32(Date().timeIntervalSinceReferenceDate / 3600)) - Int32(offsetDays)
        let grouped = Dictionary(grouping: hrs, by: { HistoryStore.localDay($0.h) })
        return (0..<period.days).map { i in grouped[today - Int32(period.days) + 1 + Int32(i)] ?? [] }
    }

    private func series(_ v: Vital, _ b: [[Hour]]) -> [Double?] {
        b.map { hs -> Double? in
            guard !hs.isEmpty else { return nil }
            switch v {
            case .temperature: let n = hs.reduce(Float(0)) { $0 + $1.tN }; return n > 0 ? Double(hs.reduce(Float(0)) { $0 + $1.tSum } / n) : nil
            case .charge: return Double(hs.map(\.lo).min() ?? 0)
            case .power: let n = hs.reduce(Float(0)) { $0 + $1.wN }; return n > 0 ? Double(hs.reduce(Float(0)) { $0 + $1.wSum } / n) : nil
            case .voltage: let vs = hs.filter { $0.vMax > 0 }; return vs.isEmpty ? nil : Double(vs.reduce(Float(0)) { $0 + ($1.vMin + $1.vMax) / 2 } / Float(vs.count))
            case .health: return nil
            }
        }
    }

    private func capacitySeries() -> [CapacityDay] {
        let today = Int32(Date().timeIntervalSinceReferenceDate / 86400)
        return model.history.capacity.filter { $0.d > today - Int32(max(period.days, 2)) }
    }

    private func summary(_ v: Vital) -> String {
        let hrs = buckets().flatMap { $0 }
        switch v {
        case .temperature:
            let n = hrs.reduce(Float(0)) { $0 + $1.tN }
            guard n > 0 else { return "No readings yet" }
            return "Average \(Int((hrs.reduce(Float(0)) { $0 + $1.tSum } / n).rounded()))°, up to \(Int((hrs.map(\.tMax).max() ?? 0).rounded()))°"
        case .charge:
            guard !hrs.isEmpty else { return "No readings yet" }
            let ac = hrs.reduce(Float(0)) { $0 + $1.ac }, all = hrs.reduce(Float(0)) { $0 + $1.ac + $1.bat }
            return "Down to \(hrs.map(\.lo).min() ?? 0)%, on the charger \(all > 0 ? Int((ac / all * 100).rounded()) : 0)% of the time"
        case .power:
            let n = hrs.reduce(Float(0)) { $0 + $1.wN }
            guard n > 0 else { return "No readings yet" }
            return String(format: "The Mac drew %.1f W on average, up to %.0f W", hrs.reduce(Float(0)) { $0 + $1.wSum } / n, hrs.map(\.wMax).max() ?? 0)
        case .voltage:
            let vs = hrs.filter { $0.vMax > 0 }
            guard !vs.isEmpty else { return "No readings yet" }
            return String(format: "Between %.2f and %.2f V", vs.map(\.vMin).min() ?? 0, vs.map(\.vMax).max() ?? 0)
        case .health:
            let b = model.battery
            let f = Wear.forecast(battery: b, history: model.history.capacity)
            let when = f.date.map { " · 80% around \($0.formatted(.dateTime.month(.abbreviated).year()))" } ?? ""
            return "\(b.maxCapacityPercent)% maximum capacity, \(b.cycleCount) cycles\(when)"
        }
    }

    private func row(_ v: Vital) -> some View {
        HStack(spacing: 10) {
            SymbolTile(symbol: v.symbol, size: 26, tint: v.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(v.rawValue).font(.system(size: 13, weight: .medium))
                Text(summary(v)).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            Sparkline(values: v == .health ? capacitySeries().map { Double($0.cap) } : series(v, buckets()).compactMap { $0 }, color: v.tint)
                .frame(width: 90, height: 24)
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func detail(_ v: Vital) -> some View {
        let b = buckets()
        let before = compare ? buckets(offsetDays: period.days) : []
        Section {
            HStack {
                Button { withAnimation { open = nil } } label: { Label("Battery Health", systemImage: "chevron.left") }.buttonStyle(.borderless)
                Spacer()
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(v.rawValue).font(.title2.bold())
                Text(summary(v)).foregroundStyle(.secondary)
            }
            switch v {
            case .temperature:
                RangeBarsChart(ranges: b.map { hs in
                    let t = hs.filter { $0.tN > 0 }
                    guard !t.isEmpty else { return nil }
                    return (Double(t.map(\.tMin).min()!), Double(t.map(\.tMax).max()!), Double(t.reduce(Float(0)) { $0 + $1.tSum } / t.reduce(Float(0)) { $0 + $1.tN }))
                }, threshold: 38, height: 160)
                let warm = b.flatMap { $0 }.filter { $0.tMax >= 38 }.count
                Text("The dashed line is 38 °C, where charging slows down and wear adds up. \(warm == 0 ? "The battery didn't get that warm." : "It spent about \(warm) hour\(warm == 1 ? "" : "s") that warm.")")
                    .font(.callout).foregroundStyle(.secondary)
            case .charge:
                LineChart(values: series(.charge, b), before: compare ? series(.charge, before) : [], color: v.tint, range: 0...100, height: 160, unit: "%")
            case .power:
                LineChart(values: series(.power, b), before: compare ? series(.power, before) : [], color: v.tint, height: 160, unit: " W")
                if compare { delta(series(.power, b), series(.power, before), unit: "W", higherIsWorse: true) }
            case .voltage:
                LineChart(values: series(.voltage, b), before: compare ? series(.voltage, before) : [], color: v.tint, height: 160, unit: " V")
            case .health:
                let caps = capacitySeries()
                LineChart(values: caps.map { Double($0.cap) }, color: v.tint, height: 160, unit: "%")
                HStack {
                    statBox("Maximum Capacity", "\(model.battery.maxCapacityPercent)%")
                    statBox("Capacity Change", caps.count > 1 ? "\(Int(caps.last!.cap) - Int(caps.first!.cap)) points" : "—")
                    statBox("Cycles Added", caps.count > 1 ? "+\(caps.last!.cycles - caps.first!.cycles)" : "—")
                }
                Text("Read once a day and never thrown away, so a year from now you can see how the battery has worn.").font(.callout).foregroundStyle(.secondary)
                let f = Wear.forecast(battery: model.battery, history: model.history.capacity)
                VStack(alignment: .leading, spacing: 4) {
                    Label("Wear forecast", systemImage: "calendar.badge.clock").font(.headline)
                    if let d = f.date, (f.cyclesLeft ?? 0) > 0 {
                        Text("\(f.confident ? "" : "Roughly ")\(d.formatted(.dateTime.month(.wide).year())): when maximum capacity should reach 80%, about \(f.cyclesLeft!) cycles from now.")
                    } else if f.cyclesLeft == 0 {
                        Text("Maximum capacity has reached 80%, where Apple suggests a battery service.")
                    }
                    Text(f.basis).font(.callout).foregroundStyle(.secondary)
                    Text("Keeping a charge limit and avoiding heat pushes this date further out.").font(.callout).foregroundStyle(.secondary)
                }
            }
            if compare && v != .health { Text("The dashed line is the period before.").font(.caption).foregroundStyle(.secondary) }
        }
        if v == .temperature || v == .power {
            Section("Through the day") {
                let hrs = b.flatMap { $0 }
                let values: [Double] = (0..<24).map { hour in
                    let hs = hrs.filter { Calendar.current.component(.hour, from: HistoryStore.hourDate($0.h)) == hour }
                    if v == .temperature { let n = hs.reduce(Float(0)) { $0 + $1.tN }; return n > 0 ? Double(hs.reduce(Float(0)) { $0 + $1.tSum } / n) : 0 }
                    let n = hs.reduce(Float(0)) { $0 + $1.wN }; return n > 0 ? Double(hs.reduce(Float(0)) { $0 + $1.wSum } / n) : 0
                }
                HourOfDayChart(values: values, unit: v == .temperature ? "°" : " W")
                if let peak = values.indices.max(by: { values[$0] < values[$1] }), values[peak] > 0 {
                    Text(String(format: v == .temperature ? "Warmest around %02d:00." : "Works hardest around %02d:00.", peak)).font(.callout).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func statBox(_ t: String, _ v: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(t).font(.caption).foregroundStyle(.secondary)
            Text(v).font(.system(size: 20, weight: .semibold, design: .rounded))
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func delta(_ a: [Double?], _ b: [Double?], unit: String, higherIsWorse: Bool) -> some View {
        let x = a.compactMap { $0 }, y = b.compactMap { $0 }
        if !x.isEmpty, !y.isEmpty {
            let d = x.reduce(0, +) / Double(x.count) - y.reduce(0, +) / Double(y.count)
            Text(String(format: "%@%.1f %@ on average compared with before", d >= 0 ? "+" : "", d, unit))
                .foregroundStyle((d > 0) == higherIsWorse ? Theme.orange : Theme.green).font(.callout)
        }
    }
}
