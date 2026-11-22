import AppKit

/// Draws the menu bar icon: a battery that drains like the built-in one, a ring, or just the number.
enum StatusIcon {
    enum Motion { case none, flow, liquid, stripes, pulse, calm, breathe, beat, water }

    static func motion(for b: BatteryState, limit: Int?, prefs: Prefs) -> Motion {
        guard b.externalConnected, b.hasBattery, !b.lowPowerMode,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return .none }
        if b.isCharging {
            let target = limit ?? 100
            if b.percent >= target - 5 {
                switch prefs.lastFewMotion { case .pulse: return .pulse; case .calm: return .calm; case .still: return .none }
            }
            switch prefs.chargingMotion { case .flow: return .flow; case .liquid: return .liquid; case .stripes: return .stripes; case .still: return .none }
        }
        switch prefs.holdingMotion { case .breathe: return .breathe; case .beat: return .beat; case .water: return .water; case .still: return .none }
    }

    static func fps(_ m: Motion) -> Double {
        switch m { case .none: 0; case .breathe, .water, .calm, .pulse: 8; default: 15 }
    }

    /// `phase` runs 0…1 and loops.
    static func image(_ b: BatteryState, prefs: Prefs, motion: Motion, phase: Double) -> NSImage {
        switch prefs.iconStyle {
        case .battery: return battery(b, prefs: prefs, motion: motion, phase: phase)
        case .ring: return ring(b, prefs: prefs, motion: motion, phase: phase)
        case .text: return NSImage(size: NSSize(width: 1, height: 1))
        }
    }

    private static func stateColor(_ b: BatteryState, prefs: Prefs) -> NSColor? {
        guard prefs.colorfulStates, b.hasBattery else { return nil }
        if b.lowPowerMode { return .systemYellow }
        if b.isCharging { return .systemGreen }
        if !b.externalConnected && b.percent <= 20 { return .systemRed }
        return nil
    }

    private static func battery(_ b: BatteryState, prefs: Prefs, motion: Motion, phase: Double) -> NSImage {
        let color = stateColor(b, prefs: prefs)
        let size = NSSize(width: 27, height: 13)
        let img = NSImage(size: size, flipped: false) { _ in
            let body = NSRect(x: 0.5, y: 0.5, width: 23.5, height: 12)
            let outline = NSBezierPath(roundedRect: body, xRadius: 3.6, yRadius: 3.6)
            NSColor.black.withAlphaComponent(0.4).setStroke()
            outline.lineWidth = 1
            outline.stroke()
            let nub = NSBezierPath(roundedRect: NSRect(x: 24.8, y: 4.2, width: 1.7, height: 4.6), xRadius: 0.8, yRadius: 0.8)
            NSColor.black.withAlphaComponent(0.4).setFill(); nub.fill()

            let inner = body.insetBy(dx: 1.75, dy: 1.75)
            let pct = b.hasBattery ? CGFloat(max(4, min(100, b.percent))) / 100 : 1
            var fillRect = inner; fillRect.size.width = max(2, inner.width * pct)
            let fillPath = NSBezierPath(roundedRect: fillRect, xRadius: 2, yRadius: 2)
            let base = color ?? .black
            NSGraphicsContext.saveGraphicsState()
            fillPath.addClip()
            drawMotion(motion, in: fillRect, base: base, phase: phase)
            NSGraphicsContext.restoreGraphicsState()

            if prefs.percentInside && b.hasBattery {
                let s = "\(b.percent)" as NSString
                let font = NSFont.systemFont(ofSize: 8.5, weight: .bold)
                // Knock the number out of the fill so it reads on any background.
                NSGraphicsContext.current?.compositingOperation = .destinationOut
                let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
                let sz = s.size(withAttributes: attrs)
                s.draw(at: NSPoint(x: inner.midX - sz.width / 2, y: inner.midY - sz.height / 2 + 0.3), withAttributes: attrs)
                NSGraphicsContext.current?.compositingOperation = .sourceOver
            } else if b.externalConnected {
                glyph(b.isCharging ? "bolt.fill" : "powerplug.fill", center: NSPoint(x: body.midX, y: body.midY))
            }
            return true
        }
        img.isTemplate = color == nil
        return img
    }

    private static func drawMotion(_ m: Motion, in r: NSRect, base: NSColor, phase: Double) {
        let p = CGFloat(phase)
        switch m {
        case .none:
            base.setFill(); r.fill()
        case .flow:
            base.withAlphaComponent(0.75).setFill(); r.fill()
            let w = r.width * 0.55, x = r.minX - w + (r.width + w) * p
            NSGradient(colors: [base.withAlphaComponent(0), base, base.withAlphaComponent(0)])?.draw(in: NSRect(x: x, y: r.minY, width: w, height: r.height), angle: 0)
        case .liquid, .calm, .water:
            base.withAlphaComponent(0.45).setFill(); r.fill()
            let amp: CGFloat = m == .liquid ? 1.6 : (m == .calm ? 1.0 : 0.6)
            let path = NSBezierPath()
            path.move(to: NSPoint(x: r.minX, y: r.minY))
            var x = r.minX
            while x <= r.maxX + 1 {
                let y = r.midY + 1 + amp * sin((x / 5) + p * 2 * .pi)
                path.line(to: NSPoint(x: x, y: y)); x += 1
            }
            path.line(to: NSPoint(x: r.maxX, y: r.minY)); path.close()
            base.setFill(); path.fill()
            // the wave rises toward the right edge like a liquid level seen side-on
            base.setFill(); NSRect(x: r.minX, y: r.minY, width: r.width, height: r.height * 0.35).fill()
        case .stripes:
            base.withAlphaComponent(0.6).setFill(); r.fill()
            base.setFill()
            var x = r.minX - r.height + p * 6
            while x < r.maxX {
                let s = NSBezierPath()
                s.move(to: NSPoint(x: x, y: r.minY)); s.line(to: NSPoint(x: x + 3, y: r.minY))
                s.line(to: NSPoint(x: x + 3 + r.height, y: r.maxY)); s.line(to: NSPoint(x: x + r.height, y: r.maxY)); s.close()
                s.fill(); x += 6
            }
        case .pulse:
            base.withAlphaComponent(0.55 + 0.45 * CGFloat((sin(phase * 2 * .pi) + 1) / 2)).setFill(); r.fill()
        case .breathe:
            base.withAlphaComponent(0.6 + 0.4 * CGFloat((sin(phase * 2 * .pi) + 1) / 2)).setFill(); r.fill()
        case .beat:
            // lub-dub, then rest
            let t = phase
            let pulse = exp(-pow((t - 0.1) * 22, 2)) + 0.7 * exp(-pow((t - 0.28) * 22, 2))
            base.withAlphaComponent(0.6 + 0.4 * CGFloat(pulse)).setFill(); r.fill()
        }
    }

    private static func glyph(_ name: String, center: NSPoint) {
        guard let sym = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .black)) else { return }
        let sz = sym.size
        let rect = NSRect(x: center.x - sz.width / 2, y: center.y - sz.height / 2, width: sz.width, height: sz.height)
        // A thin knock-out around the glyph keeps it legible over the fill.
        NSGraphicsContext.current?.compositingOperation = .destinationOut
        for dx in [-1.0, 1.0] { for dy in [-1.0, 1.0] { sym.draw(in: rect.offsetBy(dx: dx, dy: dy)) } }
        NSGraphicsContext.current?.compositingOperation = .sourceOver
        let tinted = NSImage(size: sz, flipped: false) { r in
            sym.draw(in: r); NSColor.black.set(); r.fill(using: .sourceAtop); return true
        }
        tinted.draw(in: rect)
    }

    private static func ring(_ b: BatteryState, prefs: Prefs, motion: Motion, phase: Double) -> NSImage {
        let color = stateColor(b, prefs: prefs)
        let size = NSSize(width: 16, height: 16)
        let img = NSImage(size: size, flipped: false) { _ in
            let c = NSPoint(x: 8, y: 8), r: CGFloat = 6.2
            let track = NSBezierPath(); track.appendArc(withCenter: c, radius: r, startAngle: 0, endAngle: 360)
            track.lineWidth = 2.4
            NSColor.black.withAlphaComponent(0.25).setStroke(); track.stroke()
            let pct = CGFloat(max(2, min(100, b.percent))) / 100
            let arc = NSBezierPath()
            arc.appendArc(withCenter: c, radius: r, startAngle: 90, endAngle: 90 - 360 * pct, clockwise: true)
            arc.lineWidth = 2.4; arc.lineCapStyle = .round
            var base = color ?? .black
            switch motion {
            case .pulse, .breathe: base = base.withAlphaComponent(0.6 + 0.4 * CGFloat((sin(phase * 2 * .pi) + 1) / 2))
            case .beat: base = base.withAlphaComponent(0.6 + 0.4 * CGFloat(exp(-pow((phase - 0.1) * 22, 2)) + 0.7 * exp(-pow((phase - 0.28) * 22, 2))))
            default: break
            }
            base.setStroke(); arc.stroke()
            if [.flow, .liquid, .stripes, .calm, .water].contains(motion) {
                // a bright bead travelling along the filled arc
                let a = (90 - 360 * pct * CGFloat(phase)) * .pi / 180
                let dot = NSBezierPath(ovalIn: NSRect(x: c.x + r * cos(a) - 1.6, y: c.y + r * sin(a) - 1.6, width: 3.2, height: 3.2))
                (color.map { $0.highlight(withLevel: 0.5) ?? $0 } ?? NSColor.black.withAlphaComponent(0.5)).setFill(); dot.fill()
            }
            if b.externalConnected { glyph(b.isCharging ? "bolt.fill" : "powerplug.fill", center: c) }
            return true
        }
        img.isTemplate = color == nil
        return img
    }

    static func title(_ b: BatteryState, prefs: Prefs, timeLeft: Double) -> String {
        if prefs.iconStyle == .text { return b.hasBattery ? "\(b.percent)%" : "\(Int(b.systemPower.rounded())) W" }
        guard b.hasBattery else { return "" }
        switch prefs.besideIcon {
        case .nothing: return ""
        case .percentage: return "\(b.percent)%"
        case .timeLeft:
            if b.externalConnected { return b.minutesToFull.map { Fmt.duration(minutes: Double($0)) } ?? "\(b.percent)%" }
            return timeLeft > 0 ? Fmt.duration(minutes: timeLeft) : "\(b.percent)%"
        case .powerDraw: return String(format: b.systemPower < 10 ? "%.1f W" : "%.0f W", b.systemPower)
        }
    }
}
