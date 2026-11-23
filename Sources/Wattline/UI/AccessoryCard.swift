import AppKit
import SwiftUI

/// Put AirPods in, and a glass card slides in below the menu bar with a ring for each part.
final class AccessoryCardController {
    private var window: NSPanel?
    #if DEBUG
    var debugWindow: NSWindow? { window }
    #endif
    private var hideWork: DispatchWorkItem?
    private let state = CardState()
    private var builtWithGlass = false
    var onClick: (() -> Void)?

    func show(_ a: Accessory, anchor: NSRect?) {
        let size = NSSize(width: 340, height: 128)
        let glass = Prefs.shared.useGlass
        if window != nil, builtWithGlass != glass { window?.orderOut(nil); window = nil }   // theme changed: rebuild
        state.glass = glass
        if window == nil {
            builtWithGlass = glass
            let w = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
            w.isOpaque = false; w.backgroundColor = .clear; w.hasShadow = true
            w.level = .statusBar
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            let host = NSHostingView(rootView: AccessoryCardView(state: state, onClick: { [weak self] in self?.hide(); self?.onClick?() },
                                                                  onHover: { [weak self] h in self?.hovering(h) }))
            if #available(macOS 26, *), glass {
                // Liquid Glass theme: a dark-tinted glass HUD keeps the white rings and labels legible on any wallpaper.
                let g = NSGlassEffectView(frame: NSRect(origin: .zero, size: size))
                g.cornerRadius = 24
                g.tintColor = NSColor.black.withAlphaComponent(0.35)
                host.frame = g.bounds; host.autoresizingMask = [.width, .height]
                g.contentView = host
                w.contentView = g
            } else {
                let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
                effect.material = .hudWindow; effect.blendingMode = .behindWindow; effect.state = .active
                effect.wantsLayer = true; effect.layer?.cornerRadius = 24; effect.layer?.cornerCurve = .continuous; effect.layer?.masksToBounds = true
                host.frame = effect.bounds; host.autoresizingMask = [.width, .height]
                effect.addSubview(host)
                w.contentView = effect
            }
            window = w
        }
        guard let w = window, let screen = NSScreen.main else { return }
        state.accessory = a
        state.appeared = false
        let vf = screen.visibleFrame
        var x: CGFloat
        switch Prefs.shared.cardPosition {
        case .belowIcon: x = (anchor?.midX ?? vf.maxX - 200) - size.width / 2
        case .topCenter: x = vf.midX - size.width / 2
        case .topRight: x = vf.maxX - size.width - 12
        }
        x = max(vf.minX + 8, min(x, vf.maxX - size.width - 8))
        let finalY = vf.maxY - size.height - 8
        w.setFrame(NSRect(x: x, y: finalY + 30, width: size.width, height: size.height), display: false)
        w.alphaValue = 0
        w.orderFrontRegardless()     // never takes focus from the app you're in
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.35
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
            w.animator().setFrame(NSRect(x: x, y: finalY, width: size.width, height: size.height), display: true)
            w.animator().alphaValue = 1
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            withAnimation(.easeOut(duration: 0.9)) { self?.state.appeared = true }
        }
        scheduleHide()
    }

    private func scheduleHide() {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(3, min(12, Prefs.shared.cardSeconds)), execute: work)
    }

    private func hovering(_ h: Bool) {
        if h { hideWork?.cancel() } else { scheduleHide() }
    }

    func hide() {
        hideWork?.cancel()
        guard let w = window, w.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            w.animator().alphaValue = 0
            w.animator().setFrame(w.frame.offsetBy(dx: 0, dy: 20), display: true)
        }) { w.orderOut(nil) }
    }
}

@Observable final class CardState { var accessory: Accessory?; var appeared = false; var glass = false }

struct AccessoryCardView: View {
    var state: CardState
    var onClick: () -> Void
    var onHover: (Bool) -> Void

    var body: some View {
        HStack(spacing: 16) {
            if let a = state.accessory {
                VStack(spacing: 6) {
                    Image(systemName: NSImage(systemSymbolName: a.symbol, accessibilityDescription: nil) == nil ? "headphones" : a.symbol)
                        .font(.system(size: 38, weight: .light))
                        .foregroundStyle(.white)
                        .frame(height: 48)
                        .scaleEffect(state.appeared ? 1 : 0.7)
                    VStack(spacing: 0) {
                        Text(a.name).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                        if let m = a.model, m != a.name { Text(m).font(.system(size: 10)).foregroundStyle(.white.opacity(0.6)).lineLimit(1) }
                    }
                }
                .frame(width: 110)
                HStack(spacing: 14) {
                    ForEach(a.parts) { p in
                        VStack(spacing: 5) {
                            ZStack {
                                Circle().stroke(Color.white.opacity(0.18), lineWidth: 5)
                                Circle().trim(from: 0, to: state.appeared ? CGFloat(p.level) / 100 : 0).rotation(.degrees(-90))
                                    .stroke(p.level <= 20 ? Theme.red : Theme.green, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                                Text("\(p.level)%").font(.system(size: 11, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(.white)
                            }
                            .frame(width: 46, height: 46)
                            Text(p.label.isEmpty ? "Battery" : p.label).font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(0.7))
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(state.glass ? Color.clear : Color.black.opacity(0.25))   // glass carries its own tint
        .contentShape(Rectangle())
        .onTapGesture(perform: onClick)
        .onHover(perform: onHover)
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .combine)
    }
}
