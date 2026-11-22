import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum SettingsPane: Hashable {
    case general, menuBar, panel, charging, notifications, insights, accessories, sleep, history, battery, warmth, shortcuts, about
    case app(String)

    static let sidebar: [(String, [SettingsPane])] = [
        ("", [.general, .menuBar, .panel]),
        ("", [.charging, .notifications, .insights, .accessories]),
        ("", [.battery, .warmth, .history, .sleep]),
        ("", [.shortcuts, .about]),
    ]

    var title: String {
        switch self {
        case .general: "General"; case .menuBar: "Menu Bar"; case .panel: "Panel"; case .charging: "Charging"
        case .notifications: "Notifications"; case .insights: "Insights"; case .accessories: "Accessories"; case .sleep: "Sleep"
        case .history: "History"; case .battery: "Battery Health"; case .warmth: "Why It's Warm"; case .shortcuts: "Shortcuts & Widgets"; case .about: "About"; case .app: "History"
        }
    }
    var symbol: String {
        switch self {
        case .general: "gearshape.fill"; case .menuBar: "menubar.rectangle"; case .panel: "rectangle.topthird.inset.filled"
        case .charging: "bolt.fill"; case .notifications: "bell.badge.fill"; case .insights: "lightbulb.fill"
        case .accessories: "airpodspro"; case .sleep: "moon.fill"; case .history: "chart.bar.fill"; case .battery: "heart.fill"
        case .warmth: "thermometer.high"; case .shortcuts: "square.stack.3d.up.fill"
        case .about: "info.circle.fill"; case .app: "chart.bar.fill"
        }
    }
    var tint: Color {
        switch self {
        case .general: .gray; case .menuBar: .blue; case .panel: .indigo; case .charging: .green; case .notifications: .red
        case .insights: .yellow; case .accessories: .cyan; case .sleep: .purple; case .history: .orange; case .battery: .pink
        case .warmth: .red; case .shortcuts: .teal
        case .about: .gray; case .app: .orange
        }
    }
}

@Observable final class SettingsState { var selection: SettingsPane = .general; var appKey: String? }

final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let state = SettingsState()
    private let model: AppModel
    private let showTour: () -> Void

    init(model: AppModel, showTour: @escaping () -> Void) { self.model = model; self.showTour = showTour }

    func show(pane: SettingsPane?) {
        if let pane {
            if case .app(let key) = pane { state.selection = .history; state.appKey = key } else { state.selection = pane; state.appKey = nil }
        }
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 580),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            w.title = "Wattline"
            w.titlebarAppearsTransparent = true
            w.toolbarStyle = .unified
            w.minSize = NSSize(width: 700, height: 480)
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.contentView = NSHostingView(rootView: SettingsRoot(state: state, model: model, showTour: showTour))
            w.center()
            window = w
        }
        NSApp.setActivationPolicy(.regular)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        // Drop the view tree; it's rebuilt next time.
        window?.contentView = nil
        window = nil
    }
}

struct SettingsRoot: View {
    @Bindable var state: SettingsState
    var model: AppModel
    var showTour: () -> Void

    var body: some View {
        NavigationSplitView {
            List(selection: $state.selection) {
                ForEach(SettingsPane.sidebar.indices, id: \.self) { i in
                    Section {
                        ForEach(SettingsPane.sidebar[i].1, id: \.self) { p in
                            Label { Text(p.title) } icon: { SymbolTile(symbol: p.symbol, size: 20, tint: p.tint) }.tag(p)
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 200, max: 240)
        } detail: {
            Group {
                switch state.selection {
                case .general: GeneralPane(showTour: showTour)
                case .menuBar: MenuBarPane()
                case .panel: PanelPane(model: model)
                case .charging: ChargingPane(model: model)
                case .notifications: NotificationsPane()
                case .insights: InsightsPane(model: model)
                case .accessories: AccessoriesPane(model: model)
                case .sleep: SleepPane(model: model)
                case .history, .app: HistoryPane(model: model, appKey: $state.appKey)
                case .battery: BatteryHealthPane(model: model)
                case .warmth: WarmthPane(model: model)
                case .shortcuts: ShortcutsPane()
                case .about: AboutPane()
                }
            }
            .navigationTitle(state.selection.title)
        }
    }
}

// MARK: - General

struct GeneralPane: View {
    var showTour: () -> Void
    var model = AppModel.shared
    @Bindable private var prefs = Prefs.shared
    @State private var login = LoginItem.enabled
    var body: some View {
        Form {
            Section {
                Toggle("Open at Login", isOn: Binding(get: { login }, set: { LoginItem.set($0); login = LoginItem.enabled }))
                Toggle("Open the panel with ⌥⌘B", isOn: $prefs.hotkeyEnabled)
            }
            Section {
                LabeledContent("macOS's own battery icon") {
                    Button("Hide It in Control Center…") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.ControlCenter-Settings.extension")!) }
                }
                Toggle("Suggest Low Power Mode at 20%", isOn: $prefs.suggestLowPower)
            } footer: { Text("Low Power Mode switches without a password once the installer's helper rule is in place; otherwise macOS asks once.").font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading) }
            Section {
                Toggle("Turn on below a level", isOn: $prefs.autoLPMBelow.onChange { model.autoLPMSettingsChanged() })
                Picker("Level", selection: $prefs.autoLPMLevel) { ForEach([10, 15, 20, 25, 30, 40, 50], id: \.self) { Text("\($0)%").tag($0) } }
                    .disabled(!prefs.autoLPMBelow)
                Toggle("Turn on after a while on battery", isOn: $prefs.autoLPMAfter.onChange { model.autoLPMSettingsChanged() })
                Picker("After", selection: $prefs.autoLPMAfterMinutes) {
                    ForEach([15, 30, 60, 90, 120, 180], id: \.self) { Text(Fmt.hoursMinutes(Double($0))).tag($0) }
                }.disabled(!prefs.autoLPMAfter)
                Toggle("Turn it off again when I plug in", isOn: $prefs.autoLPMOffWhenPlugged)
            } header: { Text("Automatic Low Power Mode") } footer: {
                Text("Only Low Power Mode that Wattline turned on is turned off again. Switching automatically needs the installer package's helper rule; without it you get a notification with a button instead.").font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
            }
            Section {
                LabeledContent("Welcome tour") { Button("Show Again") { showTour() } }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Menu Bar

struct MenuBarPane: View {
    @Bindable private var prefs = Prefs.shared
    var body: some View {
        Form {
            Section {
                HStack(spacing: 20) {
                    Spacer()
                    preview("On battery", IconPreview.sample(percent: 64, charging: false, external: false))
                    preview("Charging", IconPreview.sample(percent: 64, charging: true, external: true))
                    preview("Low", IconPreview.sample(percent: 12, charging: false, external: false))
                    Spacer()
                }.padding(.vertical, 6)
            }
            Section {
                Picker("Style", selection: $prefs.iconStyle) { ForEach(IconStyle.allCases) { Text($0.label).tag($0) } }.pickerStyle(.segmented)
                Picker("Beside the icon", selection: $prefs.besideIcon) { ForEach(BesideIcon.allCases) { Text($0.label).tag($0) } }
                    .disabled(prefs.iconStyle == .text)
                Toggle("Percentage inside", isOn: $prefs.percentInside).disabled(prefs.iconStyle != .battery)
                Toggle("Colorful states", isOn: $prefs.colorfulStates)
            } header: { Text("Icon") } footer: { Text("A bolt while charging, a plug when it's plugged in but holding its charge. Green, red and yellow for charging, low and Low Power Mode, or plain to match the rest of the menu bar.").font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading) }
            Section {
                Picker("While charging", selection: $prefs.chargingMotion) { ForEach(ChargingMotion.allCases) { Text($0.label).tag($0) } }
                Picker("Last few percent", selection: $prefs.lastFewMotion) { ForEach(LastFewMotion.allCases) { Text($0.label).tag($0) } }
                Picker("Holding the charge", selection: $prefs.holdingMotion) { ForEach(HoldingMotion.allCases) { Text($0.label).tag($0) } }
            } header: { Text("How it moves") } footer: { Text("All of them rest in Low Power Mode and with Reduce Motion.").font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading) }
        }
        .formStyle(.grouped)
    }
    private func preview(_ label: String, _ s: BatteryState) -> some View {
        VStack(spacing: 6) {
            IconPreview(state: s, motion: StatusIcon.motion(for: s, limit: 100, prefs: prefs)).scaleEffect(1.3).frame(height: 30)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Panel

struct PanelPane: View {
    var model: AppModel
    @Bindable private var prefs = Prefs.shared
    var body: some View {
        Form {
            Section {
                Stepper("Slices: \(prefs.sliceCount)", value: $prefs.sliceCount, in: 2...7)
                Toggle("Ask before quitting an app", isOn: $prefs.askBeforeQuit)
            } header: { Text("The battery") } footer: { Text("Optional, so a stray drag never costs you unsaved work. Apps drawing under 0.1 W never get a slice.").font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading) }
            Section("Show in the panel") {
                Toggle("History", isOn: $prefs.showHistory)
                Toggle("Insights", isOn: $prefs.showInsights)
                Toggle("Accessories", isOn: $prefs.showAccessories)
                Toggle("Sleep", isOn: $prefs.showSleep)
                Toggle("Temperature, voltage and current", isOn: $prefs.showReadings)
                Toggle("Charge limit", isOn: $prefs.showChargeLimit)
            }
            Section {
                ForEach(prefs.hiddenApps, id: \.self) { key in
                    HStack {
                        Text(displayName(key))
                        Spacer()
                        Button { model.toggleHidden(key) } label: { Image(systemName: "minus.circle.fill").foregroundStyle(.red) }.buttonStyle(.plain)
                    }
                }
                Menu("Hide an App…") {
                    ForEach(NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil }
                        .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }, id: \.processIdentifier) { app in
                        let key = "app:\(app.bundleIdentifier!)"
                        if !prefs.hiddenApps.contains(key) { Button(app.localizedName ?? key) { model.toggleHidden(key) } }
                    }
                }
            } header: { Text("Apps you'd never quit") } footer: {
                Text("Hide Music or your VPN from the battery, so they can't be dragged out by accident.").font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.leading)
            }
        }
        .formStyle(.grouped)
    }
    private func displayName(_ key: String) -> String {
        if key.hasPrefix("app:"), let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: String(key.dropFirst(4))) {
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        return key.split(separator: ":").last.map(String.init) ?? key
    }
}

// MARK: - Charging

struct ChargingPane: View {
    var model: AppModel
    @Bindable private var prefs = Prefs.shared
    var body: some View {
        Form {
            Section {
                if model.chargeLevels.isEmpty {
                    LabeledContent("Charge limit") { Text("Not available").foregroundStyle(.secondary) }
                } else {
                    Picker("Charge limit", selection: Binding(get: { model.chargeLimit ?? 100 }, set: { model.setChargeLimit($0) })) {
                        ForEach(model.chargeLevels.reversed(), id: \.self) { Text($0 == 100 ? "None" : "\($0)%").tag($0) }
                    }
                    LabeledContent("Charge to full once") {
                        Button(model.fullOnce ? "Cancel" : "Charge to 100%") { model.fullOnce ? model.cancelFullOnce() : model.chargeToFullOnce() }
                            .disabled(!model.fullOnce && (model.chargeLimit ?? 100) >= 100)
                    }
                }
            } header: { Text("Charge limit") } footer: {
                Text("The same setting as System Settings › Battery. macOS keeps it itself, so it holds even when Wattline isn't running. Needs a Mac with Apple silicon and macOS 26.4 or later. Charge to Full Once brings your limit back when you unplug.")
                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.leading)
            }
            Section {
                Toggle("Charge to 100% before busy days", isOn: Binding(get: { prefs.calendarCharging }, set: { on in
                    if on { model.meetings.requestAccess { ok in prefs.calendarCharging = ok; if ok { Notifier.shared.requestPermission(); model.checkCalendarCharging() } } }
                    else { prefs.calendarCharging = false }
                }))
                Picker("When meetings add up to", selection: $prefs.calendarHours) { ForEach([2, 3, 4, 5, 6], id: \.self) { Text("\($0) hours or more").tag($0) } }
                    .disabled(!prefs.calendarCharging)
                Toggle("Or any meeting has a location", isOn: $prefs.calendarCountLocations).disabled(!prefs.calendarCharging)
                if model.calendarChargingActive { Label("Charging to 100% for upcoming meetings", systemImage: "calendar.badge.clock").foregroundStyle(Theme.green) }
            } header: { Text("Calendar-aware charging") } footer: {
                Text("While plugged in with a charge limit, Wattline looks 16 hours ahead. On a long day of meetings, or meetings somewhere else, it charges to 100% once; your limit comes back when you unplug. It reads only when events start and end and whether they have a location, never titles, places or attendees.")
                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
            }
            Section("When it's charged") {
                Toggle("Notify me", isOn: $prefs.notifyCharged.onTrue { Notifier.shared.requestPermission() })
                Picker("At", selection: $prefs.chargedLevel) { ForEach([80, 85, 90, 95, 100], id: \.self) { Text("\($0)%").tag($0) } }
                    .disabled(!prefs.notifyCharged)
            }
            Section {
                Picker("Chime", selection: $prefs.chime) { ForEach(ChimeMode.allCases) { Text($0.label).tag($0) } }
                Picker("Sound", selection: $prefs.chimeSound) { ForEach(ChimeSound.allCases) { Text($0.label).tag($0) } }
                    .onChange(of: prefs.chimeSound) { _, s in Chime.preview(s, pluggedIn: true) }
                HStack {
                    Spacer()
                    Button("Plug In") { Chime.preview(prefs.chimeSound, pluggedIn: true) }
                    Button("Unplug") { Chime.preview(prefs.chimeSound, pluggedIn: false) }
                }
            } header: { Text("Chime") } footer: {
                Text("Two soft notes, rising as you plug in and falling as you unplug. Most MacBooks already chime when you plug in, so it can play for unplugging only.").font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.leading)
            }
        }
        .formStyle(.grouped)
        .onAppear { model.refreshChargeLimit() }
    }
}

// MARK: - Notifications

struct NotificationsPane: View {
    @Bindable private var prefs = Prefs.shared
    var model = AppModel.shared
    var body: some View {
        Form {
            Section {
                ForEach(prefs.budgets.keys.sorted(), id: \.self) { key in
                    let ref = model.history.index(of: key).flatMap { model.history.app($0) }
                    HStack(spacing: 8) {
                        if let ref { ConsumerIcon(identity: identity(ref), size: 18) }
                        Text(ref?.name ?? key)
                        Spacer()
                        let used = model.todayMinutes(key), limit = Double(prefs.budgets[key] ?? 0)
                        Text("\(Fmt.hoursMinutes(used)) of \(Fmt.hoursMinutes(limit)) today").monospacedDigit()
                            .foregroundStyle(used >= limit ? Theme.orange : .secondary)
                        Button { prefs.budgets[key] = nil } label: { Image(systemName: "minus.circle.fill").foregroundStyle(.red) }.buttonStyle(.plain)
                    }
                }
                Menu("Add a Budget…") {
                    ForEach(model.history.appUse(in: model.history.hours(lastDays: 14)).prefix(20)) { a in
                        if prefs.budgets[a.ref.key] == nil {
                            Menu(a.ref.name) {
                                ForEach([15, 30, 60, 120, 180], id: \.self) { m in
                                    Button(Fmt.hoursMinutes(Double(m)) + " a day") { prefs.budgets[a.ref.key] = m; Notifier.shared.requestPermission() }
                                }
                            }
                        }
                    }
                }
            } header: { Text("Battery budgets") } footer: {
                Text("A notification, once a day, when an app uses more battery time than you allow it. Apps that used battery in the last two weeks can have one; you can also set one on an app's page in History.")
                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
            }
            Section {
                ForEach([30, 20, 15, 10, 5], id: \.self) { level in
                    Toggle("At \(level)%", isOn: Binding(get: { prefs.lowLevels.contains(level) }, set: { on in
                        if on { prefs.lowLevels.append(level); Notifier.shared.requestPermission() } else { prefs.lowLevels.removeAll { $0 == level } }
                    }))
                }
            } header: { Text("Low battery") } footer: { Text("Names the app using the most energy, with a button that quits it.").font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading) }
            Section {
                Toggle("Runaway apps", isOn: $prefs.notifyRunaway.onTrue { Notifier.shared.requestPermission() })
            } footer: { Text("When an app keeps drawing a lot of power for 15 minutes. Never about the app you're using.").font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading) }
            Section {
                Toggle("A sleep that drained the battery", isOn: $prefs.notifySleepDrain.onTrue { Notifier.shared.requestPermission() })
            } footer: { Text("A Mac asleep should use about 1% an hour.").font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading) }
            Section("Accessories") {
                Toggle("Running low", isOn: $prefs.notifyAccessoryLow.onTrue { Notifier.shared.requestPermission() })
                Picker("At", selection: $prefs.accessoryLevel) { ForEach([10, 15, 20, 25, 30], id: \.self) { Text("\($0)%").tag($0) } }
                    .disabled(!prefs.notifyAccessoryLow)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Insights

struct InsightsPane: View {
    var model: AppModel
    @Bindable private var prefs = Prefs.shared
    @State private var calendarDenied = false
    var body: some View {
        Form {
            Section {
                Toggle("Charge before your meeting", isOn: Binding(get: { prefs.meetingWarning }, set: { on in
                    if on {
                        model.meetings.requestAccess { ok in prefs.meetingWarning = ok; calendarDenied = !ok; if ok { Notifier.shared.requestPermission() } }
                    } else { prefs.meetingWarning = false }
                }))
                Picker("Warn", selection: $prefs.meetingLead) {
                    ForEach([15, 30, 45, 60, 90, 120], id: \.self) { m in Text(m < 60 ? "\(m) minutes before" : (m == 60 ? "1 hour before" : (m == 90 ? "1 hour, 30 minutes before" : "2 hours before"))).tag(m) }
                }.disabled(!prefs.meetingWarning)
                if calendarDenied { Text("Calendar access was turned down. Allow it in System Settings › Privacy & Security › Calendars.").font(.footnote).foregroundStyle(.orange) }
            } footer: { Text("Reads only when events start and end, never what they're called or who's coming.").font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading) }
            Section {
                Toggle("Using more power than usual", isOn: $prefs.insightMoreThanUsual)
                Toggle("A new app using a lot", isOn: $prefs.insightNewApp)
                Toggle("Also as notifications", isOn: $prefs.insightsNotify.onTrue { Notifier.shared.requestPermission() })
            } footer: { Text("These need about a week of history, and say nothing rather than guess.").font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading) }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Accessories

struct AccessoriesPane: View {
    var model: AppModel
    @Bindable private var prefs = Prefs.shared
    var body: some View {
        Form {
            Section {
                Toggle("Show a card when headphones connect", isOn: $prefs.accessoryCard)
                Picker("Show it", selection: $prefs.cardPosition) { ForEach(CardPosition.allCases) { Text($0.label).tag($0) } }
                LabeledContent("For") {
                    HStack { Slider(value: $prefs.cardSeconds, in: 3...12, step: 1).frame(width: 160); Text("\(Int(prefs.cardSeconds)) s").monospacedDigit().frame(width: 34) }
                }
                LabeledContent("") { Button("Preview") { (NSApp.delegate as? AppDelegate)?.showCardPreview() } }
            } footer: { Text("It stays while the pointer is over it, never takes focus from the app you're in, and a click opens the panel.").font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading) }
            Section("Connected") {
                if model.accessories.isEmpty { Text("No accessories with a battery are connected.").foregroundStyle(.secondary) }
                ForEach(model.accessories) { AccessoryRow(accessory: $0) }
                Button("Refresh") { model.accessoryMonitor.refresh() }
            }
            Section {} footer: { Text("No Bluetooth permission needed: Wattline reads what macOS already knows about your accessories, without talking to them.").font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading) }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Sleep

struct SleepPane: View {
    var model: AppModel
    @State private var loading: Date?
    @State private var expanded: Set<Date> = []
    var body: some View {
        let _ = model.historyVersion
        let sleeps = Array(model.history.sleeps.reversed())
        Form {
            Section {
                ForEach(sleeps) { s in
                    DisclosureGroup(isExpanded: Binding(get: { expanded.contains(s.start) }, set: { if $0 { expanded.insert(s.start) } else { expanded.remove(s.start) } })) {
                        wakeList(s)
                    } label: {
                        LabeledContent(s.start.formatted(.dateTime.weekday(.wide).day().month())) {
                            Text("\(Fmt.hoursMinutes(s.hours * 60)) · \(s.plugged ? "plugged in" : "\(s.used)% used")")
                                .monospacedDigit()
                                .foregroundStyle(!s.plugged && model.typicalSleepRate > 0 && s.perHour > model.typicalSleepRate * 3 ? Theme.orange : .primary)
                        }
                    }
                }
                if sleeps.isEmpty { Text("Sleeps show here after your Mac has slept for ten minutes or more.").foregroundStyle(.secondary) }
            } header: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Recent Sleeps")
                    if model.typicalSleepRate > 0 { Text(String(format: "Typically %.1f%% an hour", model.typicalSleepRate)).font(.caption).foregroundStyle(.secondary) }
                }
            }
            Section {
                LabeledContent("Kept awake by") {
                    Text(model.keptAwake.isEmpty ? "Nothing right now" : model.keptAwake.map { "\($0.name) (\($0.reason.lowercased()))" }.joined(separator: ", "))
                        .foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                }
            }
        }
        .formStyle(.grouped)
    }
}

extension SleepPane {
    @ViewBuilder
    func wakeList(_ s: SleepRecord) -> some View {
        let wakes = s.wakes ?? []
        let dark = wakes.filter(\.dark)
        if !dark.isEmpty {
            let top = Dictionary(grouping: dark, by: \.reason).sorted { $0.value.count > $1.value.count }
            Text("Woke \(dark.count) time\(dark.count == 1 ? "" : "s") without the screen" + (top.first.map { ", mostly for: \($0.key)" } ?? ""))
                .font(.callout).foregroundStyle(.secondary)
        }
        ForEach(wakes.suffix(30), id: \.self) { w in
            HStack {
                Image(systemName: w.dark ? "moon.zzz" : "sun.max").foregroundStyle(.secondary).frame(width: 18)
                Text(w.date.formatted(date: .omitted, time: .shortened)).monospacedDigit().frame(width: 64, alignment: .leading)
                Text(w.reason).foregroundStyle(.secondary)
            }.font(.callout)
        }
        if wakes.isEmpty { Text("No wakes recorded for this sleep.").font(.callout).foregroundStyle(.secondary) }
        HStack {
            Spacer()
            if loading == s.start { ProgressView().controlSize(.small) }
            Button("Look Up Every Wake") {
                loading = s.start
                model.lookUpWakes(for: s) { loading = nil }
            }.disabled(loading != nil)
        }
        Text("Wattline notes each wake as it happens. Looking up reads macOS's power log, which takes a few seconds.").font(.caption).foregroundStyle(.tertiary)
    }
}

// MARK: - About

struct AboutPane: View {
    var body: some View {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 64, height: 64)
                    VStack(alignment: .leading) {
                        Text("Wattline").font(.title2.bold())
                        Text("Version \(version)").foregroundStyle(.secondary)
                        Text("Your battery, explained.").font(.callout).foregroundStyle(.secondary)
                    }
                }.padding(.vertical, 4)
            }
            Section("Light on your battery") {
                LabeledContent("Panel closed, plugged in", value: "Nothing")
                LabeledContent("Panel closed, on battery", value: "A sample every 5 min")
                LabeledContent("Panel open", value: "A sample every 2 s")
                LabeledContent("Battery changes", value: "Pushed by macOS, never polled")
            }
            Section("How the time is worked out") {
                Text("T × Pₐₚₚ ⁄ (Pₛᵧₛₜₑₘ − Pₐₚₚ)").font(.system(.title3, design: .serif)).frame(maxWidth: .infinity)
                Text("The time left, times the app's power over what the Mac would draw without it. That's the −48m on a slice. App power comes from the kernel's per-process energy counters and the GPU driver's per-process GPU time; processes that don't report energy are worked out from their CPU time and marked ≈, and are never allowed to add up to more than the whole Mac is using.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("Private") {
                Text("No analytics, no accounts, no network requests. The history and your calendar never leave this Mac. The calendar is read only for meeting warnings and calendar-aware charging, and only for times and whether an event has a location.").font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
