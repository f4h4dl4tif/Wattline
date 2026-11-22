import Foundation

struct LevelBar { var level: Int; var plugged: Bool; var start: Date }
struct DayUse: Identifiable { var day: Int32; var used: Double; var batteryMinutes: Double; var id: Int32 { day }
    var date: Date { HistoryStore.hourDate(day * 24) } }
struct AppUse: Identifiable { var ref: AppRef; var index: Int32; var minutes: Double; var share: Double; var wattMinutes: Double; var id: Int32 { index } }

enum Period: String, CaseIterable, Identifiable {
    case day = "24H", week = "7D", twoWeeks = "14D", month = "30D", quarter = "3M", year = "1Y"
    var id: String { rawValue }
    var days: Int { switch self { case .day: 1; case .week: 7; case .twoWeeks: 14; case .month: 30; case .quarter: 90; case .year: 365 } }
}

enum PowerFilter: String, CaseIterable, Identifiable { case all = "All", battery = "On Battery", plugged = "Plugged In"; var id: String { rawValue } }

extension HistoryStore {
    /// Local-calendar day number for an hour record (days since 2001 in the user's time zone).
    static func localDay(_ h: Int32) -> Int32 {
        let offset = Int32(TimeZone.current.secondsFromGMT(for: hourDate(h)) / 3600)
        return (h + offset) / 24
    }
    static func localDayDate(_ d: Int32) -> Date {
        let utc = Date(timeIntervalSinceReferenceDate: TimeInterval(d) * 86400)
        return utc.addingTimeInterval(-TimeInterval(TimeZone.current.secondsFromGMT(for: utc)))
    }

    /// A bar every half hour for the last 24 hours, like iPhone's Battery settings.
    func levelBars(current: BatteryState) -> [LevelBar?] {
        let now = Date()
        let slot: TimeInterval = 1800
        let endSlot = (now.timeIntervalSinceReferenceDate / slot).rounded(.down) * slot
        let start = endSlot - 47 * slot
        var bars: [LevelBar?] = Array(repeating: nil, count: 48)
        let pts = levels
        var idx = 0
        var last: LevelPoint?
        for i in 0..<48 {
            let slotStart = start + Double(i) * slot, slotEnd = slotStart + slot
            var plugged = false
            var lowest: UInt8?
            while idx < pts.count, Double(pts[idx].t) < slotEnd {
                let p = pts[idx]
                if Double(p.t) >= slotStart { plugged = plugged || p.e; lowest = min(lowest ?? p.p, p.p) }
                last = p; idx += 1
            }
            if let l = last {
                plugged = plugged || l.e
                bars[i] = LevelBar(level: Int(lowest ?? l.p), plugged: plugged,
                                   start: Date(timeIntervalSinceReferenceDate: slotStart))
            }
        }
        bars[47] = LevelBar(level: current.percent, plugged: current.externalConnected, start: Date(timeIntervalSinceReferenceDate: endSlot))
        return bars
    }

    func days(_ count: Int) -> [DayUse] {
        let today = Self.localDay(Int32(Date().timeIntervalSinceReferenceDate / 3600))
        var map: [Int32: (Double, Double)] = [:]
        for h in hours {
            let d = Self.localDay(h.h)
            guard d > today - Int32(count) else { continue }
            var v = map[d] ?? (0, 0); v.0 += Double(h.used); v.1 += Double(h.bat); map[d] = v
        }
        return (0..<Int32(count)).map { i in
            let d = today - Int32(count) + 1 + i
            return DayUse(day: d, used: map[d]?.0 ?? 0, batteryMinutes: map[d]?.1 ?? 0)
        }
    }

    func hours(lastDays days: Int, offsetDays: Int = 0) -> [Hour] {
        let now = Int32(Date().timeIntervalSinceReferenceDate / 3600)
        let hi = now - Int32(offsetDays * 24), lo = hi - Int32(days * 24)
        return hours.filter { $0.h > lo && $0.h <= hi }
    }

    func hours(onLocalDay day: Int32) -> [Hour] { hours.filter { Self.localDay($0.h) == day } }

    /// Where it went: battery time per app, as each app's share of the time on battery.
    func appUse(in hrs: [Hour]) -> [AppUse] {
        var wm: [Int32: Float] = [:]
        var bat: Float = 0
        for h in hrs { bat += h.bat; for (k, v) in h.apps { wm[k, default: 0] += v } }
        let total = wm.values.reduce(0, +)
        guard total > 0 else { return [] }
        return wm.compactMap { k, v in
            guard let ref = app(k) else { return nil }
            let share = Double(v / total)
            return AppUse(ref: ref, index: k, minutes: Double(bat) * share, share: share, wattMinutes: Double(v))
        }.sorted { $0.wattMinutes > $1.wattMinutes }
    }

    /// An app's average power at each hour of the day, over every day it was measured.
    func throughTheDay(app index: Int32?, in hrs: [Hour]) -> [Double] {
        var sum = [Double](repeating: 0, count: 24), n = [Double](repeating: 0, count: 24)
        let cal = Calendar.current
        for h in hrs where h.bat > 0 {
            let hour = cal.component(.hour, from: Self.hourDate(h.h))
            let v: Float = index.map { (h.apps[$0] ?? 0) / max(h.bat, 1) } ?? (h.batWN > 0 ? h.batW / h.batWN : 0)
            sum[hour] += Double(v); n[hour] += 1
        }
        return (0..<24).map { n[$0] > 0 ? sum[$0] / n[$0] : 0 }
    }
}
