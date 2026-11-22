import SwiftUI

/// A live, animated menu bar icon for previews.
struct IconPreview: View {
    var state: BatteryState
    var motion: StatusIcon.Motion
    var showTitle = true
    var prefs = Prefs.shared
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 15, paused: motion == .none)) { ctx in
            let period: Double = [.breathe, .water, .calm].contains(motion) ? 4 : (motion == .beat ? 1.2 : 2)
            let phase = ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period
            HStack(spacing: 4) {
                if showTitle {
                    let t = StatusIcon.title(state, prefs: prefs, timeLeft: 290)
                    if !t.isEmpty { Text(t).font(.system(size: 13)).monospacedDigit() }
                }
                if prefs.iconStyle != .text {
                    Image(nsImage: StatusIcon.image(state, prefs: prefs, motion: motion, phase: phase))
                }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.07)))
    }

    static func sample(percent: Int, charging: Bool, external: Bool) -> BatteryState {
        var s = BatteryState(); s.hasBattery = true; s.percent = percent; s.isCharging = charging; s.externalConnected = external
        s.systemPower = 7.3; return s
    }
}

struct WelcomeTour: View {
    var model: AppModel
    var finish: () -> Void
    @State private var step = 0
    @Bindable private var prefs = Prefs.shared
    @State private var loginItem = LoginItem.enabled
    private let titles = ["Welcome", "Your Menu Bar", "How It Moves", "What the Panel Shows", "Notifications", "Finishing Touches"]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                ForEach(0..<titles.count, id: \.self) { i in
                    Capsule().fill(i <= step ? Color.accentColor : Color.primary.opacity(0.15)).frame(width: i == step ? 22 : 8, height: 6)
                }
            }
            .animation(.spring(response: 0.3), value: step)
            .padding(.top, 34)

            Text(titles[step]).font(.system(size: 22, weight: .bold)).padding(.top, 18)
            Group {
                switch step {
                case 0: welcome
                case 1: menuBar
                case 2: motion
                case 3: panel
                case 4: notifications
                default: finishing
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.horizontal, 44).padding(.top, 16)
            .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .opacity))
            .id(step)

            HStack {
                if step > 0 { Button("Back") { withAnimation { step -= 1 } }.keyboardShortcut(.cancelAction) }
                Spacer()
                Button(step == titles.count - 1 ? "Done" : "Continue") {
                    if step == titles.count - 1 { finish() } else { withAnimation { step += 1 } }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
            .padding(20)
        }
        .frame(width: 520, height: 460)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var welcome: some View {
        VStack(spacing: 18) {
            IconPreview(state: IconPreview.sample(percent: 64, charging: false, external: false), motion: .none, showTitle: false)
                .scaleEffect(2.2).padding(.vertical, 16)
            VStack(alignment: .leading, spacing: 10) {
                bullet("bolt.horizontal", "See what's draining your Mac, down to the watt.")
                bullet("clock.arrow.circlepath", "Every app shows the battery time it costs you.")
                bullet("hand.draw", "Drag a slice out of the battery to quit that app.")
                bullet("lock", "Everything stays on your Mac. No accounts, no analytics.")
            }
            Text("Each choice applies as you make it, so you can close this whenever you like.")
                .font(.system(size: 11)).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
    }

    private func bullet(_ s: String, _ t: String) -> some View {
        HStack(spacing: 10) { Image(systemName: s).frame(width: 20).foregroundStyle(Color.accentColor); Text(t).font(.system(size: 13)) }
    }

    private var menuBar: some View {
        VStack(spacing: 16) {
            IconPreview(state: IconPreview.sample(percent: 64, charging: false, external: false), motion: .none).scaleEffect(1.6).padding(.vertical, 10)
            Form {
                Picker("Style", selection: $prefs.iconStyle) { ForEach(IconStyle.allCases) { Text($0.label).tag($0) } }.pickerStyle(.segmented)
                Picker("Beside the icon", selection: $prefs.besideIcon) { ForEach(BesideIcon.allCases) { Text($0.label).tag($0) } }
                Toggle("Percentage inside", isOn: $prefs.percentInside).disabled(prefs.iconStyle != .battery)
                Toggle("Colorful states", isOn: $prefs.colorfulStates)
            }
            .formStyle(.grouped).scrollDisabled(true)
        }
    }

    private var motion: some View {
        VStack(spacing: 12) {
            Text("The battery can move while it charges, and while it's held at your limit.").font(.system(size: 12)).foregroundStyle(.secondary)
            HStack(spacing: 24) {
                VStack { IconPreview(state: IconPreview.sample(percent: 64, charging: true, external: true), motion: StatusIcon.motion(for: IconPreview.sample(percent: 64, charging: true, external: true), limit: 100, prefs: prefs), showTitle: false); Text("Charging").font(.caption).foregroundStyle(.secondary) }
                VStack { IconPreview(state: IconPreview.sample(percent: 97, charging: true, external: true), motion: StatusIcon.motion(for: IconPreview.sample(percent: 97, charging: true, external: true), limit: 100, prefs: prefs), showTitle: false); Text("Last few %").font(.caption).foregroundStyle(.secondary) }
                VStack { IconPreview(state: IconPreview.sample(percent: 80, charging: false, external: true), motion: StatusIcon.motion(for: IconPreview.sample(percent: 80, charging: false, external: true), limit: 80, prefs: prefs), showTitle: false); Text("Holding").font(.caption).foregroundStyle(.secondary) }
            }
            .scaleEffect(1.3).padding(.vertical, 8)
            Form {
                Picker("While Charging", selection: $prefs.chargingMotion) { ForEach(ChargingMotion.allCases) { Text($0.label).tag($0) } }
                Picker("Last Few Percent", selection: $prefs.lastFewMotion) { ForEach(LastFewMotion.allCases) { Text($0.label).tag($0) } }
                Picker("Holding the Charge", selection: $prefs.holdingMotion) { ForEach(HoldingMotion.allCases) { Text($0.label).tag($0) } }
            }
            .formStyle(.grouped).scrollDisabled(true)
            Text("All of them rest in Low Power Mode and with Reduce Motion.").font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private var panel: some View {
        Form {
            Toggle("History", isOn: $prefs.showHistory)
            Toggle("Insights", isOn: $prefs.showInsights)
            Toggle("Accessories", isOn: $prefs.showAccessories)
            Toggle("Sleep", isOn: $prefs.showSleep)
            Toggle("Temperature, voltage and current", isOn: $prefs.showReadings)
            Toggle("Charge limit", isOn: $prefs.showChargeLimit)
        }
        .formStyle(.grouped).scrollDisabled(true)
    }

    private var notifications: some View {
        VStack(spacing: 8) {
            Form {
                Toggle("Low battery, at 20% and 10%", isOn: Binding(get: { !prefs.lowLevels.isEmpty }, set: { prefs.lowLevels = $0 ? [20, 10] : []; if $0 { Notifier.shared.requestPermission() } }))
                Toggle("When it's charged", isOn: $prefs.notifyCharged.onTrue { Notifier.shared.requestPermission() })
                Toggle("Accessories running low", isOn: $prefs.notifyAccessoryLow.onTrue { Notifier.shared.requestPermission() })
                Toggle("Apps using a lot of energy", isOn: $prefs.notifyRunaway.onTrue { Notifier.shared.requestPermission() })
                Toggle("A sleep that drained the battery", isOn: $prefs.notifySleepDrain.onTrue { Notifier.shared.requestPermission() })
            }
            .formStyle(.grouped).scrollDisabled(true)
            Text("macOS asks for permission the first time you turn one on.").font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .onAppear { Notifier.shared.requestPermission() }
    }

    private var finishing: some View {
        Form {
            Toggle("Open the panel with ⌥⌘B", isOn: $prefs.hotkeyEnabled)
            Toggle("Open at Login", isOn: Binding(get: { loginItem }, set: { LoginItem.set($0); loginItem = LoginItem.enabled }))
            LabeledContent("macOS's own battery icon") {
                Button("Hide It in Control Center…") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.ControlCenter-Settings.extension")!)
                }
            }
        }
        .formStyle(.grouped).scrollDisabled(true)
    }
}

extension Binding where Value == Bool {
    /// Runs `action` when the toggle is switched on.
    func onTrue(_ action: @escaping () -> Void) -> Binding<Bool> {
        Binding(get: { wrappedValue }, set: { wrappedValue = $0; if $0 { action() } })
    }
    func onChange(_ action: @escaping () -> Void) -> Binding<Bool> {
        Binding(get: { wrappedValue }, set: { wrappedValue = $0; action() })
    }
}
