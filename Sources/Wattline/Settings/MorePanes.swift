import AppKit
import SwiftUI

// MARK: - Why it's warm

/// Temperature over time, next to the busiest app at each moment.
struct WarmthPane: View {
    var model: AppModel
    @State private var hours = 24
    @State private var hover: Int?

    struct Spell: Identifiable { var start: Date; var end: Date; var peak: Double; var app: AppRef?; var charging: Bool; var id: Date { start } }

    var body: some View {
        let _ = model.historyVersion
        let cutoff = Int32(Date().timeIntervalSinceReferenceDate) - Int32(hours * 3600)
        let samples = model.history.samples.filter { $0.k > 0 && $0.t >= cutoff }
        let temps = samples.map { Double($0.k) }.sorted()
        let median = temps.isEmpty ? 30 : temps[temps.count / 2]
        let warm = max(34, median + 3)
        Form {
            Section {
                Picker("", selection: $hours) { Text("24 Hours").tag(24); Text("48 Hours").tag(48) }.pickerStyle(.segmented).labelsHidden()
                if samples.count < 3 {
                    Text("Readings arrive every five minutes. Come back in a little while to see the battery's temperature next to what was running.")
                        .foregroundStyle(.secondary)
                } else {
                    WarmChart(samples: samples, warm: warm, history: model.history, hover: $hover).frame(height: 190)
                    detail(samples, warm: warm)
                }
            } header: { Text("Temperature and the busiest app") } footer: {
                Text("The coloured strip is the busiest app at each reading; the dashed line is 38 °C, where charging slows and wear adds up. Plugged in or not, the busiest app is noted every five minutes.")
                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
            }
            let spells = Self.spells(samples, warm: warm, store: model.history)
            Section("Warm spells, above \(Int(warm.rounded()))°") {
                if spells.isEmpty { Text("The battery hasn't run warm in this period.").foregroundStyle(.secondary) }
                ForEach(spells.reversed()) { sp in
                    HStack(spacing: 10) {
                        if let a = sp.app { ConsumerIcon(identity: identity(a), size: 22) } else { SymbolTile(symbol: "thermometer.high", size: 22, tint: .red) }
                        VStack(alignment: .leading, spacing: 1) {
                            Text("\(sp.start.formatted(date: .omitted, time: .shortened))–\(sp.end.formatted(date: .omitted, time: .shortened)), up to \(Int(sp.peak.rounded()))°")
                            Text(explain(sp)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            let culprits = Self.culprits(samples, warm: warm, store: model.history)
            if !culprits.isEmpty {
                Section("Busiest while warm") {
                    ForEach(culprits, id: \.0.key) { ref, n in
                        HStack(spacing: 8) {
                            ConsumerIcon(identity: identity(ref), size: 18)
                            Text(ref.name)
                            Spacer()
                            Text("\(n * 5) min").monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func explain(_ sp: Spell) -> String {
        switch (sp.app, sp.charging) {
        case let (a?, true): return "Charging while \(a.name) was busiest"
        case let (a?, false): return "\(a.name) was the busiest app"
        case (nil, true): return "Charging, with no app especially busy"
        default: return "No app especially busy: the room, the sun or a closed lid may be why"
        }
    }

    @ViewBuilder
    private func detail(_ samples: [Sample], warm: Double) -> some View {
        let s = hover.flatMap { samples.indices.contains($0) ? samples[$0] : nil } ?? samples.last!
        let app = s.top.flatMap { model.history.app($0) }
        HStack(spacing: 8) {
            Text(HistoryStore.date(s.t).formatted(date: .omitted, time: .shortened)).monospacedDigit()
            Text("\(Int(Double(s.k).rounded()))°C").monospacedDigit().foregroundStyle(Double(s.k) >= warm ? Theme.red : .primary)
            if let app {
                ConsumerIcon(identity: identity(app), size: 14)
                Text("\(app.name), \(Fmt.watts(Double(s.tw ?? 0)))")
            } else { Text("nothing busy").foregroundStyle(.secondary) }
            Spacer()
            Text(s.e ? "plugged in" : "on battery").foregroundStyle(.secondary)
        }.font(.callout)
    }

    static func spells(_ samples: [Sample], warm: Double, store: HistoryStore) -> [Spell] {
        var out: [Spell] = []
        var run: [Sample] = []
        func flush() {
            guard run.count >= 2 else { run = []; return }
            let counts = Dictionary(grouping: run.compactMap(\.top), by: { $0 }).mapValues(\.count)
            let top = counts.max { $0.value < $1.value }?.key
            out.append(Spell(start: HistoryStore.date(run.first!.t), end: HistoryStore.date(run.last!.t), peak: Double(run.map(\.k).max()!),
                             app: top.flatMap { store.app($0) }, charging: run.filter(\.e).count * 2 > run.count))
            run = []
        }
        for s in samples {
            if Double(s.k) >= warm { if let l = run.last, s.t - l.t > 900 { flush() }; run.append(s) } else { flush() }
        }
        flush()
        return out
    }

    static func culprits(_ samples: [Sample], warm: Double, store: HistoryStore) -> [(AppRef, Int)] {
        let hot = samples.filter { Double($0.k) >= warm }.compactMap(\.top)
        return Dictionary(grouping: hot, by: { $0 }).compactMap { k, v in store.app(k).map { ($0, v.count) } }
            .sorted { $0.1 > $1.1 }.prefix(6).map { $0 }
    }
}

struct WarmChart: View {
    var samples: [Sample]
    var warm: Double
    var history: HistoryStore
    @Binding var hover: Int?

    var body: some View {
        let temps = samples.map { Double($0.k) }
        let lo = floor(min(temps.min() ?? 25, warm) - 2), hi = ceil(max(temps.max() ?? 40, 38) + 1)
        HStack(alignment: .top, spacing: 6) {
            GeometryReader { geo in
                let chartH = geo.size.height - 22
                let n = CGFloat(max(samples.count - 1, 1))
                let x: (Int) -> CGFloat = { geo.size.width * CGFloat($0) / n }
                let y: (Double) -> CGFloat = { chartH * (1 - CGFloat(($0 - lo) / (hi - lo))) }
                ZStack(alignment: .topLeading) {
                    Path { p in p.move(to: CGPoint(x: 0, y: y(38))); p.addLine(to: CGPoint(x: geo.size.width, y: y(38))) }
                        .stroke(Theme.orange, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    Rectangle().fill(Theme.red.opacity(0.07)).frame(height: max(0, y(warm))).offset(y: 0)
                    Path { p in
                        for (i, s) in samples.enumerated() {
                            let pt = CGPoint(x: x(i), y: y(Double(s.k)))
                            i == 0 ? p.move(to: pt) : p.addLine(to: pt)
                        }
                    }.stroke(Theme.red, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    // The busiest app at each reading.
                    HStack(spacing: 0) {
                        ForEach(samples.indices, id: \.self) { i in
                            let ref = samples[i].top.flatMap { history.app($0) }
                            Rectangle().fill(ref.map { Color(nsColor: IconCache.tint(for: identity($0))) } ?? Color.primary.opacity(0.08))
                        }
                    }
                    .frame(width: geo.size.width, height: 12).clipShape(RoundedRectangle(cornerRadius: 3))
                    .offset(y: chartH + 8)
                    if let h = hover, samples.indices.contains(h) {
                        Rectangle().fill(Color.primary.opacity(0.35)).frame(width: 1, height: geo.size.height).offset(x: x(h))
                        Circle().fill(Theme.red).frame(width: 7, height: 7).offset(x: x(h) - 3.5, y: y(Double(samples[h].k)) - 3.5)
                    }
                }
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let p): hover = max(0, min(samples.count - 1, Int((p.x / geo.size.width * n).rounded())))
                    case .ended: hover = nil
                    }
                }
            }
            VStack(alignment: .leading) { Text("\(Int(hi))°"); Spacer(); Text("\(Int((hi + lo) / 2))°"); Spacer(); Text("\(Int(lo))°"); Spacer().frame(height: 22) }
                .font(.system(size: 9)).foregroundStyle(.secondary).frame(width: 28, alignment: .leading)
        }
    }
}

// MARK: - Shortcuts & widgets

struct ShortcutsPane: View {
    private let app = "/Applications/Wattline.app/Contents/MacOS/Wattline"
    var body: some View {
        Form {
            Section {
                row("Get battery time left", "Run Shell Script", "\(app) --time-left")
                row("Get battery status as JSON", "Run Shell Script", "\(app) --status")
                row("Set charge limit (80, 85, 90, 95 or none)", "Open URLs", "wattline://charge-limit/80")
                row("Charge to full once", "Open URLs", "wattline://full-once")
                row("Quit the hungriest app", "Open URLs", "wattline://quit-hungriest")
                row("Low Power Mode on, off or toggle", "Open URLs", "wattline://low-power/toggle")
                row("Dim the screen by 20%", "Open URLs", "wattline://dim/20")
                row("Open the panel", "Open URLs", "wattline://open")
            } header: { Text("Shortcuts") } footer: {
                Text("In the Shortcuts app, add the action shown on the right and paste the text. “Get battery time left” returns text like 4:50 that later actions can use. The same commands work in Terminal, scripts and automation tools.")
                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
            }
            Section {
                Label("Right-click the desktop, choose Edit Widgets, and search for Wattline. Or open Notification Center and click Edit Widgets.", systemImage: "square.grid.2x2")
                Text("The widget shows time left and the three apps that used the most battery today, and refreshes with each reading.").foregroundStyle(.secondary)
            } header: { Text("Widgets") }
        }
        .formStyle(.grouped)
    }

    private func row(_ title: String, _ action: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack { Text(title); Spacer(); Text(action).font(.caption).foregroundStyle(.secondary) }
            HStack {
                Text(text).font(.system(.caption, design: .monospaced)).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.borderless).help("Copy")
            }
            .padding(6).background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
        }
    }
}
