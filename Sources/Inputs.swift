import Foundation

/// The monitor's inputs as DDC codes (VCP 0x60) and what the user calls them.
enum Inputs {
    static func label(_ code: UInt8) -> String {
        switch code {
        case 0x01: "VGA 1"
        case 0x02: "VGA 2"
        case 0x03: "DVI 1"
        case 0x04: "DVI 2"
        case 0x0F: "DP 1"
        case 0x10, 0x13: "DP 2" // 0x13: Dell and HP give their second DisplayPort this code
        case 0x11: "HDMI 1"
        case 0x12: "HDMI 2"
        case 0x1B: "USB-C"
        default: "Input \(code)"
        }
    }

    static func customName(_ code: UInt8) -> String? {
        let name = UserDefaults.standard.string(forKey: "name.\(code)") ?? ""
        return name.isEmpty ? nil : name
    }

    static func name(_ code: UInt8) -> String {
        customName(code) ?? label(code)
    }

    static func isHidden(_ code: UInt8) -> Bool {
        UserDefaults.standard.bool(forKey: "hidden.\(code)")
    }

    /// This Mac's input: the one picked in Configure, else the one detected.
    static func own(among inputs: [UInt8], downstream: String?) -> UInt8? {
        let picked = UserDefaults.standard.integer(forKey: "ownInput")
        if picked != 0, inputs.contains(UInt8(picked)) { return UInt8(picked) }
        return detectedOwn(among: inputs, downstream: downstream)
    }

    /// The only input of the link type the monitor gets from this Mac; nil when the
    /// monitor has two of that type.
    static func detectedOwn(among inputs: [UInt8], downstream: String?) -> UInt8? {
        let codes: Set<UInt8> = switch downstream {
        case "HDMI": [0x11, 0x12]
        case "DP": [0x0F, 0x10, 0x13, 0x1B]
        default: []
        }
        let candidates = inputs.filter(codes.contains)
        return candidates.count == 1 ? candidates[0] : nil
    }
}

/// What the monitor says about itself in its capabilities string.
struct Capabilities {
    let model: String?
    let inputs: [UInt8]

    init(_ string: String) {
        model = string.firstMatch(of: #/model\(([^)]*)\)/#).map { String($0.1) }
        inputs = string.firstMatch(of: #/[ (]60\(([0-9A-Fa-f ]*)\)/#)
            .map { $0.1.split(separator: " ").compactMap { UInt8($0, radix: 16) } } ?? []
    }
}
