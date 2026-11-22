import AppKit
import SwiftUI

/// The battery, as the time you have left, with a slice for each app costing you time.
struct SliceBattery: View {
    var model: AppModel
    @Binding var hovered: String?
    @Binding var selected: String?
    @FocusState private var focused: String?
    @State private var dragging: String?

    private let height: CGFloat = 54

    var body: some View {
        let slices = model.slices
        let timeLeft = model.timeLeft
        let total = max(1, timeLeft + slices.reduce(0) { $0 + $1.minutes })
        GeometryReader { geo in
            let bodyWidth = geo.size.width - 7
            let widths = layout(slices: slices, timeLeft: timeLeft, total: total, width: bodyWidth)
            VStack(spacing: 4) {
                HStack(spacing: 0) {
                    ZStack {
                        Color.white
                        Text(timeLeft > 0 ? Fmt.duration(minutes: timeLeft) : "—")
                            .font(.system(size: widths.first ?? 0 < 70 ? 17 : 24, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.black)
                            .lineLimit(1).minimumScaleFactor(0.5)
                            .padding(.horizontal, 4)
                    }
                    .frame(width: widths.first ?? bodyWidth)
                    .accessibilityLabel("\(Fmt.spokenDuration(minutes: timeLeft)) left")

                    ForEach(Array(slices.enumerated()), id: \.element.id) { i, s in
                        sliceView(s, width: widths[i + 1])
                    }
                }
                .frame(width: bodyWidth, height: height)
                .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
                .overlay(alignment: .trailing) {
                    RoundedRectangle(cornerRadius: 2).fill(Color.primary.opacity(0.35)).frame(width: 4, height: 16).offset(x: 6)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .animation(.spring(response: 0.45, dampingFraction: 0.85), value: slices.map(\.id))

                // What each slice costs, under it.
                HStack(spacing: 0) {
                    Color.clear.frame(width: widths.first ?? 0, height: 1)
                    ForEach(Array(slices.enumerated()), id: \.element.id) { i, s in
                        Text("−" + Fmt.duration(minutes: s.minutes))
                            .font(.system(size: 10, weight: .medium)).monospacedDigit()
                            .foregroundStyle(s.isSystem ? .tertiary : .secondary)
                            .lineLimit(1).fixedSize()
                            .frame(width: widths[i + 1])
                            .opacity(widths[i + 1] >= 26 ? 1 : 0)
                    }
                }
                .frame(width: bodyWidth, alignment: .leading)
            }
        }
        .frame(height: height + 18)
    }

    @ViewBuilder
    private func sliceView(_ s: Slice, width: CGFloat) -> some View {
        let tint = s.isSystem ? Color.gray.opacity(0.55) : Color(nsColor: IconCache.tint(for: s.consumer?.identity))
        let isHover = hovered == s.id, isSel = selected == s.id, isFocus = focused == s.id
        ZStack {
            Rectangle().fill(s.isSystem ? AnyShapeStyle(tint) : AnyShapeStyle(tint.gradient))
            Rectangle().fill(Color.white.opacity(isHover || isSel ? 0.18 : 0))
            ConsumerIcon(identity: s.consumer?.identity, size: min(22, max(12, width - 8)))
                .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
                .opacity(dragging == s.id ? 0.25 : 1)
        }
        .frame(width: width)
        .overlay(Rectangle().fill(Color.black.opacity(0.18)).frame(width: 1), alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Color.white.opacity(isFocus ? 0.9 : 0), lineWidth: 2).padding(2))
        .contentShape(Rectangle())
        .onHover { h in hovered = h ? s.id : (hovered == s.id ? nil : hovered) }
        .onTapGesture { withAnimation(.easeOut(duration: 0.18)) { selected = selected == s.id ? nil : s.id } }
        .gesture(dragGesture(s))
        .focusable(!s.isSystem)
        .focused($focused, equals: s.id)
        .onKeyPress(.delete) { requestQuit(s); return .handled }
        .onKeyPress(.deleteForward) { requestQuit(s); return .handled }
        .onKeyPress(.return) { selected = s.id; return .handled }
        .onChange(of: focused) { _, f in if f == s.id { hovered = s.id } }
        .help(s.isSystem ? "Display & System: the screen, graphics, Wi‑Fi, Bluetooth and macOS itself" : "\(s.name): \(Fmt.watts(s.watts)). Drag out to quit.")
        .accessibilityElement()
        .accessibilityLabel("\(s.name), costs \(Fmt.spokenDuration(minutes: s.minutes))")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Quit") { requestQuit(s) }
    }

    private func dragGesture(_ s: Slice) -> some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .global)
            .onChanged { v in
                guard let c = s.consumer, c.identity.canQuit else { return }
                if dragging == nil && hypot(v.translation.width, v.translation.height) > 10 {
                    dragging = s.id
                    DragGhost.shared.begin(identity: c.identity)
                }
                if dragging == s.id { DragGhost.shared.move(to: NSEvent.mouseLocation) }
            }
            .onEnded { _ in
                guard dragging == s.id, let c = s.consumer else { dragging = nil; return }
                dragging = nil
                if DragGhost.shared.isOutsidePanel {
                    confirmThenQuit(c) { quit in
                        if quit { DragGhost.shared.poof(); model.quit(c, force: false) } else { DragGhost.shared.cancel() }
                    }
                } else {
                    DragGhost.shared.cancel()
                }
            }
    }

    private func requestQuit(_ s: Slice) {
        guard let c = s.consumer, c.identity.canQuit else { NSSound.beep(); return }
        confirmThenQuit(c) { if $0 { model.quit(c, force: false) } }
    }

    private func confirmThenQuit(_ c: Consumer, done: @escaping (Bool) -> Void) {
        guard Prefs.shared.askBeforeQuit else { done(true); return }
        let alert = NSAlert()
        alert.messageText = "Quit \(c.name)?"
        alert.informativeText = "Any unsaved changes may be lost."
        alert.addButton(withTitle: "Quit"); alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        done(alert.runModal() == .alertFirstButtonReturn)
    }

    /// Widths for [time left, slice…]: proportional to time, with room for each icon.
    private func layout(slices: [Slice], timeLeft: Double, total: Double, width: CGFloat) -> [CGFloat] {
        guard !slices.isEmpty else { return [width] }
        let minSlice: CGFloat = 24, minTime: CGFloat = 64
        var w = [CGFloat(timeLeft / total) * width] + slices.map { CGFloat($0.minutes / total) * width }
        // Lift tiny slices to the minimum and take the room from the biggest pieces.
        for _ in 0..<3 {
            var deficit: CGFloat = 0
            for i in w.indices {
                let m = i == 0 ? minTime : minSlice
                if w[i] < m { deficit += m - w[i]; w[i] = m }
            }
            guard deficit > 0.5 else { break }
            let flexible = w.indices.filter { w[$0] > ($0 == 0 ? minTime : minSlice) + 1 }
            let pool = flexible.reduce(0) { $0 + w[$1] - ($1 == 0 ? minTime : minSlice) }
            guard pool > 0 else { break }
            for i in flexible { w[i] -= deficit * (w[i] - (i == 0 ? minTime : minSlice)) / pool }
        }
        let sum = w.reduce(0, +)
        return w.map { $0 * width / sum }
    }
}

/// Plugged in: light swells into the battery, and a bar shows where charging will stop.
struct ChargeBattery: View {
    var model: AppModel
    var body: some View {
        let b = model.battery
        let limit = model.chargeLimit ?? 100
        let animate = b.isCharging && !b.lowPowerMode && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        VStack(spacing: 8) {
            HStack(spacing: 0) {
                GeometryReader { geo in
                    let w = geo.size.width
                    ZStack(alignment: .leading) {
                        Color.primary.opacity(0.08)
                        TimelineView(.animation(minimumInterval: 1 / 24, paused: !animate)) { ctx in
                            let t = ctx.date.timeIntervalSinceReferenceDate
                            let fillW = w * CGFloat(b.percent) / 100
                            ZStack(alignment: .leading) {
                                Rectangle().fill(b.isCharging ? Theme.green : Color.white)
                                if animate {
                                    let p = CGFloat(t.truncatingRemainder(dividingBy: 2.4) / 2.4)
                                    LinearGradient(colors: [.white.opacity(0), .white.opacity(0.55), .white.opacity(0)], startPoint: .leading, endPoint: .trailing)
                                        .frame(width: fillW * 0.5)
                                        .offset(x: -fillW * 0.5 + (fillW * 1.5) * p)
                                }
                            }
                            .frame(width: fillW)
                            .clipped()
                        }
                        if limit < 100 {
                            Hatch(spacing: 5).stroke(Color.primary.opacity(0.18), lineWidth: 1.2)
                                .frame(width: w * CGFloat(100 - limit) / 100)
                                .offset(x: w * CGFloat(limit) / 100)
                        }
                        Text("\(b.percent)")
                            .font(.system(size: 24, weight: .semibold, design: .rounded)).monospacedDigit()
                            .foregroundStyle(b.isCharging || b.percent > 30 ? Color.black : Color.primary)
                            .padding(.leading, 14)
                    }
                }
                .frame(height: 54)
                .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
                RoundedRectangle(cornerRadius: 2).fill(Color.primary.opacity(0.35)).frame(width: 4, height: 16).padding(.leading, 3)
            }
            HStack {
                Text(b.isCharging ? "Charging" : (b.percent >= limit - 1 && limit < 100 ? "Holding at \(limit)%" : (b.fullyCharged ? "Charged" : "Not Charging")))
                Spacer()
                if b.isCharging, let m = b.minutesToFull { Text("\(Fmt.hoursMinutes(Double(m))) to \(min(100, limit))%").foregroundStyle(.secondary) }
                Text("\(b.percent)%").monospacedDigit()
                if limit < 100 { Image(systemName: "arrow.right").font(.system(size: 9)).foregroundStyle(.secondary); Text("\(limit)%").foregroundStyle(.secondary) }
            }
            .font(.system(size: 11))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Battery \(b.percent) percent, \(b.isCharging ? "charging" : "not charging")\(limit < 100 ? ", stops at \(limit) percent" : "")")
    }
}

/// What's behind a slice: its processes, with Show, Quit and Force Quit.
struct SliceDetail: View {
    var model: AppModel
    var sliceID: String
    var close: () -> Void
    @State private var confirmForce = false

    var body: some View {
        let consumer = model.reading.consumers.first { $0.id == sliceID }
        VStack(alignment: .leading, spacing: 8) {
            if sliceID == "system" { systemBody } else if let c = consumer { body(for: c) } else {
                Text("It's not using energy right now.").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.06)))
        .overlay(alignment: .topTrailing) {
            Button(action: close) { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary).padding(6) }
                .buttonStyle(.plain).accessibilityLabel("Close")
        }
    }

    @ViewBuilder
    private func body(for c: Consumer) -> some View {
        HStack(spacing: 8) {
            ConsumerIcon(identity: c.identity, size: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(c.name).font(.system(size: 13, weight: .semibold)).lineLimit(2)
                Text(c.gpuWatts > 0.05 ? "CPU + GPU" : (c.identity.detail ?? "CPU")).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            Text((c.estimated ? "≈ " : "") + Fmt.watts(model.smoothed[c.id] ?? c.watts)).font(.system(size: 12, weight: .medium)).monospacedDigit()
        }
        if c.identity.kind == .service, let d = c.identity.detail {
            Text(d + ". macOS's own work can't be quit: it settles by itself.").font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        VStack(spacing: 3) {
            ForEach(c.processes.prefix(7)) { p in
                HStack(alignment: .firstTextBaseline) {
                    Text(p.name).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Text((p.estimated ? "≈ " : "") + Fmt.watts(p.watts)).font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            if c.processes.count > 7 {
                Text("and \(c.processes.count - 7) more").font(.system(size: 10)).foregroundStyle(.tertiary).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        if c.identity.canQuit {
            HStack(spacing: 6) {
                if c.identity.kind == .app || c.identity.kind == .command {
                    Button("Show") { show(c) }
                }
                Spacer()
                Button("Quit") { model.quit(c, force: false) }
                Button("Force Quit…") { confirmForce = true }
            }
            .controlSize(.small)
            .confirmationDialog("Force quit \(c.name)?", isPresented: $confirmForce) {
                Button("Force Quit", role: .destructive) { model.quit(c, force: true) }
            } message: { Text(c.identity.kind == .command ? "It's sent kill -9, and stops immediately." : "You'll lose any unsaved changes.") }
        }
    }

    private var systemBody: some View {
        let shown = Set(model.slices.compactMap { $0.consumer?.id })
        let small = model.reading.consumers.filter { !shown.contains($0.id) }.prefix(6)
        let s = model.slices.first { $0.isSystem }
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                SymbolTile(symbol: "sun.max.fill", size: 26, tint: .gray)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Display & System").font(.system(size: 13, weight: .semibold))
                    Text("The power no app accounts for").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer()
                Text(Fmt.watts(s?.watts ?? model.reading.unaccountedWatts)).font(.system(size: 12, weight: .medium)).monospacedDigit()
            }
            Text("The screen, graphics, Wi‑Fi, Bluetooth and macOS itself. A dimmer screen makes it smaller.")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let b = Brightness.level() {
                HStack(spacing: 6) {
                    Image(systemName: "sun.max").font(.system(size: 11)).foregroundStyle(.secondary)
                    Text("Screen at \(Int((b * 100).rounded()))%, ≈ \(Fmt.watts(Brightness.backlightWatts(at: b)))").font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    if let g = model.dimmingGain, g.minutes >= 1 {
                        Text("dimming 20% gives +\(Fmt.duration(minutes: g.minutes))").font(.system(size: 11)).foregroundStyle(Theme.green)
                        Button("Dim") { model.dimScreen(by: 0.2) }.controlSize(.mini)
                    }
                }
            }
            if !small.isEmpty {
                Text("Smaller apps, not given a slice").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary).padding(.top, 2)
                ForEach(Array(small)) { c in
                    HStack(spacing: 6) {
                        ConsumerIcon(identity: c.identity, size: 14)
                        Text(c.name).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                        Spacer()
                        Text((c.estimated ? "≈ " : "") + Fmt.watts(model.smoothed[c.id] ?? c.watts)).font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func show(_ c: Consumer) {
        guard let pid = c.identity.appPID else { return }
        if c.identity.kind == .command {
            // bring its terminal forward
            NSRunningApplication(processIdentifier: Proc.responsible(pid))?.activate()
        } else {
            NSRunningApplication(processIdentifier: pid)?.activate()
        }
    }
}

/// The icon that follows the pointer while a slice is dragged out, and the puff of smoke when it's let go.
final class DragGhost {
    static let shared = DragGhost()
    private var window: NSPanel?
    private var host: NSHostingView<GhostView>?
    private let model = GhostModel()
    var panelFrame: () -> NSRect = { .zero }

    var isOutsidePanel: Bool {
        guard let w = window else { return false }
        return !panelFrame().insetBy(dx: -8, dy: -8).contains(NSPoint(x: w.frame.midX, y: w.frame.midY))
    }

    func begin(identity: GroupIdentity) {
        if window == nil {
            let w = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 96, height: 96), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
            w.isOpaque = false; w.backgroundColor = .clear; w.hasShadow = false
            w.level = .popUpMenu; w.ignoresMouseEvents = true
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let h = NSHostingView(rootView: GhostView(model: model))
            w.contentView = h
            window = w; host = h
        }
        model.identity = identity; model.poofing = false; model.outside = false
        window?.alphaValue = 1
        window?.orderFrontRegardless()
    }

    func move(to p: NSPoint) {
        window?.setFrameOrigin(NSPoint(x: p.x - 48, y: p.y - 48))
        let out = isOutsidePanel
        if model.outside != out { model.outside = out }
    }

    func poof() {
        model.poofing = true
        NSSound(named: "Pop")?.play()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in self?.window?.orderOut(nil) }
    }

    func cancel() {
        NSAnimationContext.runAnimationGroup({ ctx in ctx.duration = 0.15; window?.animator().alphaValue = 0 }) { [weak self] in
            self?.window?.orderOut(nil)
        }
    }
}

@Observable final class GhostModel { var identity: GroupIdentity?; var poofing = false; var outside = false }

struct GhostView: View {
    var model: GhostModel
    var body: some View {
        ZStack {
            if model.poofing {
                PuffView()
            } else {
                ConsumerIcon(identity: model.identity, size: 44)
                    .shadow(color: .black.opacity(0.35), radius: 6, y: 3)
                    .scaleEffect(model.outside ? 1.08 : 0.92)
                    .opacity(model.outside ? 1 : 0.7)
                    .overlay(alignment: .topTrailing) {
                        if model.outside {
                            Image(systemName: "xmark.circle.fill").font(.system(size: 16)).foregroundStyle(.white, .red).offset(x: 6, y: -6)
                        }
                    }
                    .animation(.spring(response: 0.25), value: model.outside)
            }
        }
        .frame(width: 96, height: 96)
    }
}

/// A Dock-style puff: a few soft clouds that expand and fade.
struct PuffView: View {
    @State private var go = false
    var body: some View {
        ZStack {
            ForEach(0..<7, id: \.self) { i in
                let a = Double(i) / 7 * 2 * .pi
                Circle()
                    .fill(Color.white.opacity(0.9))
                    .frame(width: 22, height: 22)
                    .shadow(color: .black.opacity(0.2), radius: 2)
                    .offset(x: go ? cos(a) * 30 : 0, y: go ? sin(a) * 30 : 0)
                    .scaleEffect(go ? 1.5 : 0.6)
                    .opacity(go ? 0 : 1)
            }
            Circle().fill(Color.white.opacity(0.95)).frame(width: 36, height: 36).scaleEffect(go ? 0.2 : 1).opacity(go ? 0 : 1)
        }
        .onAppear { withAnimation(.easeOut(duration: 0.42)) { go = true } }
    }
}
