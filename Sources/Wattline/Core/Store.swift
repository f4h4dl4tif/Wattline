import Foundation

/// A level change, recorded when macOS says the battery changed.
struct LevelPoint: Codable { var t: Int32; var p: UInt8; var c: Bool; var e: Bool }   // time, percent, charging, external power

/// A reading every five minutes.
struct Sample: Codable {
    var t: Int32                     // seconds since 2001
    var p: UInt8                     // percent
    var e: Bool                      // on external power
    var w: Float                     // W the Mac drew
    var a: Float                     // W from the charger
    var v: Float                     // V
    var k: Float                     // °C, 0 when unknown
    var apps: [Int32: Float]?        // app index → W (on battery only)
    var top: Int32?                  // the busiest app, plugged in or not (for "why is it warm")
    var tw: Float?                   // its watts
}

/// Everything about one hour, kept for as long as history is.
struct Hour: Codable {
    var h: Int32                     // hour start, hours since 2001
    var bat: Float = 0               // minutes on battery
    var ac: Float = 0                // minutes on the charger
    var used: Float = 0              // percent used on battery
    var lo: UInt8 = 100              // lowest level
    var tSum: Float = 0, tMin: Float = 0, tMax: Float = 0, tN: Float = 0
    var wSum: Float = 0, wMax: Float = 0, wN: Float = 0
    var aSum: Float = 0, aN: Float = 0
    var vMin: Float = 0, vMax: Float = 0
    var batW: Float = 0, batWN: Float = 0  // system power while on battery
    var apps: [Int32: Float] = [:]   // app index → watt-minutes on battery
}

struct AppRef: Codable, Hashable { var key: String; var name: String; var path: String?; var symbol: String?; var kind: ConsumerKind; var badge: Bool? }
struct CapacityDay: Codable { var d: Int32; var cap: UInt8; var cycles: Int32 }   // days since 2001
struct SleepRecord: Codable, Identifiable {
    var start: Date; var end: Date; var startPct: Int; var endPct: Int; var plugged: Bool
    var wakes: [WakeEvent]? = nil     // what woke it, when known
    var id: Date { start }
    var hours: Double { end.timeIntervalSince(start) / 3600 }
    var used: Int { max(0, startPct - endPct) }
    var perHour: Double { hours > 0.25 ? Double(used) / hours : 0 }
}

/// The history, on disk in Application Support. Nothing ever leaves the Mac.
final class HistoryStore {
    private struct File: Codable {
        var levels: [LevelPoint] = []
        var samples: [Sample] = []
        var hours: [Hour] = []
        var apps: [AppRef] = []
        var capacity: [CapacityDay] = []
        var sleeps: [SleepRecord] = []
    }
    private var f = File()
    private var appIndex: [String: Int32] = [:]
    private let url: URL
    private var dirty = false

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Wattline", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("history.json")
        if let data = try? Data(contentsOf: url), let file = try? JSONDecoder().decode(File.self, from: data) { f = file }
        for (i, a) in f.apps.enumerated() { appIndex[a.key] = Int32(i) }
    }

    static func now32() -> Int32 { Int32(Date().timeIntervalSinceReferenceDate) }
    static func date(_ t: Int32) -> Date { Date(timeIntervalSinceReferenceDate: TimeInterval(t)) }
    static func hourDate(_ h: Int32) -> Date { Date(timeIntervalSinceReferenceDate: TimeInterval(h) * 3600) }

    var levels: [LevelPoint] { f.levels }
    var samples: [Sample] { f.samples }
    var hours: [Hour] { f.hours }
    var capacity: [CapacityDay] { f.capacity }
    var sleeps: [SleepRecord] { f.sleeps }
    func app(_ i: Int32) -> AppRef? { i >= 0 && Int(i) < f.apps.count ? f.apps[Int(i)] : nil }
    func index(of key: String) -> Int32? { appIndex[key] }

    func index(for c: Consumer) -> Int32 {
        if let i = appIndex[c.id] {
            if f.apps[Int(i)].name != c.name { f.apps[Int(i)].name = c.name }
            return i
        }
        let i = Int32(f.apps.count)
        f.apps.append(AppRef(key: c.id, name: c.name, path: c.identity.bundlePath, symbol: c.identity.symbol, kind: c.identity.kind, badge: c.identity.terminalBadge ? true : nil))
        appIndex[c.id] = i
        return i
    }

    // MARK: Recording

    /// About 0.1 µs: one append, saved with the next sample.
    func recordLevel(_ s: BatteryState) {
        let p = LevelPoint(t: Self.now32(), p: UInt8(clamping: s.percent), c: s.isCharging, e: s.externalConnected)
        if let last = f.levels.last, last.p == p.p, last.c == p.c, last.e == p.e { return }
        f.levels.append(p); dirty = true
    }

    func recordSample(_ s: BatteryState, reading: EnergyReading?, intervalMinutes: Double) {
        let t = Self.now32()
        var apps: [Int32: Float]?
        if let reading, s.onBattery, reading.interval > 0 {
            var m: [Int32: Float] = [:]
            for c in reading.consumers.prefix(24) where c.watts >= 0.05 { m[index(for: c)] = Float(c.watts) }
            apps = m
        }
        let busiest = reading?.consumers.first { $0.watts >= 0.3 }
        let sample = Sample(t: t, p: UInt8(clamping: s.percent), e: s.externalConnected, w: Float(s.systemPower),
                            a: Float(s.adapterInput), v: Float(s.voltage), k: Float(s.temperature ?? 0), apps: apps,
                            top: busiest.map { index(for: $0) }, tw: busiest.map { Float($0.watts) })
        let previous = f.samples.last
        f.samples.append(sample)

        // Fold it into the hour.
        let h = t / 3600
        if f.hours.last?.h != h { f.hours.append(Hour(h: h, lo: sample.p)) }
        var hr = f.hours[f.hours.count - 1]
        let mins = Float(min(intervalMinutes, 10))
        if s.onBattery {
            hr.bat += mins
            if let prev = previous, !prev.e, prev.p > sample.p, t - prev.t < 1200 { hr.used += Float(prev.p - sample.p) }
            hr.batW += sample.w; hr.batWN += 1
            for (k, w) in apps ?? [:] { hr.apps[k, default: 0] += w * mins }
        } else { hr.ac += mins }
        hr.lo = min(hr.lo, sample.p)
        if sample.k > 0 {
            hr.tMin = hr.tN == 0 ? sample.k : min(hr.tMin, sample.k); hr.tMax = max(hr.tMax, sample.k)
            hr.tSum += sample.k; hr.tN += 1
        }
        if sample.w > 0 { hr.wSum += sample.w; hr.wN += 1; hr.wMax = max(hr.wMax, sample.w) }
        if sample.a > 0 { hr.aSum += sample.a; hr.aN += 1 }
        if sample.v > 0 { hr.vMin = hr.vMin == 0 ? sample.v : min(hr.vMin, sample.v); hr.vMax = max(hr.vMax, sample.v) }
        f.hours[f.hours.count - 1] = hr

        // Wear, read once a day and kept for good.
        let day = t / 86400
        if f.capacity.last?.d != day, s.hasBattery {
            f.capacity.append(CapacityDay(d: day, cap: UInt8(clamping: s.maxCapacityPercent), cycles: Int32(s.cycleCount)))
        }
        dirty = true
        prune()
        save()
    }

    func recordSleep(_ r: SleepRecord) {
        guard r.end.timeIntervalSince(r.start) > 600 else { return }
        f.sleeps.append(r)
        if f.sleeps.count > 60 { f.sleeps.removeFirst(f.sleeps.count - 60) }
        dirty = true; save()
    }

    func updateSleep(_ start: Date, wakes: [WakeEvent]) {
        guard let i = f.sleeps.firstIndex(where: { $0.start == start }) else { return }
        f.sleeps[i].wakes = wakes
        dirty = true; save()
    }

    private func prune() {
        let t = Self.now32()
        let twoDays = t - 2 * 86400
        if let i = f.samples.firstIndex(where: { $0.t >= twoDays }), i > 0 { f.samples.removeFirst(i) }
        let elevenDays = t - 11 * 86400
        if let i = f.levels.firstIndex(where: { $0.t >= elevenDays }), i > 0 { f.levels.removeFirst(i) }
        let keepHours = Int32(max(14, Prefs.shared.retentionDays) * 24)
        let cutoff = t / 3600 - keepHours
        if let i = f.hours.firstIndex(where: { $0.h >= cutoff }), i > 0 { f.hours.removeFirst(i) }
    }

    func save() {
        guard dirty else { return }
        dirty = false
        let file = f, url = url
        DispatchQueue.global(qos: .utility).async {
            if let data = try? JSONEncoder().encode(file) { try? data.write(to: url, options: .atomic) }
        }
    }

    // MARK: Export

    func exportCSV(perApp: Bool) -> String {
        let iso = ISO8601DateFormatter()
        if perApp {
            var rows = ["date,app,battery_minutes,watt_hours"]
            for (day, hrs) in Dictionary(grouping: f.hours, by: { $0.h / 24 }).sorted(by: { $0.key < $1.key }) {
                let bat = hrs.reduce(Float(0)) { $0 + $1.bat }
                var apps: [Int32: Float] = [:]
                for h in hrs { for (k, v) in h.apps { apps[k, default: 0] += v } }
                let total = max(apps.values.reduce(0, +), 0.0001)
                for (k, wm) in apps.sorted(by: { $0.value > $1.value }) {
                    let name = (app(k)?.name ?? "?").replacingOccurrences(of: ",", with: " ")
                    rows.append("\(iso.string(from: Self.hourDate(day * 24)).prefix(10)),\(name),\(String(format: "%.1f", bat * wm / total)),\(String(format: "%.3f", wm / 60))")
                }
            }
            return rows.joined(separator: "\n")
        }
        var rows = ["hour,minutes_on_battery,minutes_plugged_in,percent_used,lowest_level,avg_temp_c,max_temp_c,avg_power_w,max_power_w,avg_charger_w,min_voltage,max_voltage"]
        for h in f.hours {
            func r(_ x: Float) -> String { String(format: "%.2f", x) }
            rows.append([iso.string(from: Self.hourDate(h.h)), r(h.bat), r(h.ac), r(h.used), "\(h.lo)",
                         r(h.tN > 0 ? h.tSum / h.tN : 0), r(h.tMax), r(h.wN > 0 ? h.wSum / h.wN : 0), r(h.wMax),
                         r(h.aN > 0 ? h.aSum / h.aN : 0), r(h.vMin), r(h.vMax)].joined(separator: ","))
        }
        return rows.joined(separator: "\n")
    }

    func exportJSON() -> Data? {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]; enc.dateEncodingStrategy = .iso8601
        return try? enc.encode(f)
    }
}
