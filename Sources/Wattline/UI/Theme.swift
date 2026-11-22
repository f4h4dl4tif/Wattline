import AppKit
import SwiftUI

enum Theme {
    static let green = Color(nsColor: .systemGreen)
    static let red = Color(nsColor: .systemRed)
    static let yellow = Color(nsColor: .systemYellow)
    static let orange = Color(nsColor: .systemOrange)
    static let panelWidth: CGFloat = 320
}

/// Icons, loaded once and kept small: a few dozen at most.
enum IconCache {
    private static let cache: NSCache<NSString, NSImage> = { let c = NSCache<NSString, NSImage>(); c.countLimit = 64; return c }()
    private static var tints: [String: NSColor] = [:]

    static func icon(path: String) -> NSImage {
        if let i = cache.object(forKey: path as NSString) { return i }
        let img = NSWorkspace.shared.icon(forFile: path)
        img.size = NSSize(width: 32, height: 32)
        cache.setObject(img, forKey: path as NSString)
        return img
    }

    /// A slice colour for anything: its icon's colour, or a calm palette colour picked from its name.
    static func tint(for identity: GroupIdentity?) -> NSColor {
        guard let identity else { return .systemGray }
        if let p = identity.bundlePath, !identity.terminalBadge { return tint(path: p) }
        let palette: [NSColor] = [
            NSColor(srgbRed: 0.36, green: 0.52, blue: 0.92, alpha: 1), NSColor(srgbRed: 0.45, green: 0.42, blue: 0.85, alpha: 1),
            NSColor(srgbRed: 0.24, green: 0.62, blue: 0.70, alpha: 1), NSColor(srgbRed: 0.58, green: 0.45, blue: 0.80, alpha: 1),
            NSColor(srgbRed: 0.30, green: 0.58, blue: 0.86, alpha: 1),
        ]
        let h = identity.name.unicodeScalars.reduce(UInt32(5381)) { ($0 &* 33) &+ $1.value }
        return palette[Int(h % UInt32(palette.count))]
    }

    /// The icon's average colour, softened: used to tint its slice.
    static func tint(path: String?) -> NSColor {
        guard let path else { return .systemGray }
        if let t = tints[path] { return t }
        let img = icon(path: path)
        var px = [UInt8](repeating: 0, count: 4)
        let cs = CGColorSpaceCreateDeviceRGB()
        var color = NSColor.systemBlue
        if let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
           let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            ctx.interpolationQuality = .medium
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            let a = max(CGFloat(px[3]), 1) / 255
            let c = NSColor(srgbRed: CGFloat(px[0]) / 255 / a, green: CGFloat(px[1]) / 255 / a, blue: CGFloat(px[2]) / 255 / a, alpha: 1)
            var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0
            c.usingColorSpace(.sRGB)?.getHue(&h, saturation: &s, brightness: &b, alpha: nil)
            // Keep slices calm and readable: moderate saturation, mid brightness.
            color = s < 0.12 ? NSColor(srgbRed: 0.48, green: 0.5, blue: 0.62, alpha: 1)
                             : NSColor(hue: h, saturation: min(0.62, max(0.35, s)), brightness: min(0.86, max(0.62, b)), alpha: 1)
        }
        tints[path] = color
        return color
    }
}

/// The icon for a consumer: its app, a macOS service symbol, or a generic one; with a terminal badge for commands.
struct ConsumerIcon: View {
    var identity: GroupIdentity?
    var size: CGFloat = 18

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if let path = identity?.bundlePath {
                Image(nsImage: IconCache.icon(path: path)).resizable().interpolation(.high).frame(width: size, height: size)
            } else if let identity {
                SymbolTile(symbol: identity.symbol ?? "gearshape", size: size)
            } else {
                SymbolTile(symbol: "sun.max.fill", size: size, tint: .gray)
            }
            if identity?.terminalBadge == true {
                Image(systemName: "terminal.fill")
                    .font(.system(size: size * 0.36, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(size * 0.06)
                    .background(RoundedRectangle(cornerRadius: size * 0.12).fill(Color.black.opacity(0.85)))
                    .offset(x: size * 0.12, y: size * 0.1)
            }
        }
        .frame(width: size, height: size)
    }
}

/// A System Settings–style rounded symbol tile.
struct SymbolTile: View {
    var symbol: String
    var size: CGFloat
    var tint: Color = .blue
    var body: some View {
        let name = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) == nil ? "gearshape.fill" : symbol
        RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
            .fill(LinearGradient(colors: [tint.opacity(0.95), tint.opacity(0.75)], startPoint: .top, endPoint: .bottom))
            .overlay(Image(systemName: name).font(.system(size: size * 0.55, weight: .semibold)).foregroundStyle(.white))
            .frame(width: size, height: size)
    }
}

/// "Label ……… value", like the system's own Battery menu.
struct InfoRow<Trailing: View>: View {
    var label: String
    @ViewBuilder var trailing: Trailing
    var body: some View {
        HStack(spacing: 6) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            trailing
        }
        .font(.system(size: 12))
        .frame(minHeight: 20)
        .accessibilityElement(children: .combine)
    }
}

struct SectionTitle: View {
    var text: String
    var body: some View {
        Text(text).font(.system(size: 12, weight: .semibold)).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 2)
    }
}

/// Plain-text menu item rows at the bottom of the panel.
struct MenuRow: View {
    var title: String
    var action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 13)).frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 5).fill(hover ? Color.accentColor.opacity(0.85) : .clear))
                .foregroundStyle(hover ? .white : .primary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .padding(.horizontal, -8)
    }
}

/// Diagonal hatching: "held back on purpose".
struct Hatch: Shape {
    var spacing: CGFloat = 4
    func path(in rect: CGRect) -> Path {
        var p = Path()
        var x = rect.minX - rect.height
        while x < rect.maxX {
            p.move(to: CGPoint(x: x, y: rect.maxY)); p.addLine(to: CGPoint(x: x + rect.height, y: rect.minY))
            x += spacing
        }
        return p
    }
}
