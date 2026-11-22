import Foundation
import IOKit

/// Minimal read-only access to the System Management Controller.
/// Used for the battery temperature, which macOS no longer publishes in the registry.
final class SMC {
    static let shared = SMC()

    private struct KeyData {
        struct Vers { var major: UInt8 = 0, minor: UInt8 = 0, build: UInt8 = 0, reserved: UInt8 = 0, release: UInt16 = 0 }
        struct PLimit { var version: UInt16 = 0, length: UInt16 = 0, cpu: UInt32 = 0, gpu: UInt32 = 0, mem: UInt32 = 0 }
        struct Info { var size: UInt32 = 0, type: UInt32 = 0, attributes: UInt8 = 0, pad0: UInt8 = 0, pad1: UInt8 = 0, pad2: UInt8 = 0 } // padded to match the C layout
        var key: UInt32 = 0
        var vers = Vers()
        var pLimit = PLimit()
        var info = Info()
        var result: UInt8 = 0, status: UInt8 = 0, data8: UInt8 = 0
        var data32: UInt32 = 0
        var bytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) =
            (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)
    }

    private var conn: io_connect_t = 0
    private var infoCache: [UInt32: KeyData.Info] = [:]

    private init() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return }
        IOServiceOpen(service, mach_task_self_, 0, &conn)
        IOObjectRelease(service)
    }

    static func fourCC(_ s: String) -> UInt32 { s.utf8.reduce(0) { $0 << 8 | UInt32($1) } }

    private func call(_ input: inout KeyData) -> KeyData? {
        guard conn != 0 else { return nil }
        var output = KeyData()
        var size = MemoryLayout<KeyData>.stride
        let r = IOConnectCallStructMethod(conn, 2, &input, MemoryLayout<KeyData>.stride, &output, &size)
        return (r == kIOReturnSuccess && output.result == 0) ? output : nil
    }

    /// Raw bytes and type code for a key, or nil when the key doesn't exist.
    func read(_ key: String) -> (type: String, bytes: [UInt8])? {
        let k = Self.fourCC(key)
        var info = infoCache[k]
        if info == nil {
            var input = KeyData(); input.key = k; input.data8 = 9 // get key info
            guard let out = call(&input) else { return nil }
            info = out.info; infoCache[k] = out.info
        }
        guard let info, info.size > 0, info.size <= 32 else { return nil }
        var input = KeyData(); input.key = k; input.info.size = info.size; input.data8 = 5 // read bytes
        guard let out = call(&input) else { return nil }
        let all = withUnsafeBytes(of: out.bytes) { Array($0) }
        let t = info.type
        let type = String(bytes: [UInt8(t >> 24 & 0xff), UInt8(t >> 16 & 0xff), UInt8(t >> 8 & 0xff), UInt8(t & 0xff)], encoding: .ascii) ?? ""
        return (type, Array(all.prefix(Int(info.size))))
    }

    func double(_ key: String) -> Double? {
        guard let (type, b) = read(key) else { return nil }
        switch type {
        case "flt ": guard b.count >= 4 else { return nil }
            return Double(Float(bitPattern: UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24))
        case "sp78": guard b.count >= 2 else { return nil }
            return Double(Int16(bitPattern: UInt16(b[0]) << 8 | UInt16(b[1]))) / 256
        case "ui8 ": return b.first.map(Double.init)
        case "ui16": guard b.count >= 2 else { return nil }; return Double(UInt16(b[0]) << 8 | UInt16(b[1]))
        case "ui32": guard b.count >= 4 else { return nil }
            return Double(UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3]))
        default: return nil
        }
    }

    /// Battery temperature in °C: the average of the pack sensors that report a sane value.
    func batteryTemperature() -> Double? {
        let temps = ["TB0T", "TB1T", "TB2T"].compactMap(double).filter { $0 > 5 && $0 < 80 }
        return temps.isEmpty ? nil : temps.reduce(0, +) / Double(temps.count)
    }
}
