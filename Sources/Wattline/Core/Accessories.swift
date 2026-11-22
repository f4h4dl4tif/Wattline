import AppKit
import CoreAudio
import GameController
import IOKit

struct Accessory: Identifiable, Equatable {
    enum Kind: String { case airpods, airpodsPro, airpodsMax, beats, headphones, keyboard, mouse, trackpad, controller, other }
    struct Part: Equatable, Identifiable { var label: String; var level: Int; var id: String { label } }

    var id: String
    var name: String
    var model: String?
    var kind: Kind
    var parts: [Part]
    var seen = Date()

    /// For low-battery alerts: AirPods go by the lower earbud, never the case.
    var lowest: Int? {
        let buds = parts.filter { $0.label != "Case" }
        return (buds.isEmpty ? parts : buds).map(\.level).min()
    }
    var isEarbuds: Bool { [.airpods, .airpodsPro, .beats].contains(kind) && parts.count > 1 }

    var symbol: String {
        switch kind {
        case .airpods: "airpods"
        case .airpodsPro: "airpodspro"
        case .airpodsMax: "airpodsmax"
        case .beats: "beats.earphones"
        case .headphones: "headphones"
        case .keyboard: "keyboard"
        case .mouse: "magicmouse"
        case .trackpad: "rectangle.and.hand.point.up.left"
        case .controller: "gamecontroller"
        case .other: "dot.radiowaves.left.and.right"
        }
    }

    static func kind(name: String, minor: String?) -> Kind {
        let n = name.lowercased(), m = (minor ?? "").lowercased()
        if n.contains("airpods max") { return .airpodsMax }
        if n.contains("airpods pro") { return .airpodsPro }
        if n.contains("airpods") { return .airpods }
        if n.contains("beats") || n.contains("powerbeats") { return .beats }
        if n.contains("keyboard") || m.contains("keyboard") { return .keyboard }
        if n.contains("trackpad") || m.contains("trackpad") { return .trackpad }
        if n.contains("mouse") || m.contains("mouse") { return .mouse }
        if m.contains("gamepad") || n.contains("controller") { return .controller }
        if m.contains("headphones") || m.contains("headset") { return .headphones }
        return .other
    }
}

/// Reads what macOS already knows about accessories, without talking to them.
/// Changes arrive from Core Audio (headphones) and the I/O Registry (Magic accessories), so nothing is polled.
final class AccessoryMonitor {
    var onChange: (([Accessory], _ newlyConnected: [Accessory]) -> Void)?
    private(set) var accessories: [Accessory] = []
    private var hidNotify: IONotificationPortRef?
    private var hidIterators: [io_iterator_t] = []
    private var debounce: DispatchWorkItem?
    private let queue = DispatchQueue(label: "accessories", qos: .utility)

    func start() {
        // Headphones come and go as audio devices.
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main) { [weak self] _, _ in self?.refreshSoon(delay: 2.5) }

        // Magic accessories as HID battery services.
        hidNotify = IONotificationPortCreate(kIOMainPortDefault)
        if let port = hidNotify {
            CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(port).takeUnretainedValue(), .defaultMode)
            let ctx = Unmanaged.passUnretained(self).toOpaque()
            for type in [kIOFirstMatchNotification, kIOTerminatedNotification] {
                var it: io_iterator_t = 0
                IOServiceAddMatchingNotification(port, type, IOServiceMatching("AppleDeviceManagementHIDEventService"), { ctx, it in
                    while case let o = IOIteratorNext(it), o != 0 { IOObjectRelease(o) }
                    guard let ctx else { return }
                    Unmanaged<AccessoryMonitor>.fromOpaque(ctx).takeUnretainedValue().refreshSoon(delay: 1)
                }, ctx, &it)
                while case let o = IOIteratorNext(it), o != 0 { IOObjectRelease(o) }
                hidIterators.append(it)
            }
        }
        NotificationCenter.default.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] _ in self?.refreshSoon(delay: 0.5) }
        NotificationCenter.default.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] _ in self?.refreshSoon(delay: 0.5) }
        refresh()
    }

    func refreshSoon(delay: Double) {
        debounce?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.refresh() }
        debounce = w
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
    }

    func refresh() {
        let controllers: [Accessory] = GCController.controllers().compactMap { c in
            guard let b = c.battery else { return nil }
            return Accessory(id: "gc:\(c.vendorName ?? "controller")", name: c.vendorName ?? "Game Controller", kind: .controller,
                             parts: [.init(label: "", level: Int(b.batteryLevel * 100))])
        }
        queue.async { [weak self] in
            guard let self else { return }
            var list = Self.hidAccessories()
            for a in Self.bluetoothAccessories() where !list.contains(where: { $0.name == a.name }) { list.append(a) }
            list += controllers
            DispatchQueue.main.async {
                let fresh = list.filter { n in !self.accessories.contains { $0.id == n.id } }
                self.accessories = list
                self.onChange?(list, fresh)
            }
        }
    }

    private static func hidAccessories() -> [Accessory] {
        var out: [Accessory] = []
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleDeviceManagementHIDEventService"), &it) == KERN_SUCCESS else { return out }
        defer { IOObjectRelease(it) }
        while case let o = IOIteratorNext(it), o != 0 {
            defer { IOObjectRelease(o) }
            func prop(_ k: String) -> Any? { IORegistryEntryCreateCFProperty(o, k as CFString, nil, 0)?.takeRetainedValue() }
            guard let pct = (prop("BatteryPercent") as? NSNumber)?.intValue else { continue }
            let name = (prop("Product") as? String) ?? "Accessory"
            let id = (prop("DeviceAddress") as? String) ?? (prop("SerialNumber") as? String) ?? name
            if out.contains(where: { $0.id == id }) { continue }
            out.append(Accessory(id: id, name: name, kind: Accessory.kind(name: name, minor: nil), parts: [.init(label: "", level: pct)]))
        }
        return out
    }

    /// AirPods, Beats and other headphones: from the system profiler's cached Bluetooth state.
    private static func bluetoothAccessories() -> [Accessory] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        p.arguments = ["SPBluetoothDataType", "-json", "-detailLevel", "basic"]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let bt = (root["SPBluetoothDataType"] as? [[String: Any]])?.first,
              let connected = bt["device_connected"] as? [[String: Any]] else { return [] }
        var out: [Accessory] = []
        for entry in connected {
            for (name, value) in entry {
                guard let d = value as? [String: Any] else { continue }
                func level(_ k: String) -> Int? { (d[k] as? String).flatMap { Int($0.replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces)) } }
                var parts: [Accessory.Part] = []
                if let l = level("device_batteryLevelLeft") { parts.append(.init(label: "Left", level: l)) }
                if let r = level("device_batteryLevelRight") { parts.append(.init(label: "Right", level: r)) }
                if let c = level("device_batteryLevelCase") { parts.append(.init(label: "Case", level: c)) }
                if let m = level("device_batteryLevelMain") ?? level("device_batteryLevel") { parts.append(.init(label: "", level: m)) }
                guard !parts.isEmpty else { continue }
                let minor = d["device_minorType"] as? String
                let id = (d["device_address"] as? String) ?? name
                var model: String? = d["device_productID"] as? String
                if let pid = model { model = Self.models[pid.lowercased()] }
                out.append(Accessory(id: id, name: name, model: model, kind: Accessory.kind(name: model ?? name, minor: minor), parts: parts))
            }
        }
        return out
    }

    /// A renamed accessory shows its model under your name for it.
    private static let models: [String: String] = [
        "0x2002": "AirPods", "0x200f": "AirPods (2nd generation)", "0x2013": "AirPods (3rd generation)", "0x2019": "AirPods 4",
        "0x201b": "AirPods 4", "0x200e": "AirPods Pro", "0x2014": "AirPods Pro (2nd generation)", "0x2024": "AirPods Pro (2nd generation)",
        "0x2027": "AirPods Pro 3", "0x200a": "AirPods Max", "0x201f": "AirPods Max", "0x200b": "Powerbeats Pro", "0x201d": "Powerbeats Pro 2",
        "0x2011": "Beats Studio Buds", "0x2012": "Beats Fit Pro", "0x2016": "Beats Studio Buds +", "0x2017": "Beats Studio Pro",
        "0x2009": "Beats Studio3", "0x2006": "Beats Solo3", "0x2025": "Beats Solo 4", "0x2010": "Beats Flex",
    ]
}
