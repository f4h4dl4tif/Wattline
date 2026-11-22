import AppKit
import Carbon.HIToolbox
import EventKit
import ServiceManagement
import UserNotifications
import ObjectiveC

// MARK: - Low Power Mode

enum LowPower {
    /// Uses the installer's one-line sudo rule when it's there, so there's no password; otherwise macOS asks once.
    /// `prompt: false` never asks for a password: used for automatic switching.
    static func set(_ on: Bool, prompt: Bool = true, completion: @escaping (Bool) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let arg = on ? "1" : "0"
            var ok = run("/usr/bin/sudo", ["-n", "/usr/bin/pmset", "-a", "lowpowermode", arg]) == 0
            if !ok && prompt {
                let script = "do shell script \"/usr/bin/pmset -a lowpowermode \(arg)\" with administrator privileges"
                ok = run("/usr/bin/osascript", ["-e", script]) == 0
            }
            DispatchQueue.main.async { completion(ok) }
        }
    }

    @discardableResult
    static func run(_ path: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run(); p.waitUntilExit(); return p.terminationStatus } catch { return -1 }
    }
}

// MARK: - Charge limit (macOS's own, from 26.4 on Apple silicon)

/// Talks to PowerUI's smart-charge client, the same one System Settings › Battery › Charge Limit uses.
/// Looked up at runtime and every selector checked first, so on a Mac without it nothing breaks.
final class ChargeLimit {
    static let shared = ChargeLimit()
    private let client: NSObject?
    private let lock = NSLock()
    private let selAvailable = NSSelectorFromString("availableChargeLimitsWithError:")
    private let selGet = NSSelectorFromString("getMCLLimitWithError:")
    private let selSet = NSSelectorFromString("setMCLLimit:error:")

    private init() {
        let initSel = NSSelectorFromString("initWithClientName:")
        guard dlopen("/System/Library/PrivateFrameworks/PowerUI.framework/PowerUI", RTLD_LAZY) != nil,
              let type = NSClassFromString("PowerUISmartChargeClient") as? NSObject.Type,
              [selAvailable, selGet, selSet, initSel].allSatisfy(type.instancesRespond(to:)),
              let imp = class_getMethodImplementation(type, initSel),
              let allocated = type.perform(NSSelectorFromString("alloc"))?.takeUnretainedValue()
        else { client = nil; return }
        typealias Init = @convention(c) (AnyObject, Selector, NSString) -> NSObject?
        client = unsafeBitCast(imp, to: Init.self)(allocated, initSel, "Wattline")
    }

    func levels() -> [Int] {
        guard let client, let imp = client.method(for: selAvailable) else { return [] }
        typealias F = @convention(c) (NSObject, Selector, UnsafeMutablePointer<NSError?>) -> NSArray?
        var err: NSError?
        lock.lock(); defer { lock.unlock() }
        let arr = unsafeBitCast(imp, to: F.self)(client, selAvailable, &err) as? [NSNumber]
        return (arr ?? []).map(\.intValue).filter { (1...100).contains($0) }.sorted()
    }

    /// 100 when there's no limit.
    func current() -> Int? {
        guard let client, let imp = client.method(for: selGet) else { return nil }
        typealias F = @convention(c) (NSObject, Selector, UnsafeMutablePointer<NSError?>) -> UInt8
        var err: NSError?
        lock.lock(); defer { lock.unlock() }
        let v = unsafeBitCast(imp, to: F.self)(client, selGet, &err)
        return err == nil && (1...100).contains(v) ? Int(v) : nil
    }

    @discardableResult
    func set(_ level: Int) -> Bool {
        guard let client, levels().contains(level), let imp = client.method(for: selSet) else { return false }
        typealias F = @convention(c) (NSObject, Selector, UInt8, UnsafeMutablePointer<NSError?>) -> Bool
        var err: NSError?
        lock.lock()
        let ok = unsafeBitCast(imp, to: F.self)(client, selSet, UInt8(level), &err)
        lock.unlock()
        return ok && err == nil && current() == level
    }
}

// MARK: - Chime

enum Chime {
    private static var plugIn: NSSound?
    private static var unplug: NSSound?

    static func play(pluggedIn: Bool) {
        let prefs = Prefs.shared
        switch prefs.chime {
        case .off: return
        case .unplugOnly where pluggedIn: return
        default: break
        }
        preview(prefs.chimeSound, pluggedIn: pluggedIn)
    }

    static func preview(_ sound: ChimeSound, pluggedIn: Bool) {
        if sound != .wattline { NSSound(named: NSSound.Name(sound.rawValue))?.play(); return }
        if pluggedIn {
            if plugIn == nil { plugIn = NSSound(data: tones([659.25, 987.77])) }
            plugIn?.stop(); plugIn?.play()
        } else {
            if unplug == nil { unplug = NSSound(data: tones([987.77, 659.25])) }
            unplug?.stop(); unplug?.play()
        }
    }

    /// Two soft notes, made on the fly: no audio files in the app.
    private static func tones(_ freqs: [Double]) -> Data {
        let rate = 44100.0, noteLen = 0.16, gap = 0.07
        var samples: [Int16] = []
        for (i, f) in freqs.enumerated() {
            let n = Int(rate * (noteLen + (i == freqs.count - 1 ? 0.22 : 0)))
            for s in 0..<n {
                let t = Double(s) / rate
                let attack = min(1, t / 0.012)
                let decay = exp(-t * (i == freqs.count - 1 ? 7 : 11))
                let v = (sin(2 * .pi * f * t) + 0.25 * sin(4 * .pi * f * t)) * attack * decay * 0.22
                samples.append(Int16(max(-1, min(1, v)) * 32767))
            }
            if i < freqs.count - 1 { samples += [Int16](repeating: 0, count: Int(rate * gap)) }
        }
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        let bytes = UInt32(samples.count * 2)
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + bytes); d.append(contentsOf: Array("WAVEfmt ".utf8))
        u32(16); u16(1); u16(1); u32(44100); u32(88200); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(bytes)
        samples.withUnsafeBytes { d.append(contentsOf: $0) }
        return d
    }
}

// MARK: - Notifications

final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()
    var onQuit: ((String) -> Void)?
    var onLowPower: (() -> Void)?
    var onOpenPanel: (() -> Void)?
    private var categories: Set<UNNotificationCategory> = []
    private var bundled: Bool { Bundle.main.bundleIdentifier != nil && Bundle.main.bundlePath.hasSuffix(".app") }

    func setUp() {
        guard bundled else { return }
        UNUserNotificationCenter.current().delegate = self
        let lpm = UNNotificationCategory(identifier: "lowpower", actions: [UNNotificationAction(identifier: "lowpower", title: "Turn On Low Power Mode")], intentIdentifiers: [])
        categories.insert(lpm)
        UNUserNotificationCenter.current().setNotificationCategories(categories)
    }

    func requestPermission() {
        guard bundled else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// `quitKey`/`quitName` add a button that quits that app.
    func post(id: String, title: String, body: String, quitKey: String? = nil, quitName: String? = nil, lowPower: Bool = false) {
        guard bundled else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = nil
        if let quitKey, let quitName {
            let cat = "quit:\(quitKey)"
            let c = UNNotificationCategory(identifier: cat, actions: [UNNotificationAction(identifier: "quit", title: "Quit \(quitName)")], intentIdentifiers: [])
            if categories.insert(c).inserted { UNUserNotificationCenter.current().setNotificationCategories(categories) }
            content.categoryIdentifier = cat
            content.userInfo = ["quit": quitKey]
        } else if lowPower {
            content.categoryIdentifier = "lowpower"
        }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        DispatchQueue.main.async {
            switch response.actionIdentifier {
            case "quit": if let key = info["quit"] as? String { self.onQuit?(key) }
            case "lowpower": self.onLowPower?()
            default: self.onOpenPanel?()
            }
        }
        completionHandler()
    }
}

// MARK: - Calendar (only if the meeting warning is on)

final class MeetingWatch {
    private lazy var store = EKEventStore()

    var authorized: Bool { EKEventStore.authorizationStatus(for: .event) == .fullAccess }

    func requestAccess(_ done: @escaping (Bool) -> Void) {
        store.requestFullAccessToEvents { ok, _ in DispatchQueue.main.async { done(ok) } }
    }

    /// The next meeting starting within `lead` minutes: only when it starts and ends.
    func nextMeeting(within lead: Int) -> (start: Date, end: Date)? {
        guard authorized else { return nil }
        let now = Date()
        let pred = store.predicateForEvents(withStart: now, end: now.addingTimeInterval(TimeInterval(lead * 60)), calendars: nil)
        return store.events(matching: pred)
            .filter { !$0.isAllDay && $0.startDate > now }
            .min { $0.startDate < $1.startDate }
            .map { ($0.startDate, $0.endDate) }
    }

    /// Hours of timed events in a window, and whether any has a location (a sign you'll be away from your desk).
    /// Reads only times and whether a location is set, never titles, places or attendees.
    func load(from start: Date, to end: Date) -> (hours: Double, hasLocation: Bool, first: Date?) {
        guard authorized else { return (0, false, nil) }
        let events = store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: nil))
            .filter { !$0.isAllDay && $0.availability != .free }
        // Merge overlapping events so a double-booking isn't counted twice.
        var total = 0.0, cursor = Date.distantPast
        for e in events.sorted(by: { $0.startDate < $1.startDate }) {
            let s = max(e.startDate, cursor)
            if e.endDate > s { total += e.endDate.timeIntervalSince(s) }
            cursor = max(cursor, e.endDate)
        }
        let hasLoc = events.contains { !($0.location ?? "").trimmingCharacters(in: .whitespaces).isEmpty || $0.structuredLocation != nil }
        return (total / 3600, hasLoc, events.map(\.startDate).min())
    }
}

// MARK: - Keyboard shortcut (⌥⌘B)

final class HotKey {
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    static var action: (() -> Void)?

    func register() {
        unregister()
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { HotKey.action?() }
            return noErr
        }, 1, &spec, nil, &handler)
        let id = EventHotKeyID(signature: OSType(0x5754_4C4E), id: 1)
        RegisterEventHotKey(UInt32(kVK_ANSI_B), UInt32(cmdKey | optionKey), id, GetApplicationEventTarget(), 0, &ref)
    }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        if let handler { RemoveEventHandler(handler) }
        ref = nil; handler = nil
    }
}

enum LoginItem {
    static var enabled: Bool { SMAppService.mainApp.status == .enabled }
    static func set(_ on: Bool) {
        do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } } catch {}
    }
}
