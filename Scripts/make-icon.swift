import AppKit

// Wattline's icon: a battery on a deep indigo squircle, its charge split into slices.
let size: CGFloat = 1024
let img = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
    let inset: CGFloat = 100
    let rect = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let squircle = NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.35); shadow.shadowBlurRadius = 28; shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.set()
    NSColor.black.setFill(); squircle.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(colors: [NSColor(srgbRed: 0.20, green: 0.19, blue: 0.36, alpha: 1), NSColor(srgbRed: 0.06, green: 0.06, blue: 0.13, alpha: 1)])!.draw(in: squircle, angle: -90)

    // soft sweeping light, like the hero background
    NSGraphicsContext.saveGraphicsState(); squircle.addClip()
    let wave = NSBezierPath()
    wave.move(to: NSPoint(x: rect.minX, y: rect.minY + 180))
    wave.curve(to: NSPoint(x: rect.maxX, y: rect.maxY - 120), controlPoint1: NSPoint(x: rect.minX + 420, y: rect.minY + 40), controlPoint2: NSPoint(x: rect.maxX - 300, y: rect.maxY - 60))
    wave.lineWidth = 6
    NSColor(srgbRed: 0.62, green: 0.6, blue: 1, alpha: 0.35).setStroke(); wave.stroke()
    NSGraphicsContext.restoreGraphicsState()

    // battery body
    let body = NSRect(x: 230, y: 390, width: 520, height: 244)
    let bodyPath = NSBezierPath(roundedRect: body, xRadius: 70, yRadius: 70)
    NSGraphicsContext.saveGraphicsState(); bodyPath.addClip()
    NSColor.white.setFill(); NSRect(x: body.minX, y: body.minY, width: 250, height: body.height).fill()
    let slices: [(CGFloat, NSColor)] = [
        (110, NSColor(srgbRed: 0.33, green: 0.52, blue: 0.98, alpha: 1)),
        (80, NSColor(srgbRed: 0.55, green: 0.5, blue: 0.86, alpha: 1)),
        (80, NSColor(srgbRed: 0.42, green: 0.42, blue: 0.5, alpha: 1)),
    ]
    var x = body.minX + 250
    for (w, c) in slices {
        c.setFill(); NSRect(x: x, y: body.minY, width: w, height: body.height).fill()
        NSColor.black.withAlphaComponent(0.25).setFill(); NSRect(x: x, y: body.minY, width: 4, height: body.height).fill()
        x += w
    }
    NSGraphicsContext.restoreGraphicsState()
    NSColor.white.withAlphaComponent(0.85).setFill()
    NSBezierPath(roundedRect: NSRect(x: body.maxX + 22, y: body.midY - 50, width: 34, height: 100), xRadius: 17, yRadius: 17).fill()

    // a bolt in the white part
    let bolt = NSBezierPath()
    let bx = body.minX + 125, by = body.midY
    bolt.move(to: NSPoint(x: bx + 18, y: by + 88)); bolt.line(to: NSPoint(x: bx - 46, y: by - 6)); bolt.line(to: NSPoint(x: bx + 2, y: by - 6))
    bolt.line(to: NSPoint(x: bx - 18, y: by - 88)); bolt.line(to: NSPoint(x: bx + 46, y: by + 6)); bolt.line(to: NSPoint(x: bx - 2, y: by + 6)); bolt.close()
    NSColor(srgbRed: 0.12, green: 0.12, blue: 0.2, alpha: 1).setFill(); bolt.fill()

    // the slice being dragged out
    let pulled = NSRect(x: 600, y: 190, width: 150, height: 150)
    NSGraphicsContext.saveGraphicsState()
    let s2 = NSShadow(); s2.shadowColor = NSColor.black.withAlphaComponent(0.45); s2.shadowBlurRadius = 24; s2.shadowOffset = NSSize(width: 0, height: -10); s2.set()
    NSColor(srgbRed: 0.98, green: 0.62, blue: 0.3, alpha: 1).setFill()
    NSBezierPath(roundedRect: pulled, xRadius: 36, yRadius: 36).fill()
    NSGraphicsContext.restoreGraphicsState()
    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: pulled.midX, y: pulled.maxY - 34)); arrow.line(to: NSPoint(x: pulled.midX, y: pulled.minY + 34))
    arrow.move(to: NSPoint(x: pulled.midX - 30, y: pulled.minY + 64)); arrow.line(to: NSPoint(x: pulled.midX, y: pulled.minY + 34)); arrow.line(to: NSPoint(x: pulled.midX + 30, y: pulled.minY + 64))
    arrow.lineWidth = 16; arrow.lineCapStyle = .round; arrow.lineJoinStyle = .round
    NSColor.white.setStroke(); arrow.stroke()
    return true
}
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
