import AppKit
import CoreGraphics
import IOKit

// MARK: - Screen brightness

/// The built-in display's brightness, and an estimate of what dimming it saves.
enum Brightness {
    private static let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
    private typealias Get = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
    private typealias Set = @convention(c) (UInt32, Float) -> Int32

    static var builtIn: CGDirectDisplayID? {
        var ids = [CGDirectDisplayID](repeating: 0, count: 8); var n: UInt32 = 0
        CGGetOnlineDisplayList(8, &ids, &n)
        return ids.prefix(Int(n)).first { CGDisplayIsBuiltin($0) != 0 && CGDisplayIsAsleep($0) == 0 }
    }

    /// 0…1, or nil without a built-in display that's on.
    static func level() -> Double? {
        guard let id = builtIn, let sym = dlsym(handle, "DisplayServicesGetBrightness") else { return nil }
        var b: Float = 0
        return unsafeBitCast(sym, to: Get.self)(id, &b) == 0 ? Double(b) : nil
    }

    static func set(_ v: Double) {
        guard let id = builtIn, let sym = dlsym(handle, "DisplayServicesSetBrightness") else { return }
        _ = unsafeBitCast(sym, to: Set.self)(id, Float(max(0.02, min(1, v))))
    }

    /// Backlight power at full brightness, from the screen's size (about 0.42 W per inch of diagonal).
    private static var maxBacklight: Double {
        guard let id = builtIn else { return 5 }
        let mm = CGDisplayScreenSize(id)
        let inches = (mm.width * mm.width + mm.height * mm.height).squareRoot() / 25.4
        return max(3, min(9, inches * 0.42))
    }

    /// The slider is perceptual; light output (and power) rises roughly with its square.
    static func backlightWatts(at b: Double) -> Double { maxBacklight * pow(max(0, b), 2.2) }

    /// Watts saved by dimming by `step` (0.2 = 20 points of the slider).
    static func savings(dimmingBy step: Double) -> (watts: Double, from: Double, to: Double)? {
        guard let b = level(), b > 0.05 else { return nil }
        let to = max(0.05, b - step)
        return (backlightWatts(at: b) - backlightWatts(at: to), b, to)
    }
}

// MARK: - What woke the Mac

struct WakeEvent: Codable, Hashable {
    var date: Date
    var dark: Bool          // a dark wake: the Mac woke without the screen
    var reason: String      // in plain words
}

enum WakeReasons {
    /// The reason the kernel gives for the latest wake, read from the registry: cheap, no logs involved.
    static func latest() -> String? {
        var size = 0
        if sysctlbyname("kern.wakereason", nil, &size, nil, 0) == 0, size > 1 {
            var buf = [CChar](repeating: 0, count: size)
            if sysctlbyname("kern.wakereason", &buf, &size, nil, 0) == 0 {
                let s = String(cString: buf)
                if !s.isEmpty { return s }
            }
        }
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        defer { IOObjectRelease(root) }
        return IORegistryEntryCreateCFProperty(root, "Wake Reason" as CFString, nil, 0)?.takeRetainedValue() as? String
    }

    static func wakeType() -> String? {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        defer { IOObjectRelease(root) }
        return IORegistryEntryCreateCFProperty(root, "Wake Type" as CFString, nil, 0)?.takeRetainedValue() as? String
    }

    /// Kernel wake codes, said plainly.
    static func describe(_ raw: String) -> String {
        let r = raw.lowercased()
        if r.contains("lid") { return "Opening the lid" }
        if r.contains("pwrbtn") || r.contains("power button") { return "The power button" }
        if r.contains("keyboard") || r.contains("spu") || r.contains("hid") || r.contains("trackpad") || r.contains("useractivity") { return "Keyboard, trackpad or mouse" }
        if r.contains("wifibt") || r.contains("wlan") || r.contains("wifi") || r.contains("arpt") || r.contains("network") { return "Wi‑Fi or Bluetooth (a network packet or an accessory)" }
        if r.contains("bluetooth") || r.contains("bt") { return "A Bluetooth accessory" }
        if r.contains("rtc") || r.contains("maintenance") || r.contains("sleep service") || r.contains("calendar") { return "A scheduled wake (Power Nap or maintenance)" }
        if r.contains("usb") || r.contains("xhc") { return "A USB device" }
        if r.contains("ac") && r.contains("attach") || r.contains("charger") || r.contains("adapter") { return "Plugging in the charger" }
        if r.contains("smc") || r.contains("pmu") || r.contains("battery") { return "The power controller (battery or charger event)" }
        if r.contains("notification") || r.contains("push") || r.contains("apsd") { return "A push notification" }
        return raw.split(separator: " ").prefix(3).joined(separator: " ")
    }

    /// Every wake between two dates, from macOS's power log. This reads the whole log, so it's only done on request.
    static func fromPowerLog(between start: Date, and end: Date) -> [WakeEvent] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        p.arguments = ["-g", "log"]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        var out: [WakeEvent] = []
        String(decoding: data, as: UTF8.self).enumerateLines { line, _ in
            guard line.count > 26, line.contains("Wake"), line.contains("due to") else { return }
            let parts = line.components(separatedBy: "\t").map { $0.trimmingCharacters(in: .whitespaces) }
            guard let d = f.date(from: String(line.prefix(25))), d >= start, d <= end else { return }
            let kind = parts.count > 1 ? parts[1] : line
            guard kind.hasPrefix("Wake") || kind.hasPrefix("DarkWake") else { return }
            let reason = line.components(separatedBy: "due to").last?.components(separatedBy: "Using").first?
                .trimmingCharacters(in: CharacterSet(charactersIn: " :/")) ?? ""
            out.append(WakeEvent(date: d, dark: kind.hasPrefix("DarkWake"), reason: describe(reason)))
        }
        return out
    }
}

// MARK: - Wear forecast

struct WearForecast {
    var date: Date?               // when maximum capacity reaches 80%
    var cyclesLeft: Int?
    var basis: String             // how it was worked out, in plain words
    var confident: Bool
}

enum Wear {
    /// From your own history when there's enough of it; otherwise from the wear so far per cycle.
    static func forecast(battery b: BatteryState, history: [CapacityDay]) -> WearForecast {
        guard b.hasBattery else { return WearForecast(date: nil, cyclesLeft: nil, basis: "No battery", confident: false) }
        if b.maxCapacityPercent <= 80 {
            return WearForecast(date: Date(), cyclesLeft: 0, basis: "Maximum capacity is already at \(b.maxCapacityPercent)%.", confident: true)
        }
        // Cycles per day, from history when it spans at least a week.
        var cyclesPerDay = 0.6
        var learnedRate = false
        if let first = history.first, let last = history.last, last.d - first.d >= 7, last.cycles > first.cycles {
            cyclesPerDay = Double(last.cycles - first.cycles) / Double(last.d - first.d)
            learnedRate = true
        }
        // Capacity lost per cycle: a fitted line over history (90+ days), else the wear so far.
        var perCycle: Double?
        var fitted = false
        if history.count >= 10, let first = history.first, let last = history.last, last.d - first.d >= 90, last.cycles - first.cycles >= 20 {
            let xs = history.map { Double($0.cycles) }, ys = history.map { Double($0.cap) }
            let mx = xs.reduce(0, +) / Double(xs.count), my = ys.reduce(0, +) / Double(ys.count)
            let num = zip(xs, ys).reduce(0) { $0 + ($1.0 - mx) * ($1.1 - my) }
            let den = xs.reduce(0) { $0 + ($1 - mx) * ($1 - mx) }
            if den > 0, num < 0 { perCycle = -num / den; fitted = true }
        }
        if perCycle == nil, b.cycleCount >= 30, b.maxCapacityPercent < 100 {
            perCycle = Double(100 - b.maxCapacityPercent) / Double(b.cycleCount)
        }
        // Apple rates these batteries for 80% at 1,000 cycles: the fallback when there's no wear yet.
        let rate = max(perCycle ?? 0.02, 0.005)
        let cycles = Int((Double(b.maxCapacityPercent) - 80) / rate)
        let days = Double(cycles) / max(cyclesPerDay, 0.05)
        let date = Calendar.current.date(byAdding: .day, value: Int(days), to: Date())
        let basis: String
        if fitted { basis = "From your battery's own wear over the last \(history.last!.d - history.first!.d) days." }
        else if perCycle != nil { basis = "From the wear so far (\(100 - b.maxCapacityPercent) points in \(b.cycleCount) cycles)" + (learnedRate ? " and how often you cycle it." : ", assuming about 0.6 cycles a day.") }
        else { basis = "Too little wear to measure yet, so this uses Apple's rating of 80% at about 1,000 cycles" + (learnedRate ? " and how often you cycle it." : ".") }
        return WearForecast(date: date, cyclesLeft: cycles, basis: basis, confident: fitted)
    }
}

// MARK: - Widget data

/// A tiny file the widget reads: the extension is sandboxed and can't measure apps itself.
struct WidgetSnapshot: Codable {
    struct App: Codable { var name: String; var path: String?; var symbol: String?; var minutes: Double; var watts: Double }
    var date: Date
    var percent: Int
    var charging: Bool
    var plugged: Bool
    var minutesLeft: Double
    var apps: [App]

    static var url: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Wattline", isDirectory: true).appendingPathComponent("widget.json")
    }
}
