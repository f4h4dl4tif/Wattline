import Foundation
import IOKit
import IOKit.ps

/// One reading of the internal battery and the charger, straight from the battery controller.
struct BatteryState: Equatable {
    var hasBattery = false
    var percent = 0
    var isCharging = false
    var externalConnected = false
    var fullyCharged = false
    /// Minutes, nil while macOS is still working it out.
    var minutesToEmpty: Int?
    var minutesToFull: Int?
    var voltage: Double = 0          // V
    var amperage: Double = 0         // A, negative when discharging
    var systemPower: Double = 0      // W the whole Mac draws
    var adapterInput: Double = 0     // W coming from the charger
    var adapterRating: Int = 0       // W the charger can give
    var adapterName: String?
    var cycleCount = 0
    var maxCapacityPercent = 100     // health: full charge capacity vs design
    var designCapacity = 0           // mAh
    var fullChargeCapacity = 0       // mAh
    var remainingCapacity = 0        // mAh
    var temperature: Double?         // °C
    var notChargingReason = 0
    var slowChargingReason = 0
    var lowPowerMode = false

    var onBattery: Bool { hasBattery && !externalConnected }
    /// Plugged in but holding its charge (a charge limit, Optimized Charging, or simply full).
    var holding: Bool { externalConnected && !isCharging }

    var condition: String {
        if !hasBattery { return "—" }
        if maxCapacityPercent >= 80 { return "Normal" }
        return "Service Recommended"
    }

    var batteryPowerWatts: Double { voltage * amperage }   // + in, − out

    var powerSource: String {
        guard hasBattery else { return "Power Adapter" }
        if !externalConnected { return "Battery" }
        if isCharging { return "Power Adapter" }
        return fullyCharged || percent >= 100 ? "Power Adapter · Charged" : "Power Adapter · Not Charging"
    }
}

/// Reads AppleSmartBattery and listens for macOS's own power-source notifications, so nothing is polled.
final class BatteryReader {
    private var runLoopSource: CFRunLoopSource?
    var onChange: (() -> Void)?

    init() {}

    func startListening() {
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        guard let src = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            Unmanaged<BatteryReader>.fromOpaque(ctx).takeUnretainedValue().onChange?()
        }, ctx)?.takeRetainedValue() else { return }
        runLoopSource = src
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .defaultMode)
    }

    func read() -> BatteryState {
        var s = BatteryState()
        s.lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return s }
        defer { IOObjectRelease(service) }
        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let d = props?.takeRetainedValue() as? [String: Any] else { return s }

        s.hasBattery = (d["BatteryInstalled"] as? Bool) ?? true
        s.percent = Self.int(d["CurrentCapacity"]) ?? 0
        let maxPct = Self.int(d["MaxCapacity"]) ?? 100
        if maxPct > 0 && maxPct != 100 { s.percent = s.percent * 100 / maxPct }
        s.isCharging = (d["IsCharging"] as? Bool) ?? false
        s.externalConnected = (d["ExternalConnected"] as? Bool) ?? false
        s.fullyCharged = (d["FullyCharged"] as? Bool) ?? false
        s.cycleCount = Self.int(d["CycleCount"]) ?? 0
        s.voltage = Double(Self.int(d["Voltage"]) ?? 0) / 1000
        s.amperage = Double(Self.signed(d["Amperage"]) ?? 0) / 1000

        let toEmpty = Self.int(d["AvgTimeToEmpty"]) ?? 65535
        let toFull = Self.int(d["AvgTimeToFull"]) ?? 65535
        s.minutesToEmpty = (toEmpty > 0 && toEmpty < 65535 && !s.externalConnected) ? toEmpty : nil
        s.minutesToFull = (toFull > 0 && toFull < 65535 && s.isCharging) ? toFull : nil

        let bd = d["BatteryData"] as? [String: Any] ?? [:]
        s.designCapacity = Self.int(bd["DesignCapacity"]) ?? Self.int(d["DesignCapacity"]) ?? 0
        s.fullChargeCapacity = Self.int(bd["AppleRawMaxCapacity"]) ?? Self.int(d["AppleRawMaxCapacity"]) ?? 0
        s.remainingCapacity = Self.int(bd["AppleRawCurrentCapacity"]) ?? Self.int(d["AppleRawCurrentCapacity"]) ?? 0
        if s.designCapacity > 0 && s.fullChargeCapacity > 0 {
            s.maxCapacityPercent = min(100, Int((Double(s.fullChargeCapacity) / Double(s.designCapacity) * 100).rounded()))
        }

        let telemetry = d["PowerTelemetryData"] as? [String: Any] ?? [:]
        let load = Double(Self.int(telemetry["SystemLoad"]) ?? 0) / 1000
        s.systemPower = load > 0 ? load : max(0, -s.voltage * s.amperage)
        s.adapterInput = Double(Self.int(telemetry["SystemPowerIn"]) ?? 0) / 1000

        if let adapter = d["AdapterDetails"] as? [String: Any] {
            s.adapterRating = Self.int(adapter["Watts"]) ?? 0
            s.adapterName = adapter["Name"] as? String
        }
        if let charger = d["ChargerData"] as? [String: Any] {
            s.notChargingReason = Self.int(charger["NotChargingReason"]) ?? 0
            s.slowChargingReason = Self.int(charger["SlowChargingReason"]) ?? 0
        }
        if let t = d["Temperature"].flatMap(Self.int), t > 0 {
            s.temperature = Double(t) / 100
        } else {
            s.temperature = SMC.shared.batteryTemperature()
        }
        return s
    }

    private static func int(_ v: Any?) -> Int? {
        if let n = v as? NSNumber { return n.intValue }
        return v as? Int
    }
    /// The registry stores signed values as unsigned 64-bit numbers.
    private static func signed(_ v: Any?) -> Int? {
        guard let n = v as? NSNumber else { return nil }
        return Int(truncatingIfNeeded: n.uint64Value)
    }
}

enum Fmt {
    /// "4:50", or "32m" under an hour.
    static func duration(minutes m: Double, short: Bool = false) -> String {
        let total = max(0, Int(m.rounded()))
        if total < 60 { return "\(total)m" }
        return short && total % 60 == 0 ? "\(total / 60)h" : String(format: "%d:%02d", total / 60, total % 60)
    }
    static func hoursMinutes(_ minutes: Double) -> String {
        let t = max(0, Int(minutes.rounded()))
        if t < 60 { return "\(t)m" }
        return t % 60 == 0 ? "\(t / 60)h" : "\(t / 60)h \(t % 60)m"
    }
    static func watts(_ w: Double) -> String {
        if w < 0.1 { return "<0.1 W" }
        return w < 10 ? String(format: "%.1f W", w) : String(format: "%.0f W", w)
    }
    static func spokenDuration(minutes: Double) -> String {
        let t = max(0, Int(minutes.rounded()))
        let h = t / 60, m = t % 60
        var parts: [String] = []
        if h > 0 { parts.append("\(h) hour\(h == 1 ? "" : "s")") }
        if m > 0 || h == 0 { parts.append("\(m) minute\(m == 1 ? "" : "s")") }
        return parts.joined(separator: " ")
    }
}
