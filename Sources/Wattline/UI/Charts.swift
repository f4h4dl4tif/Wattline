import SwiftUI

/// The level, all day: a bar every half hour. Green while plugged in, red when it ran low.
struct LevelBarsChart: View {
    var bars: [LevelBar?]
    var height: CGFloat = 76
    var body: some View {
        VStack(spacing: 3) {
            HStack(alignment: .top, spacing: 4) {
                GeometryReader { geo in
                    let n = CGFloat(bars.count)
                    let gap: CGFloat = 1.5
                    let w = (geo.size.width - gap * (n - 1)) / n
                    ZStack(alignment: .bottomLeading) {
                        ForEach([0.0, 0.5, 1.0], id: \.self) { f in
                            Rectangle().fill(Color.primary.opacity(0.1)).frame(height: 0.5).offset(y: -geo.size.height * f)
                        }
                        ForEach(bars.indices, id: \.self) { i in
                            if let b = bars[i] {
                                let color: Color = b.plugged ? Theme.green : (b.level <= 20 ? Theme.red : Color.primary.opacity(0.75))
                                RoundedRectangle(cornerRadius: 1).fill(color)
                                    .frame(width: w, height: max(1, geo.size.height * CGFloat(b.level) / 100))
                                    .offset(x: CGFloat(i) * (w + gap))
                            }
                        }
                    }
                }
                VStack(alignment: .leading) { Text("100%"); Spacer(); Text("50%"); Spacer(); Text("0%") }
                    .font(.system(size: 8)).foregroundStyle(.panelSecondary).frame(width: 24)
            }
            .frame(height: height)
            hourLabels.padding(.trailing, 28)
        }
        .accessibilityElement().accessibilityLabel("Battery level over the last 24 hours")
    }

    private var hourLabels: some View {
        GeometryReader { geo in
            let starts = bars.map { $0?.start }
            let cal = Calendar.current
            ForEach(starts.indices, id: \.self) { i in
                if let d = starts[i], cal.component(.minute, from: d) < 30, cal.component(.hour, from: d) % 6 == 0 {
                    Text(String(format: "%02d", cal.component(.hour, from: d)))
                        .font(.system(size: 8)).foregroundStyle(.panelSecondary)
                        .position(x: geo.size.width * (CGFloat(i) + 0.5) / CGFloat(bars.count), y: 5)
                }
            }
        }
        .frame(height: 10)
    }
}

/// Battery used each day, with the average marked.
struct DayBarsChart: View {
    var days: [DayUse]
    var selected: Int32?
    var height: CGFloat = 76
    var labelStyle: Date.FormatStyle = .dateTime.weekday(.narrow)
    var onSelect: ((Int32) -> Void)?

    var body: some View {
        let maxUsed = max(100, days.map(\.used).max() ?? 100)
        let active = days.filter { $0.used > 0 }
        let avg = active.isEmpty ? 0 : active.reduce(0) { $0 + $1.used } / Double(active.count)
        VStack(spacing: 3) {
            HStack(alignment: .top, spacing: 4) {
                GeometryReader { geo in
                    let n = CGFloat(days.count)
                    let gap: CGFloat = n > 40 ? 1 : 3
                    let w = max(1, (geo.size.width - gap * (n - 1)) / n)
                    ZStack(alignment: .bottomLeading) {
                        ForEach([0.0, 0.5, 1.0], id: \.self) { f in
                            Rectangle().fill(Color.primary.opacity(0.1)).frame(height: 0.5).offset(y: -geo.size.height * f)
                        }
                        ForEach(days.indices, id: \.self) { i in
                            let d = days[i]
                            RoundedRectangle(cornerRadius: min(2, w / 2))
                                .fill(selected == d.day ? Color.accentColor : (selected == nil ? Color.primary.opacity(0.7) : Color.primary.opacity(0.35)))
                                .frame(width: w, height: max(1, geo.size.height * CGFloat(d.used / maxUsed)))
                                .offset(x: CGFloat(i) * (w + gap))
                                .contentShape(Rectangle().size(width: w + gap, height: geo.size.height).offset(y: -geo.size.height))
                                .onTapGesture { onSelect?(d.day) }
                        }
                        if avg > 0 {
                            Rectangle().fill(Theme.orange.opacity(0.9)).frame(height: 1)
                                .offset(y: -geo.size.height * CGFloat(avg / maxUsed))
                        }
                    }
                }
                VStack(alignment: .leading) { Text("\(Int(maxUsed))%"); Spacer(); Text("\(Int(maxUsed / 2))%"); Spacer(); Text("0%") }
                    .font(.system(size: 8)).foregroundStyle(.panelSecondary).frame(width: 24)
            }
            .frame(height: height)
            if days.count <= 16 {
                HStack(spacing: 0) {
                    ForEach(days) { d in Text(d.date.formatted(labelStyle)).font(.system(size: 8)).foregroundStyle(.panelSecondary).frame(maxWidth: .infinity) }
                }
                .padding(.trailing, 28)
            }
        }
    }
}

struct Sparkline: View {
    var values: [Double]
    var color: Color = .accentColor
    var body: some View {
        GeometryReader { geo in
            let v = values.filter { $0.isFinite }
            if v.count > 1, let lo = v.min(), let hi = v.max() {
                let span = max(hi - lo, 0.0001)
                Path { p in
                    for (i, x) in v.enumerated() {
                        let pt = CGPoint(x: geo.size.width * CGFloat(i) / CGFloat(v.count - 1),
                                         y: geo.size.height * (1 - CGFloat((x - lo) / span)))
                        i == 0 ? p.move(to: pt) : p.addLine(to: pt)
                    }
                }
                .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            } else {
                Rectangle().fill(Color.primary.opacity(0.1)).frame(height: 1).frame(maxHeight: .infinity)
            }
        }
    }
}

/// A line with an optional dashed "before" line and a threshold.
struct LineChart: View {
    var values: [Double?]
    var before: [Double?] = []
    var color: Color = .accentColor
    var threshold: Double?
    var range: ClosedRange<Double>?
    var height: CGFloat = 140
    var unit: String = ""

    var body: some View {
        let all = (values + before).compactMap { $0 } + (threshold.map { [$0] } ?? [])
        let lo = range?.lowerBound ?? ((all.min() ?? 0) - 1)
        let hi = range?.upperBound ?? ((all.max() ?? 1) + 1)
        HStack(alignment: .top, spacing: 6) {
            GeometryReader { geo in
                ZStack {
                    ForEach([0.0, 0.5, 1.0], id: \.self) { f in
                        Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 0.5).position(x: geo.size.width / 2, y: geo.size.height * f)
                    }
                    if let threshold {
                        Path { p in
                            let y = geo.size.height * (1 - CGFloat((threshold - lo) / (hi - lo)))
                            p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: geo.size.width, y: y))
                        }.stroke(Theme.orange, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    }
                    if !before.isEmpty { line(before, in: geo.size, lo: lo, hi: hi).stroke(Color.secondary.opacity(0.6), style: StrokeStyle(lineWidth: 1.2, dash: [4, 3])) }
                    line(values, in: geo.size, lo: lo, hi: hi).stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                }
            }
            VStack(alignment: .leading) {
                Text(label(hi)); Spacer(); Text(label((hi + lo) / 2)); Spacer(); Text(label(lo))
            }.font(.system(size: 9)).foregroundStyle(.panelSecondary).frame(width: 40, alignment: .leading)
        }
        .frame(height: height)
    }

    private func label(_ v: Double) -> String { (abs(v) < 10 ? String(format: "%.1f", v) : String(format: "%.0f", v)) + unit }

    private func line(_ vals: [Double?], in size: CGSize, lo: Double, hi: Double) -> Path {
        Path { p in
            var started = false
            for (i, v) in vals.enumerated() {
                guard let v else { started = false; continue }
                let pt = CGPoint(x: size.width * (vals.count > 1 ? CGFloat(i) / CGFloat(vals.count - 1) : 0.5),
                                 y: size.height * (1 - CGFloat((v - lo) / max(hi - lo, 0.0001))))
                started ? p.addLine(to: pt) : p.move(to: pt)
                started = true
            }
        }
    }
}

/// Lowest to highest each day, the average marked, with a warning line.
struct RangeBarsChart: View {
    var ranges: [(lo: Double, hi: Double, avg: Double)?]
    var threshold: Double?
    var unit = "°"
    var height: CGFloat = 140
    var body: some View {
        let vals = ranges.compactMap { $0 }.flatMap { [$0.lo, $0.hi] } + (threshold.map { [$0] } ?? [])
        let lo = floor((vals.min() ?? 20) - 2), hi = ceil((vals.max() ?? 40) + 2)
        HStack(alignment: .top, spacing: 6) {
            GeometryReader { geo in
                let n = CGFloat(max(ranges.count, 1))
                let w = max(2, min(14, geo.size.width / n * 0.6))
                ZStack(alignment: .topLeading) {
                    if let threshold {
                        let y = geo.size.height * (1 - CGFloat((threshold - lo) / (hi - lo)))
                        Path { p in p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: geo.size.width, y: y)) }
                            .stroke(Theme.orange, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    }
                    ForEach(ranges.indices, id: \.self) { i in
                        if let r = ranges[i] {
                            let x = geo.size.width * (CGFloat(i) + 0.5) / n
                            let y1 = geo.size.height * (1 - CGFloat((r.hi - lo) / (hi - lo)))
                            let y2 = geo.size.height * (1 - CGFloat((r.lo - lo) / (hi - lo)))
                            Capsule().fill(Color.accentColor.opacity(0.45)).frame(width: w, height: max(w, y2 - y1)).position(x: x, y: (y1 + y2) / 2)
                            Circle().fill(Color.accentColor).frame(width: w * 0.8, height: w * 0.8)
                                .position(x: x, y: geo.size.height * (1 - CGFloat((r.avg - lo) / (hi - lo))))
                        }
                    }
                }
            }
            VStack(alignment: .leading) { Text("\(Int(hi))\(unit)"); Spacer(); Text("\(Int((hi + lo) / 2))\(unit)"); Spacer(); Text("\(Int(lo))\(unit)") }
                .font(.system(size: 9)).foregroundStyle(.panelSecondary).frame(width: 34, alignment: .leading)
        }
        .frame(height: height)
    }
}

/// 24 bars: every hour of the day, with the busiest one picked out.
struct HourOfDayChart: View {
    var values: [Double]
    var unit = " W"
    var height: CGFloat = 100
    var body: some View {
        let hi = max(values.max() ?? 1, 0.0001)
        let peak = values.firstIndex(of: values.max() ?? -1)
        VStack(spacing: 3) {
            GeometryReader { geo in
                let w = (geo.size.width - 23 * 2) / 24
                HStack(alignment: .bottom, spacing: 2) {
                    ForEach(0..<24, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(i == peak && values[i] > 0 ? Theme.orange : Color.accentColor.opacity(0.6))
                            .frame(width: w, height: max(1, geo.size.height * CGFloat(values[i] / hi)))
                    }
                }
                .frame(maxHeight: .infinity, alignment: .bottom)
            }
            .frame(height: height)
            HStack { Text("00"); Spacer(); Text("06"); Spacer(); Text("12"); Spacer(); Text("18"); Spacer(); Text("24") }
                .font(.system(size: 8)).foregroundStyle(.panelSecondary)
        }
    }
}
