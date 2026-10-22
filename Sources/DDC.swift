import Foundation
import IOKit

/// The external monitor's DDC/CI channel through IOAVService, the private I2C access Apple
/// Silicon Macs give to their display outputs. Every call blocks for tens of milliseconds,
/// so they run off the main thread. The channel stays open while the display is removed
/// from macOS, so a handed-over monitor can still be read.
final class DDC {
    private typealias Create = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
    private typealias Transfer = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn
    private typealias CopyEDID = @convention(c) (CFTypeRef, UnsafeMutablePointer<Unmanaged<CFData>?>) -> IOReturn

    private static let iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY)
    private static let create: Create? = symbol("IOAVServiceCreateWithService")
    private static let readI2C: Transfer? = symbol("IOAVServiceReadI2C")
    private static let writeI2C: Transfer? = symbol("IOAVServiceWriteI2C")
    private static let copyEDID: CopyEDID? = symbol("IOAVServiceCopyEDID")

    private static func symbol<T>(_ name: String) -> T? {
        dlsym(iokit, name).map { unsafeBitCast($0, to: T.self) }
    }

    private var service: CFTypeRef?

    /// The AV service of the external output. Dropped after a failed transfer and found
    /// again, since a reconnected cable brings a new one.
    private func externalService() -> CFTypeRef? {
        if let service { return service }
        guard let create = DDC.create else { return nil }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("DCPAVServiceProxy"), &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var entry = IOIteratorNext(iterator)
        while entry != 0 {
            let location = IORegistryEntryCreateCFProperty(entry, "Location" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
            if location == "External", let created = create(kCFAllocatorDefault, entry)?.takeRetainedValue() {
                service = created
                return created
            }
            IOObjectRelease(entry)
            entry = IOIteratorNext(iterator)
        }
        return nil
    }

    /// Sends a DDC packet: the bytes after the length byte's address, plus the checksum.
    private func send(_ bytes: [UInt8]) -> Bool {
        guard let service = externalService(), let write = DDC.writeI2C else { return false }
        var packet = bytes
        packet.append(bytes.reduce(UInt8(0x6E ^ 0x51), ^))
        let result = packet.withUnsafeMutableBytes { write(service, 0x37, 0x51, $0.baseAddress!, UInt32($0.count)) }
        if result != kIOReturnSuccess { self.service = nil }
        return result == kIOReturnSuccess
    }

    private func receive(_ count: Int) -> [UInt8]? {
        guard let service = externalService(), let read = DDC.readI2C else { return nil }
        var reply = [UInt8](repeating: 0, count: count)
        let result = reply.withUnsafeMutableBytes { read(service, 0x37, 0x51, $0.baseAddress!, UInt32(count)) }
        if result != kIOReturnSuccess { self.service = nil; return nil }
        return reply
    }

    /// A reply is valid when its last byte is the XOR of 0x50 and everything before it.
    private static func valid(_ reply: ArraySlice<UInt8>) -> Bool {
        reply.last == reply.dropLast().reduce(UInt8(0x50), ^)
    }

    /// A VCP feature's current and maximum values, or nil when the monitor does not answer.
    func read(_ code: UInt8) -> (current: UInt16, max: UInt16)? {
        for _ in 0..<3 {
            guard send([0x82, 0x01, code]) else { return nil }
            usleep(50_000)
            guard let r = receive(12) else { return nil }
            if DDC.valid(r[0..<11]), r[2] == 0x02, r[3] == 0x00, r[4] == code {
                return (UInt16(r[8]) << 8 | UInt16(r[9]), UInt16(r[6]) << 8 | UInt16(r[7]))
            }
            usleep(50_000)
        }
        return nil
    }

    func write(_ code: UInt8, _ value: UInt16) -> Bool {
        send([0x84, 0x03, code, UInt8(value >> 8), UInt8(value & 0xFF)])
    }

    /// The capabilities string, read in 32-byte chunks:
    /// "(prot(monitor)type(lcd)model(AW2724DM)...vcp(... 60( 0F 13 11) ...)...)".
    func capabilities() -> String? {
        var data: [UInt8] = []
        chunks: while data.count < 4096 {
            let offset = data.count
            for _ in 0..<3 {
                guard send([0x83, 0xF3, UInt8(offset >> 8), UInt8(offset & 0xFF)]) else { return nil }
                usleep(60_000)
                guard let r = receive(38) else { return nil }
                let length = Int(r[1] & 0x7F) - 3
                guard r[2] == 0xE3, (0...32).contains(length), DDC.valid(r[0..<(6 + length)]) else {
                    usleep(50_000)
                    continue
                }
                data += r[5..<(5 + length)]
                if length < 32 { break chunks }
                continue chunks
            }
            return nil
        }
        return String(bytes: data.prefix { $0 != 0 }, encoding: .ascii)
    }

    /// The monitor's EDID vendor and product codes, the numbers CGDisplayVendorNumber and
    /// CGDisplayModelNumber give for its display in macOS.
    func identity() -> (vendor: UInt32, product: UInt32)? {
        guard let service = externalService(), let copy = DDC.copyEDID else { return nil }
        var edid: Unmanaged<CFData>?
        guard copy(service, &edid) == kIOReturnSuccess, let data = edid?.takeRetainedValue() as Data?, data.count >= 12 else { return nil }
        return (UInt32(data[8]) << 8 | UInt32(data[9]), UInt32(data[10]) | UInt32(data[11]) << 8)
    }

    /// How many external outputs carry a monitor's DDC channel: the app handles one.
    static func externalCount() -> Int {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("DCPAVServiceProxy"), &iterator) == KERN_SUCCESS else { return 0 }
        defer { IOObjectRelease(iterator) }
        var count = 0
        var entry = IOIteratorNext(iterator)
        while entry != 0 {
            let location = IORegistryEntryCreateCFProperty(entry, "Location" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
            if location == "External" { count += 1 }
            IOObjectRelease(entry)
            entry = IOIteratorNext(iterator)
        }
        return count
    }

    /// The link type the monitor gets from this Mac ("HDMI", "DP"): the Transport property
    /// of the external framebuffer.
    static func downstream() -> String? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOMobileFramebufferShim"), &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var entry = IOIteratorNext(iterator)
        while entry != 0 {
            let transport = IORegistryEntryCreateCFProperty(entry, "Transport" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any]
            IOObjectRelease(entry)
            if let downstream = transport?["Downstream"] as? String { return downstream }
            entry = IOIteratorNext(iterator)
        }
        return nil
    }
}
