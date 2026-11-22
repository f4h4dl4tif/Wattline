import AppKit
import IOKit.ps
import SwiftUI
import WidgetKit

/// What the app writes after each reading (the extension is sandboxed and can't measure apps itself).
struct Snapshot: Codable {
    struct App: Codable { var name: String; var path: String?; var symbol: String?; var minutes: Double; var watts: Double }
    var date: Date
    var percent: Int
    var charging: Bool
    var plugged: Bool
    var minutesLeft: Double
    var apps: [App]
}

struct Entry: TimelineEntry {
    var date: Date
    var snap: Snapshot?
    var percent: Int
    var charging: Bool
    var plugged: Bool
    var hasBattery: Bool
}

struct Provider: TimelineProvider {
    private var file: URL {
        let home = String(cString: getpwuid(getuid()).pointee.pw_dir)
        return URL(fileURLWithPath: home).appendingPathComponent("Library/Application Support/Wattline/widget.json")
    }

    private func load() -> Entry {
        let snap = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(Snapshot.self, from: $0) }
        // The level itself comes straight from macOS, so it's never stale.
        var pct = snap?.percent ?? 0, charging = snap?.charging ?? false, plugged = snap?.plugged ?? false, has = false
        if let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] {
            for ps in list {
                guard let d = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any],
                      (d[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType else { continue }
                has = true
                let cur = d[kIOPSCurrentCapacityKey] as? Int ?? 0, max = d[kIOPSMaxCapacityKey] as? Int ?? 100
                pct = max > 0 ? cur * 100 / max : cur
                charging = d[kIOPSIsChargingKey] as? Bool ?? false
                plugged = (d[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
            }
        }
        return Entry(date: Date(), snap: snap, percent: pct, charging: charging, plugged: plugged, hasBattery: has)
    }

    func placeholder(in context: Context) -> Entry {
        Entry(date: Date(), snap: Snapshot(date: Date(), percent: 64, charging: false, plugged: false, minutesLeft: 290,
                                           apps: [.init(name: "Xcode", path: nil, symbol: "hammer", minutes: 41, watts: 3),
                                                  .init(name: "Music", path: nil, symbol: "music.note", minutes: 23, watts: 1),
                                                  .init(name: "Safari", path: nil, symbol: "safari", minutes: 12, watts: 0.5)]),
              percent: 64, charging: false, plugged: false, hasBattery: true)
    }
    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) { completion(context.isPreview ? placeholder(in: context) : load()) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        completion(Timeline(entries: [load()], policy: .after(Date().addingTimeInterval(15 * 60))))
    }
}

func duration(_ m: Double) -> String {
    let t = max(0, Int(m.rounded()))
    return t < 60 ? "\(t)m" : String(format: "%d:%02d", t / 60, t % 60)
}

struct BatteryGlyph: View {
    var percent: Int
    var charging: Bool
    var body: some View {
        HStack(spacing: 2) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 5, style: .continuous).stroke(Color.primary.opacity(0.35), lineWidth: 1.5)
                GeometryReader { g in
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(charging ? Color.green : (percent <= 20 ? Color.red : Color.primary))
                        .frame(width: max(3, (g.size.width - 6) * CGFloat(percent) / 100)).padding(3)
                }
                if charging { Image(systemName: "bolt.fill").font(.system(size: 10, weight: .black)).frame(maxWidth: .infinity) }
            }
            .frame(width: 38, height: 18)
            RoundedRectangle(cornerRadius: 1).fill(Color.primary.opacity(0.35)).frame(width: 2.5, height: 7)
        }
    }
}

struct AppIcon: View {
    var app: Snapshot.App
    var body: some View {
        if let p = app.path, FileManager.default.fileExists(atPath: p) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: p)).resizable().frame(width: 18, height: 18)
        } else {
            Image(systemName: app.symbol ?? "app.fill").font(.system(size: 11)).frame(width: 18, height: 18)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.blue.opacity(0.25)))
        }
    }
}

struct WidgetView: View {
    var entry: Entry
    @Environment(\.widgetFamily) private var family

    private var headline: String {
        if !entry.hasBattery { return "—" }
        if entry.plugged { return entry.charging ? (entry.snap.map { $0.minutesLeft > 0 ? duration($0.minutesLeft) : "\(entry.percent)%" } ?? "\(entry.percent)%") : "\(entry.percent)%" }
        if let m = entry.snap?.minutesLeft, m > 0 { return duration(m) }
        return "\(entry.percent)%"
    }
    private var caption: String {
        if !entry.hasBattery { return "No battery" }
        if entry.plugged { return entry.charging ? (entry.snap?.minutesLeft ?? 0 > 0 ? "to full" : "Charging") : "Plugged in" }
        return "left"
    }

    var body: some View {
        let summary = VStack(alignment: .leading, spacing: 4) {
            HStack { BatteryGlyph(percent: entry.percent, charging: entry.charging); Spacer(); Text("\(entry.percent)%").font(.system(size: 13, weight: .medium)).monospacedDigit() }
            Spacer(minLength: 0)
            Text(headline).font(.system(size: 34, weight: .semibold, design: .rounded)).monospacedDigit().minimumScaleFactor(0.6).lineLimit(1)
            Text(caption).font(.system(size: 12)).foregroundStyle(.secondary)
        }
        if family == .systemSmall {
            summary
        } else {
            HStack(spacing: 14) {
                summary.frame(maxWidth: 130)
                VStack(alignment: .leading, spacing: 7) {
                    Text("Used the most today").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    let apps = entry.snap?.apps ?? []
                    if apps.isEmpty { Text("Measured on battery, every five minutes.").font(.system(size: 11)).foregroundStyle(.secondary) }
                    ForEach(Array(apps.prefix(3).enumerated()), id: \.offset) { _, a in
                        HStack(spacing: 6) {
                            AppIcon(app: a)
                            Text(a.name).font(.system(size: 12)).lineLimit(1)
                            Spacer(minLength: 4)
                            Text(duration(a.minutes)).font(.system(size: 12)).monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }
}

struct WattlineWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "WattlineBattery", provider: Provider()) { entry in
            WidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
                .widgetURL(URL(string: "wattline://open"))
        }
        .configurationDisplayName("Battery Time")
        .description("Time left, and the apps that used the most battery today.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

@main
struct WattlineWidgets: WidgetBundle {
    var body: some Widget { WattlineWidget() }
}
