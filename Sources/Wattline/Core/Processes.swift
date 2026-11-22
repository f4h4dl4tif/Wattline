import AppKit
import Darwin

@_silgen_name("responsibility_get_pid_responsible_for_pid")
private func responsibility_get_pid_responsible_for_pid(_ pid: pid_t) -> pid_t

/// Small, allocation-light helpers around libproc / sysctl.
enum Proc {
    static func allPIDs() -> [pid_t] {
        let n = proc_listallpids(nil, 0)
        guard n > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(n) + 64)
        let got = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        return got > 0 ? Array(pids.prefix(Int(got)).filter { $0 > 0 }) : []
    }

    struct Short { var ppid: pid_t; var uid: uid_t; var comm: String }

    static func short(_ pid: pid_t) -> Short? {
        var info = proc_bsdshortinfo()
        let size = Int32(MemoryLayout<proc_bsdshortinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, size) == size else { return nil }
        let comm = withUnsafeBytes(of: info.pbsi_comm) { raw -> String in
            let bytes = raw.bindMemory(to: CChar.self)
            return String(cString: bytes.baseAddress!)
        }
        return Short(ppid: pid_t(info.pbsi_ppid), uid: info.pbsi_uid, comm: comm)
    }

    static func path(_ pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: 4096)
        return proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 ? String(cString: buf) : nil
    }

    static func responsible(_ pid: pid_t) -> pid_t {
        let r = responsibility_get_pid_responsible_for_pid(pid)
        return r > 0 ? r : pid
    }

    /// The command line of a process the user owns: executable path and arguments.
    static func arguments(_ pid: pid_t) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return [] }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0, size > 4 else { return [] }
        let argc = Int(buf.withUnsafeBytes { $0.load(as: Int32.self) })
        var i = 4
        while i < size && buf[i] != 0 { i += 1 }       // executable path
        while i < size && buf[i] == 0 { i += 1 }       // padding
        var args: [String] = []
        var start = i
        while i < size && args.count < min(argc, 6) {
            if buf[i] == 0 {
                args.append(String(decoding: buf[start..<i], as: UTF8.self))
                start = i + 1
            }
            i += 1
        }
        return args
    }

    struct Counters { var energy: UInt64; var cpu: UInt64 }

    private static let timebase: Double = {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        return Double(tb.numer) / Double(tb.denom)
    }()

    /// Energy (nJ, billed by the kernel) and CPU time (ns). Nil for processes we may not inspect.
    static func counters(_ pid: pid_t) -> Counters? {
        var ri = rusage_info_v6()
        let ok = withUnsafeMutablePointer(to: &ri) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V6, $0) }
        }
        guard ok == 0 else { return nil }
        let cpu = Double(ri.ri_user_time + ri.ri_system_time) * timebase
        return Counters(energy: ri.ri_energy_nj, cpu: UInt64(cpu))
    }

    /// Accumulated GPU time (ns) per process, from the GPU driver's user clients.
    static func gpuTimes() -> [pid_t: UInt64] {
        var result: [pid_t: UInt64] = [:]
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &it) == KERN_SUCCESS else { return result }
        defer { IOObjectRelease(it) }
        var accel = IOIteratorNext(it)
        while accel != 0 {
            var children: io_iterator_t = 0
            if IORegistryEntryGetChildIterator(accel, kIOServicePlane, &children) == KERN_SUCCESS {
                var c = IOIteratorNext(children)
                while c != 0 {
                    if let creator = IORegistryEntryCreateCFProperty(c, "IOUserClientCreator" as CFString, nil, 0)?.takeRetainedValue() as? String,
                       let usage = IORegistryEntryCreateCFProperty(c, "AppUsage" as CFString, nil, 0)?.takeRetainedValue() as? [[String: Any]],
                       creator.hasPrefix("pid "),
                       let pid = pid_t(creator.dropFirst(4).prefix { $0.isNumber }) {
                        let t = usage.reduce(UInt64(0)) { $0 + ((($1["accumulatedGPUTime"] as? NSNumber)?.uint64Value) ?? 0) }
                        result[pid, default: 0] += t
                    }
                    IOObjectRelease(c)
                    c = IOIteratorNext(children)
                }
                IOObjectRelease(children)
            }
            IOObjectRelease(accel)
            accel = IOIteratorNext(it)
        }
        return result
    }
}

/// What a slice stands for.
enum ConsumerKind: String, Codable { case app, command, service, background, system }

/// How a process is shown: which group it belongs to and what that group looks like.
struct GroupIdentity: Hashable {
    var key: String
    var kind: ConsumerKind
    var name: String
    var bundlePath: String?      // for the icon
    var symbol: String?          // SF Symbol for macOS services
    var detail: String?          // a line about what it's doing
    var appPID: pid_t?
    var terminalBadge = false
    var canQuit = true
}

/// Knows macOS's own daemons, terminals and common developer services.
enum Catalog {
    static let terminals: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.warp.Warp-Stable",
        "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "net.kovidgoyal.kitty", "io.alacritty",
        "co.zeit.hyper", "dev.zed.Zed", "com.todesktop.230313mzl4w4u92", "com.exafunction.windsurf",
        "com.jetbrains.intellij", "com.jetbrains.pycharm", "com.jetbrains.WebStorm", "com.apple.dt.Xcode",
    ]
    static let shells: Set<String> = ["zsh", "bash", "fish", "sh", "login", "nu", "tcsh", "dash", "-zsh", "-bash"]

    struct Service { let name: String; let symbol: String; let detail: String }
    static let services: [String: Service] = {
        var m: [String: Service] = [:]
        func add(_ names: [String], _ s: Service) { names.forEach { m[$0] = s } }
        add(["mds", "mds_stores", "mdworker", "mdworker_shared", "mdsync", "corespotlightd", "mdbulkimport"],
            Service(name: "Spotlight", symbol: "magnifyingglass", detail: "Indexing your files so search can find them"))
        add(["bird", "cloudd", "fileproviderd", "CloudDocsDaemon", "cloudphotod", "itunescloudd"],
            Service(name: "iCloud", symbol: "icloud", detail: "Syncing iCloud Drive and other iCloud data"))
        add(["photoanalysisd", "mediaanalysisd", "photolibraryd", "PhotosReliveWidget"],
            Service(name: "Photos", symbol: "photo.on.rectangle.angled", detail: "Analyzing your photo library for people and memories"))
        add(["backupd", "backupd-helper"], Service(name: "Time Machine", symbol: "clock.arrow.circlepath", detail: "Backing up your Mac"))
        add(["softwareupdated", "SoftwareUpdateNotificationManager", "mobileassetd"],
            Service(name: "Software Update", symbol: "arrow.down.circle", detail: "Checking for and downloading updates"))
        add(["airportd", "wifid", "wifip2pd", "wifianalyticsd"], Service(name: "Wi‑Fi", symbol: "wifi", detail: "Keeping the Wi‑Fi connection up"))
        add(["bluetoothd", "BTLEServer", "bluetoothuserd"], Service(name: "Bluetooth", symbol: "dot.radiowaves.right", detail: "Talking to your Bluetooth accessories"))
        add(["coreaudiod", "audiomxd", "AudioComponentRegistrar"], Service(name: "Sound", symbol: "speaker.wave.2", detail: "Playing and mixing audio"))
        add(["sharingd", "AirPlayXPCHelper", "rapportd"], Service(name: "AirDrop & Handoff", symbol: "airplay.audio", detail: "Looking for nearby devices"))
        add(["siriactionsd", "assistantd", "siriknowledged", "suggestd"], Service(name: "Siri & Suggestions", symbol: "sparkles", detail: "Learning from your apps to make suggestions"))
        add(["XprotectService", "XProtect", "syspolicyd", "trustd"], Service(name: "Security", symbol: "lock.shield", detail: "Checking apps and files are safe"))
        add(["nsurlsessiond", "apsd"], Service(name: "Background Downloads", symbol: "arrow.down.app", detail: "Downloads apps asked macOS to finish"))
        add(["intelligenceplatformd", "modelmanagerd", "generativeexperiencesd"],
            Service(name: "Apple Intelligence", symbol: "apple.intelligence", detail: "Running on-device models"))
        add(["mediaremoted", "mediaserverd"], Service(name: "Media", symbol: "play.circle", detail: "Handling playback controls"))
        add(["locationd"], Service(name: "Location Services", symbol: "location", detail: "Working out where your Mac is"))
        add(["spindump", "ReportCrash", "diagnosticd", "logd", "symptomsd"], Service(name: "Diagnostics", symbol: "stethoscope", detail: "Collecting logs and reports"))
        return m
    }()

    /// Absorbed by Display & System rather than given a slice.
    static let system: Set<String> = ["kernel_task", "WindowServer", "launchd", "loginwindow", "Dock", "SystemUIServer", "ControlCenter", "powerd", "hidd", "runningboardd"]

    static let devServices: [(match: String, name: String, appPath: String?)] = [
        ("com.docker", "Docker", "/Applications/Docker.app"), ("Docker", "Docker", "/Applications/Docker.app"),
        ("ollama", "Ollama", "/Applications/Ollama.app"), ("qemu-system", "Virtual Machine", nil),
        ("postgres", "PostgreSQL", nil), ("mysqld", "MySQL", nil), ("redis-server", "Redis", nil), ("mongod", "MongoDB", nil),
    ]

    /// claude-code, not node.
    static func commandName(exe: String, args: [String]) -> String {
        let interpreters: Set<String> = ["node", "python", "python3", "ruby", "bun", "deno", "java", "perl", "php", "npm", "npx", "pnpm", "yarn", "uv"]
        let joined = args.joined(separator: " ").lowercased()
        if joined.contains("claude") && (exe == "node" || exe == "claude" || joined.contains("claude-code")) { return "claude-code" }
        if interpreters.contains(exe) {
            for a in args.dropFirst() where !a.hasPrefix("-") {
                let base = (a as NSString).lastPathComponent
                let stem = (base as NSString).deletingPathExtension
                if !stem.isEmpty && !["index", "main", "cli", "run"].contains(stem) { return stem }
                let parent = ((a as NSString).deletingLastPathComponent as NSString).lastPathComponent
                if !parent.isEmpty && parent != "bin" && parent != "dist" { return parent }
            }
        }
        return exe
    }
}
