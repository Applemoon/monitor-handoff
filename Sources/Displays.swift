import CoreGraphics
import Foundation

/// The displays macOS has, and the private call that removes one from the layout as if its
/// cable were pulled: CGSConfigureDisplayEnabled, the one display managers use. A removed
/// display drops out of every display list, so its id has to be kept to bring it back.
enum Displays {
    private typealias ConfigureEnabled = @convention(c) (CGDisplayConfigRef?, CGDirectDisplayID, Bool) -> CGError
    private static let configureEnabled: ConfigureEnabled? = {
        let lib = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY)
        return dlsym(lib, "CGSConfigureDisplayEnabled").map { unsafeBitCast($0, to: ConfigureEnabled.self) }
    }()

    static func active() -> [CGDirectDisplayID] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        CGGetActiveDisplayList(16, &ids, &count)
        return Array(ids.prefix(Int(count)))
    }

    /// The active display with these EDID vendor and product codes.
    static func find(vendor: UInt32, product: UInt32) -> CGDirectDisplayID? {
        active().first { CGDisplayVendorNumber($0) == vendor && CGDisplayModelNumber($0) == product }
    }

    /// For this login session only: after a logout the display is back whatever happened.
    static func setEnabled(_ id: CGDirectDisplayID, _ enabled: Bool) -> Bool {
        guard let configureEnabled else { return false }
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else { return false }
        guard configureEnabled(config, id, enabled) == .success else {
            CGCancelDisplayConfiguration(config)
            return false
        }
        return CGCompleteDisplayConfiguration(config, .forSession) == .success
    }
}
