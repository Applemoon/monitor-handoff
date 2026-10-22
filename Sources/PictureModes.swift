import Foundation

/// A picture mode the menu offers: the VCP write that turns it on, and the VCP value that says
/// it is on.
struct PictureMode {
    let name: String
    let set: (code: UInt8, value: UInt16)
    let isOn: (code: UInt8, value: UInt16)
}

/// The picture modes of the monitor. A model with a profile gets its own modes under the names
/// its menu shows; any other gets the standard MCCS color presets and display modes it declares.
struct PictureModes {
    let sections: [(title: String?, modes: [PictureMode])]

    /// What to read to see which modes are on.
    var codes: [UInt8] { Array(Set(sections.flatMap { $0.modes.map(\.isOn.code) })) }

    init?(_ capabilities: Capabilities) {
        if let model = capabilities.model, let profile = PictureModes.profiles[model] {
            sections = [(nil, profile)]
            return
        }
        let standard: [(title: String, code: UInt8, names: [UInt8: String])] = [
            ("Color", 0x14, PictureModes.colorPresets),
            ("Mode", 0xDC, PictureModes.displayModes),
        ]
        sections = standard.compactMap { section in
            let modes = capabilities.declared(section.code).map { value in
                PictureMode(name: section.names[value] ?? "Mode \(value)",
                            set: (section.code, UInt16(value)), isOn: (section.code, UInt16(value)))
            }
            return modes.isEmpty ? nil : (section.title, modes)
        }
        if sections.isEmpty { return nil }
    }

    // MCCS: VCP 14, select color preset.
    private static let colorPresets: [UInt8: String] = [
        0x01: "sRGB", 0x02: "Native", 0x03: "4000K", 0x04: "5000K", 0x05: "6500K", 0x06: "7500K",
        0x07: "8200K", 0x08: "9300K", 0x09: "10000K", 0x0A: "11500K", 0x0B: "User 1", 0x0C: "User 2",
        0x0D: "User 3",
    ]

    // MCCS: VCP DC, display application.
    private static let displayModes: [UInt8: String] = [
        0x00: "Standard", 0x01: "Productivity", 0x02: "Mixed", 0x03: "Movie", 0x04: "User Defined",
        0x05: "Games", 0x06: "Sports", 0x07: "Professional",
    ]

    private static func mode(_ name: String, _ code: UInt8, _ value: UInt16, preset: UInt16) -> PictureMode {
        PictureMode(name: name, set: (code, value), isOn: (0xE2, preset))
    }

    /// Mapped on the monitors themselves: each value written, the preset the monitor then reports,
    /// and the name its own menu shows for it.
    private static let profiles: [String: [PictureMode]] = [
        // Dell reports the preset in E2 but ignores writes there. Standard and Game 1 go through
        // the display mode (DC), sRGB, Warm, Cool and Custom Color through the color preset (14),
        // the rest through Dell's F0. DCI-P3 is named by its effect: the backlight drops to 15,
        // as the manual says it does.
        "AW2724DM": [
            mode("Standard", 0xDC, 0, preset: 0),
            mode("FPS", 0xF0, 15, preset: 32),
            mode("MOBA/RTS", 0xF0, 16, preset: 33),
            mode("RPG", 0xF0, 17, preset: 34),
            mode("SPORTS", 0xF0, 19, preset: 47),
            mode("Color Space: sRGB", 0x14, 1, preset: 11),
            mode("Color Space: DCI-P3", 0xF0, 10, preset: 27),
            mode("Game 1", 0xDC, 5, preset: 4),
            mode("Game 2", 0xF0, 13, preset: 30),
            mode("Game 3", 0xF0, 14, preset: 31),
            mode("Warm", 0x14, 11, preset: 14),
            mode("Cool", 0x14, 8, preset: 18),
            mode("Custom Color", 0x14, 12, preset: 20),
        ],
    ]
}
