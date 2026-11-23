import Foundation
import Observation

enum IconStyle: String, CaseIterable, Identifiable { case battery, ring, text; var id: String { rawValue }
    var label: String { switch self { case .battery: "Battery"; case .ring: "Ring"; case .text: "Text Only" } } }
enum BesideIcon: String, CaseIterable, Identifiable { case nothing, percentage, timeLeft, powerDraw; var id: String { rawValue }
    var label: String { switch self { case .nothing: "Nothing"; case .percentage: "Percentage"; case .timeLeft: "Time Left"; case .powerDraw: "Power Draw" } } }
enum ChargingMotion: String, CaseIterable, Identifiable { case flow, liquid, stripes, still; var id: String { rawValue }
    var label: String { switch self { case .flow: "Flow"; case .liquid: "Liquid"; case .stripes: "Stripes"; case .still: "None" } } }
enum LastFewMotion: String, CaseIterable, Identifiable { case pulse, calm, still; var id: String { rawValue }
    var label: String { switch self { case .pulse: "Slow Pulse"; case .calm: "Calm Liquid"; case .still: "None" } } }
enum HoldingMotion: String, CaseIterable, Identifiable { case breathe, beat, water, still; var id: String { rawValue }
    var label: String { switch self { case .breathe: "Breathing"; case .beat: "Heartbeat"; case .water: "Still Water"; case .still: "None" } } }
enum ChimeMode: String, CaseIterable, Identifiable { case off, both, unplugOnly; var id: String { rawValue }
    var label: String { switch self { case .off: "Off"; case .both: "Plug In and Unplug"; case .unplugOnly: "Unplug Only" } } }
enum ChimeSound: String, CaseIterable, Identifiable { case wattline, Glass, Pop, Purr, Tink, Bottle; var id: String { rawValue }
    var label: String { self == .wattline ? "Wattline" : rawValue } }
enum CardPosition: String, CaseIterable, Identifiable { case belowIcon, topCenter, topRight; var id: String { rawValue }
    var label: String { switch self { case .belowIcon: "Below the Icon"; case .topCenter: "Top Center"; case .topRight: "Top Right" } } }

/// Every setting, saved to UserDefaults as it changes.
@Observable
final class Prefs {
    static let shared = Prefs()
    @ObservationIgnored private let d = UserDefaults.standard

    // Menu bar
    var iconStyle: IconStyle { didSet { d.set(iconStyle.rawValue, forKey: "iconStyle") } }
    var besideIcon: BesideIcon { didSet { d.set(besideIcon.rawValue, forKey: "besideIcon") } }
    var percentInside: Bool { didSet { d.set(percentInside, forKey: "percentInside") } }
    var colorfulStates: Bool { didSet { d.set(colorfulStates, forKey: "colorfulStates") } }
    var chargingMotion: ChargingMotion { didSet { d.set(chargingMotion.rawValue, forKey: "chargingMotion") } }
    var lastFewMotion: LastFewMotion { didSet { d.set(lastFewMotion.rawValue, forKey: "lastFewMotion") } }
    var holdingMotion: HoldingMotion { didSet { d.set(holdingMotion.rawValue, forKey: "holdingMotion") } }

    // Panel
    var sliceCount: Int { didSet { d.set(sliceCount, forKey: "sliceCount") } }
    var hiddenApps: [String] { didSet { d.set(hiddenApps, forKey: "hiddenApps") } }
    var askBeforeQuit: Bool { didSet { d.set(askBeforeQuit, forKey: "askBeforeQuit") } }
    var showHistory: Bool { didSet { d.set(showHistory, forKey: "showHistory") } }
    var showInsights: Bool { didSet { d.set(showInsights, forKey: "showInsights") } }
    var showAccessories: Bool { didSet { d.set(showAccessories, forKey: "showAccessories") } }
    var showSleep: Bool { didSet { d.set(showSleep, forKey: "showSleep") } }
    var showReadings: Bool { didSet { d.set(showReadings, forKey: "showReadings") } }
    var showChargeLimit: Bool { didSet { d.set(showChargeLimit, forKey: "showChargeLimit") } }

    // Notifications
    var lowLevels: [Int] { didSet { d.set(lowLevels, forKey: "lowLevels") } }
    var notifyCharged: Bool { didSet { d.set(notifyCharged, forKey: "notifyCharged") } }
    var chargedLevel: Int { didSet { d.set(chargedLevel, forKey: "chargedLevel") } }
    var notifyAccessoryLow: Bool { didSet { d.set(notifyAccessoryLow, forKey: "notifyAccessoryLow") } }
    var accessoryLevel: Int { didSet { d.set(accessoryLevel, forKey: "accessoryLevel") } }
    var notifyRunaway: Bool { didSet { d.set(notifyRunaway, forKey: "notifyRunaway") } }
    var notifySleepDrain: Bool { didSet { d.set(notifySleepDrain, forKey: "notifySleepDrain") } }
    var suggestLowPower: Bool { didSet { d.set(suggestLowPower, forKey: "suggestLowPower") } }

    // Insights
    var meetingWarning: Bool { didSet { d.set(meetingWarning, forKey: "meetingWarning") } }
    var meetingLead: Int { didSet { d.set(meetingLead, forKey: "meetingLead") } }
    var insightMoreThanUsual: Bool { didSet { d.set(insightMoreThanUsual, forKey: "insightMoreThanUsual") } }
    var insightNewApp: Bool { didSet { d.set(insightNewApp, forKey: "insightNewApp") } }
    var insightsNotify: Bool { didSet { d.set(insightsNotify, forKey: "insightsNotify") } }

    // Charging
    var chime: ChimeMode { didSet { d.set(chime.rawValue, forKey: "chime") } }
    var chimeSound: ChimeSound { didSet { d.set(chimeSound.rawValue, forKey: "chimeSound") } }

    // Accessories
    var accessoryCard: Bool { didSet { d.set(accessoryCard, forKey: "accessoryCard") } }
    var cardPosition: CardPosition { didSet { d.set(cardPosition.rawValue, forKey: "cardPosition") } }
    var cardSeconds: Double { didSet { d.set(cardSeconds, forKey: "cardSeconds") } }

    // History
    var retentionDays: Int { didSet { d.set(retentionDays, forKey: "retentionDays") } }

    // Budgets: app key → battery minutes a day
    var budgets: [String: Int] { didSet { d.set(budgets, forKey: "budgets") } }

    // Automatic Low Power Mode
    var autoLPMBelow: Bool { didSet { d.set(autoLPMBelow, forKey: "autoLPMBelow") } }
    var autoLPMLevel: Int { didSet { d.set(autoLPMLevel, forKey: "autoLPMLevel") } }
    var autoLPMAfter: Bool { didSet { d.set(autoLPMAfter, forKey: "autoLPMAfter") } }
    var autoLPMAfterMinutes: Int { didSet { d.set(autoLPMAfterMinutes, forKey: "autoLPMAfterMinutes") } }
    var autoLPMOffWhenPlugged: Bool { didSet { d.set(autoLPMOffWhenPlugged, forKey: "autoLPMOffWhenPlugged") } }

    // Calendar-aware charging
    var calendarCharging: Bool { didSet { d.set(calendarCharging, forKey: "calendarCharging") } }
    var calendarHours: Int { didSet { d.set(calendarHours, forKey: "calendarHours") } }
    var calendarCountLocations: Bool { didSet { d.set(calendarCountLocations, forKey: "calendarCountLocations") } }

    // Warmth
    var warmBanner: Bool { didSet { d.set(warmBanner, forKey: "warmBanner") } }

    // Appearance: optional Liquid Glass panel and accessory card (macOS 26+)
    var glassTheme: Bool { didSet { d.set(glassTheme, forKey: "glassTheme") } }

    // General
    var hotkeyEnabled: Bool { didSet { d.set(hotkeyEnabled, forKey: "hotkeyEnabled") } }
    var tourDone: Bool { didSet { d.set(tourDone, forKey: "tourDone") } }

    private init() {
        d.register(defaults: [
            "iconStyle": "battery", "besideIcon": "percentage", "percentInside": false, "colorfulStates": true,
            "chargingMotion": "flow", "lastFewMotion": "pulse", "holdingMotion": "breathe",
            "sliceCount": 4, "askBeforeQuit": false, "showHistory": true, "showInsights": true, "showAccessories": true,
            "showSleep": true, "showReadings": true, "showChargeLimit": true,
            "lowLevels": [20, 10], "notifyCharged": false, "chargedLevel": 80, "notifyAccessoryLow": true, "accessoryLevel": 20,
            "notifyRunaway": true, "notifySleepDrain": true, "suggestLowPower": true,
            "meetingWarning": false, "meetingLead": 30, "insightMoreThanUsual": true, "insightNewApp": true, "insightsNotify": false,
            "chime": "off", "chimeSound": "wattline", "accessoryCard": true, "cardPosition": "belowIcon", "cardSeconds": 6.0,
            "retentionDays": 90, "autoLPMBelow": false, "autoLPMLevel": 20, "autoLPMAfter": false, "autoLPMAfterMinutes": 60,
            "autoLPMOffWhenPlugged": true, "calendarCharging": false, "calendarHours": 3, "calendarCountLocations": true, "warmBanner": true, "glassTheme": false, "hotkeyEnabled": true, "tourDone": false,
        ])
        iconStyle = IconStyle(rawValue: d.string(forKey: "iconStyle") ?? "") ?? .battery
        besideIcon = BesideIcon(rawValue: d.string(forKey: "besideIcon") ?? "") ?? .percentage
        percentInside = d.bool(forKey: "percentInside")
        colorfulStates = d.bool(forKey: "colorfulStates")
        chargingMotion = ChargingMotion(rawValue: d.string(forKey: "chargingMotion") ?? "") ?? .flow
        lastFewMotion = LastFewMotion(rawValue: d.string(forKey: "lastFewMotion") ?? "") ?? .pulse
        holdingMotion = HoldingMotion(rawValue: d.string(forKey: "holdingMotion") ?? "") ?? .breathe
        sliceCount = d.integer(forKey: "sliceCount")
        hiddenApps = d.stringArray(forKey: "hiddenApps") ?? []
        askBeforeQuit = d.bool(forKey: "askBeforeQuit")
        showHistory = d.bool(forKey: "showHistory")
        showInsights = d.bool(forKey: "showInsights")
        showAccessories = d.bool(forKey: "showAccessories")
        showSleep = d.bool(forKey: "showSleep")
        showReadings = d.bool(forKey: "showReadings")
        showChargeLimit = d.bool(forKey: "showChargeLimit")
        lowLevels = (d.array(forKey: "lowLevels") as? [Int]) ?? [20, 10]
        notifyCharged = d.bool(forKey: "notifyCharged")
        chargedLevel = d.integer(forKey: "chargedLevel")
        notifyAccessoryLow = d.bool(forKey: "notifyAccessoryLow")
        accessoryLevel = d.integer(forKey: "accessoryLevel")
        notifyRunaway = d.bool(forKey: "notifyRunaway")
        notifySleepDrain = d.bool(forKey: "notifySleepDrain")
        suggestLowPower = d.bool(forKey: "suggestLowPower")
        meetingWarning = d.bool(forKey: "meetingWarning")
        meetingLead = d.integer(forKey: "meetingLead")
        insightMoreThanUsual = d.bool(forKey: "insightMoreThanUsual")
        insightNewApp = d.bool(forKey: "insightNewApp")
        insightsNotify = d.bool(forKey: "insightsNotify")
        chime = ChimeMode(rawValue: d.string(forKey: "chime") ?? "") ?? .off
        chimeSound = ChimeSound(rawValue: d.string(forKey: "chimeSound") ?? "") ?? .wattline
        accessoryCard = d.bool(forKey: "accessoryCard")
        cardPosition = CardPosition(rawValue: d.string(forKey: "cardPosition") ?? "") ?? .belowIcon
        cardSeconds = d.double(forKey: "cardSeconds")
        retentionDays = d.integer(forKey: "retentionDays")
        budgets = (d.dictionary(forKey: "budgets") as? [String: Int]) ?? [:]
        autoLPMBelow = d.bool(forKey: "autoLPMBelow")
        autoLPMLevel = d.integer(forKey: "autoLPMLevel")
        autoLPMAfter = d.bool(forKey: "autoLPMAfter")
        autoLPMAfterMinutes = d.integer(forKey: "autoLPMAfterMinutes")
        autoLPMOffWhenPlugged = d.bool(forKey: "autoLPMOffWhenPlugged")
        calendarCharging = d.bool(forKey: "calendarCharging")
        calendarHours = d.integer(forKey: "calendarHours")
        calendarCountLocations = d.bool(forKey: "calendarCountLocations")
        warmBanner = d.bool(forKey: "warmBanner")
        glassTheme = d.bool(forKey: "glassTheme")
        hotkeyEnabled = d.bool(forKey: "hotkeyEnabled")
        tourDone = d.bool(forKey: "tourDone")
    }

    /// Liquid Glass needs macOS 26; on older systems the setting is shown disabled and ignored.
    static var glassSupported: Bool {
        if #available(macOS 26, *) { return true }
        return false
    }
    var useGlass: Bool { glassTheme && Prefs.glassSupported }

    func isHidden(_ c: Consumer) -> Bool { hiddenApps.contains(c.id) }
}
