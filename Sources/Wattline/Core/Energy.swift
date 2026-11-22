import AppKit
import Darwin

/// One process behind a slice.
struct ProcessUse: Identifiable, Hashable {
    var id: pid_t { pid }
    var pid: pid_t
    var name: String
    var watts: Double
    var estimated: Bool
}

/// An app, a command, a background service or a piece of macOS, with what it draws right now.
struct Consumer: Identifiable, Hashable {
    var id: String { identity.key }
    var identity: GroupIdentity
    var watts: Double
    var cpuWatts: Double
    var gpuWatts: Double
    var estimated: Bool
    var processes: [ProcessUse]
    var name: String { identity.name }
}

struct EnergyReading {
    var consumers: [Consumer] = []        // sorted, biggest first
    var systemWatts: Double = 0           // what the whole Mac draws
    var unaccountedWatts: Double = 0      // display, graphics, radios, macOS itself
    var interval: Double = 0
    var date = Date()
}

/// Reads the kernel's per-process energy counters and turns their change over time into watts per app.
///
/// It keeps only the previous counters, a few bytes per process; nothing runs between calls.
final class EnergyMonitor {
    struct Baseline {
        fileprivate var counters: [pid_t: Proc.Counters] = [:]
        fileprivate var gpu: [pid_t: UInt64] = [:]
        fileprivate var time: UInt64 = 0
        var isEmpty: Bool { time == 0 }
    }

    /// GPU power when a process keeps the GPU busy for a full second. Shared out by GPU time.
    var gpuWattsPerBusySecond: Double = {
        var size = 0
        sysctlbyname("hw.perflevel0.physicalcpu", nil, &size, nil, 0)
        var cores: Int32 = 0; size = MemoryLayout<Int32>.size
        sysctlbyname("hw.perflevel0.physicalcpu", &cores, &size, nil, 0)
        return cores >= 10 ? 14 : (cores >= 6 ? 9 : 5)
    }()

    private struct Meta { var name: String; var identity: GroupIdentity?; var stamp: Int }
    private var meta: [pid_t: Meta] = [:]
    private var stamp = 0
    private let ownPID = getpid()

    func baseline() -> Baseline {
        var b = Baseline()
        for pid in Proc.allPIDs() { if let c = Proc.counters(pid) { b.counters[pid] = c } }
        b.gpu = Proc.gpuTimes()
        b.time = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        return b
    }

    /// Watts per consumer since `baseline`, which then moves to now.
    func measure(since baseline: inout Baseline, systemWatts: Double) -> EnergyReading {
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let pids = Proc.allPIDs()
        var current: [pid_t: Proc.Counters] = [:]
        current.reserveCapacity(pids.count)
        for pid in pids { if let c = Proc.counters(pid) { current[pid] = c } }
        let gpuNow = Proc.gpuTimes()
        defer { baseline = Baseline(counters: current, gpu: gpuNow, time: now) }
        guard !baseline.isEmpty, now > baseline.time else { return EnergyReading(systemWatts: systemWatts) }
        let dt = Double(now - baseline.time) / 1e9

        // Per process: measured energy, or CPU time for processes the kernel doesn't bill.
        var raw: [(pid: pid_t, energyW: Double, cpuS: Double, gpuS: Double)] = []
        var billedW = 0.0, billedCPU = 0.0
        for (pid, c) in current {
            let prev = baseline.counters[pid]
            let e = prev.map { c.energy >= $0.energy ? Double(c.energy - $0.energy) : 0 } ?? 0
            let cpu = prev.map { c.cpu >= $0.cpu ? Double(c.cpu - $0.cpu) : 0 } ?? 0
            let g = gpuNow[pid].map { g in baseline.gpu[pid].map { g >= $0 ? Double(g - $0) : 0 } ?? 0 } ?? 0
            guard e > 0 || cpu > 0 || g > 0 else { continue }
            let w = e / dt / 1e9
            if w > 0 && cpu > 0 { billedW += w; billedCPU += cpu / 1e9 / dt }
            raw.append((pid, w, cpu / 1e9 / dt, g / 1e9 / dt))
        }
        // Watts per busy core, learned from the processes that do report energy.
        let wattsPerCore = billedCPU > 0.05 ? min(6, max(0.3, billedW / billedCPU)) : 1.5

        stamp &+= 1
        var groups: [GroupIdentity: (cpu: Double, gpu: Double, est: Bool, procs: [ProcessUse])] = [:]
        var estimatedTotal = 0.0
        for r in raw {
            guard let id = identity(for: r.pid) else { continue }
            let estimated = r.energyW == 0 && r.cpuS > 0
            let cpuW = estimated ? r.cpuS * wattsPerCore : r.energyW
            let gpuW = min(r.gpuS, 1) * gpuWattsPerBusySecond
            if estimated { estimatedTotal += cpuW }
            var g = groups[id] ?? (0, 0, false, [])
            g.cpu += cpuW; g.gpu += gpuW; g.est = g.est || estimated
            g.procs.append(ProcessUse(pid: r.pid, name: meta[r.pid]?.name ?? "\(r.pid)", watts: cpuW + gpuW, estimated: estimated))
            groups[id] = g
        }
        // Forget processes that have gone.
        if stamp % 8 == 0 { meta = meta.filter { current[$0.key] != nil || stamp - $0.value.stamp < 8 } }

        var consumers = groups.map { id, g in
            Consumer(identity: id, watts: g.cpu + g.gpu, cpuWatts: g.cpu, gpuWatts: g.gpu, estimated: g.est,
                     processes: g.procs.sorted { $0.watts > $1.watts })
        }
        // Measured energy is trusted; the battery's own reading can lag a few seconds behind, so the Mac's
        // total is never taken as less than what was measured plus a floor for the display and macOS.
        let total = consumers.reduce(0) { $0 + $1.watts }
        let measured = total - estimatedTotal
        var system = max(systemWatts, measured + 0.8)
        // Figures worked out from CPU time may never add up to more than the Mac is using.
        let room = max(0, system * 0.92 - measured)
        if estimatedTotal > room, estimatedTotal > 0 {
            let scale = room / estimatedTotal
            consumers = consumers.map { c in
                var c = c
                c.processes = c.processes.map { var p = $0; if p.estimated { p.watts *= scale }; return p }
                c.watts = c.processes.reduce(0) { $0 + $1.watts }
                return c
            }
        }
        system = max(system, consumers.reduce(0) { $0 + $1.watts } + 0.8)
        consumers.sort { $0.watts > $1.watts }
        let accounted = consumers.reduce(0) { $0 + $1.watts }
        return EnergyReading(consumers: consumers, systemWatts: system,
                             unaccountedWatts: max(0, system - accounted), interval: dt, date: Date())
    }

    // MARK: Grouping

    private func identity(for pid: pid_t) -> GroupIdentity? {
        if let m = meta[pid] { meta[pid]?.stamp = stamp; return m.identity }
        let short = Proc.short(pid)
        let path = Proc.path(pid)
        let name = path.map { ($0 as NSString).lastPathComponent } ?? short?.comm ?? "pid \(pid)"
        let id = resolve(pid: pid, name: name, path: path, short: short)
        meta[pid] = Meta(name: name, identity: id, stamp: stamp)
        return id
    }

    private func resolve(pid: pid_t, name: String, path: String?, short: Proc.Short?) -> GroupIdentity? {
        if Catalog.system.contains(name) { return nil }        // part of Display & System
        let rpid = Proc.responsible(pid)
        let app = NSRunningApplication(processIdentifier: rpid)

        if let app, let bundleID = app.bundleIdentifier, app.bundleURL != nil {
            // A command run in a terminal gets a slice of its own.
            if Catalog.terminals.contains(bundleID), pid != rpid, let root = commandRoot(of: pid, terminalPID: rpid) {
                let exe = (Proc.path(root).map { ($0 as NSString).lastPathComponent }) ?? name
                let cmd = Catalog.commandName(exe: exe, args: Proc.arguments(root))
                return GroupIdentity(key: "cmd:\(root)", kind: .command, name: cmd, bundlePath: app.bundleURL?.path,
                                     detail: "Running in \(app.localizedName ?? "a terminal")", appPID: root, terminalBadge: true)
            }
            if app.activationPolicy != .prohibited || bundleID.hasPrefix("com.apple.") == false {
                return GroupIdentity(key: "app:\(bundleID)", kind: .app, name: app.localizedName ?? name,
                                     bundlePath: app.bundleURL?.path, appPID: rpid, canQuit: rpid != ownPID)
            }
        }
        if let s = Catalog.services[name] {
            return GroupIdentity(key: "svc:\(s.name)", kind: .service, name: s.name, symbol: s.symbol, detail: s.detail, canQuit: false)
        }
        let lower = (path ?? name)
        for d in Catalog.devServices where lower.contains(d.match) {
            let p = d.appPath.flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil }
            return GroupIdentity(key: "bg:\(d.name)", kind: .background, name: d.name, bundlePath: p,
                                 symbol: p == nil ? "shippingbox" : nil, detail: "Running in the background")
        }
        if let path, path.hasPrefix("/opt/homebrew") || path.hasPrefix("/usr/local/Cellar") || path.hasPrefix("/usr/local/opt") {
            return GroupIdentity(key: "bg:\(name)", kind: .background, name: name, symbol: "mug", detail: "A Homebrew service")
        }
        // An app bundle that isn't running as an app (a login item or helper).
        if let path, let r = path.range(of: ".app/") {
            let bundle = String(path[..<r.lowerBound]) + ".app"
            if !bundle.hasPrefix("/System") {
                let display = FileManager.default.displayName(atPath: bundle).replacingOccurrences(of: ".app", with: "")
                return GroupIdentity(key: "app:\(bundle)", kind: .app, name: display, bundlePath: bundle, appPID: pid)
            }
        }
        if short?.uid == getuid() && !(path ?? "").hasPrefix("/System") && !(path ?? "").hasPrefix("/usr/libexec") && !(path ?? "").hasPrefix("/usr/sbin") {
            return GroupIdentity(key: "bg:\(name)", kind: .background, name: name, symbol: "terminal", detail: "A background process", appPID: pid)
        }
        return nil
    }

    /// Walks up from `pid` to the process a shell started: the command the user ran.
    private func commandRoot(of pid: pid_t, terminalPID: pid_t) -> pid_t? {
        var current = pid
        var hops = 0
        while hops < 32, let s = Proc.short(current) {
            if Catalog.shells.contains(s.comm) && current == pid { return nil }    // the shell itself
            guard s.ppid > 1, s.ppid != terminalPID else { return nil }
            if let parent = Proc.short(s.ppid), Catalog.shells.contains(parent.comm) { return current }
            current = s.ppid
            hops += 1
        }
        return nil
    }
}

/// What it costs: the time the battery would last longer without it.
enum Cost {
    /// T × Papp ⁄ (Psystem − Papp), in minutes.
    static func minutes(timeLeft: Double, app: Double, system: Double) -> Double {
        guard system > app, app > 0, timeLeft > 0 else { return 0 }
        return timeLeft * app / (system - app)
    }
}
