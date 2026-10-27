import AppKit
import ServiceManagement
import SwiftUI

/// The menu bar item: the monitor's inputs with the current one checked, a click switches.
@main
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private static var delegate: AppDelegate?

    static func main() {
        let app = NSApplication.shared
        delegate = AppDelegate() // NSApplication holds its delegate weakly
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    private let follower = Follower()
    private let updates = Updates()
    private var statusItem: NSStatusItem!
    private var snapshot = Snapshot()
    private var settings: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateIcon()
        // Open at Login is on from the first launch; the menu turns it off.
        if !UserDefaults.standard.bool(forKey: "loginItemSet") {
            try? SMAppService.mainApp.register()
            UserDefaults.standard.set(true, forKey: "loginItemSet")
        }
        follower.onChange = { [weak self] in
            self?.snapshot = $0
            self?.updateIcon()
        }
        follower.start()
        updates.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        follower.restore()
    }

    private func updateIcon() {
        statusItem.button?.image = snapshot.notResponding || snapshot.severalMonitors
            ? Icons.notResponding : snapshot.handedOver && !snapshot.disconnected ? Icons.handedOver : Icons.monitor
        // Not connected: the display dimmed, the look macOS gives an item that is off.
        statusItem.button?.appearsDisabled = snapshot.disconnected
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if snapshot.severalMonitors {
            menu.addItem(disabled: "Only one external monitor is supported")
        } else {
            addMonitorItems(to: menu)
        }
        menu.addItem(.separator())
        let configure = NSMenuItem(title: "Configure…", action: #selector(configure), keyEquivalent: ",")
        configure.target = self
        menu.addItem(configure)
        let login = NSMenuItem(title: "Open at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        if let version = updates.available {
            let update = NSMenuItem(title: "Update to \(version)", action: #selector(installUpdate), keyEquivalent: "")
            update.target = self
            menu.addItem(update)
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Monitor Handoff", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    @objc private func installUpdate() {
        updates.installAvailable()
    }

    /// The model, the brightness and the inputs.
    private func addMonitorItems(to menu: NSMenu) {
        menu.addItem(.sectionHeader(title: snapshot.model ?? "Monitor"))
        if snapshot.notResponding { menu.addItem(disabled: "Not responding") }
        if !snapshot.inputs.isEmpty && !snapshot.notResponding {
            let item = NSMenuItem()
            item.view = brightnessView()
            menu.addItem(item)
            let match = NSMenuItem(title: "Match Built-in Display", action: #selector(toggleMatchBuiltin), keyEquivalent: "")
            match.target = self
            match.state = UserDefaults.standard.bool(forKey: "matchBuiltin") ? .on : .off
            menu.addItem(match)
            if let modes = snapshot.pictureModes { menu.addItem(pictureModeItem(modes)) }
            menu.addItem(.separator())
        }
        if snapshot.inputs.isEmpty { menu.addItem(disabled: "Reading the monitor…") }
        // A hidden input still shows while the monitor is on it, so the check mark has a place.
        for code in snapshot.inputs where !Inputs.isHidden(code) || snapshot.current == code {
            let item = NSMenuItem(title: Inputs.name(code), action: #selector(select(_:)), keyEquivalent: "")
            item.target = self
            item.tag = Int(code)
            item.state = snapshot.current == code ? .on : .off
            // A renamed input keeps its port name, dimmed on the right.
            if Inputs.customName(code) != nil { item.badge = NSMenuItemBadge(string: Inputs.label(code)) }
            // This Mac's input: a laptop after the name, as an item image would indent all the others.
            if code == snapshot.own { item.attributedTitle = Icons.thisMac(after: Inputs.name(code)) }
            menu.addItem(item)
        }
    }

    @objc private func select(_ sender: NSMenuItem) {
        follower.select(UInt8(sender.tag))
    }

    private var shownModes: [PictureMode] = []

    /// Picture Mode, a submenu: the monitor's modes, checked by what the monitor reports once the
    /// read comes back, so a mode picked with its buttons is checked too.
    private func pictureModeItem(_ modes: PictureModes) -> NSMenuItem {
        let submenu = NSMenu()
        shownModes = []
        var items: [(NSMenuItem, PictureMode)] = []
        for section in modes.sections {
            if let title = section.title { submenu.addItem(.sectionHeader(title: title)) }
            for mode in section.modes {
                let item = NSMenuItem(title: mode.name, action: #selector(selectPictureMode(_:)), keyEquivalent: "")
                item.target = self
                item.tag = shownModes.count
                shownModes.append(mode)
                items.append((item, mode))
                submenu.addItem(item)
            }
        }
        follower.readPictureModes(modes.codes) { values in
            for (item, mode) in items { item.state = values[mode.isOn.code] == mode.isOn.value ? .on : .off }
        }
        let item = NSMenuItem(title: "Picture Mode", action: nil, keyEquivalent: "")
        item.submenu = submenu
        return item
    }

    @objc private func selectPictureMode(_ sender: NSMenuItem) {
        follower.setPictureMode(shownModes[sender.tag])
    }

    /// The brightness row: a slider between two suns, as in Control Center. It opens at the last
    /// value read and moves to the monitor's own once the read comes back.
    private func brightnessView() -> NSView {
        let slider = NSSlider(value: Double(brightness.value), minValue: 0, maxValue: Double(brightness.max),
                              target: self, action: #selector(brightnessChanged(_:)))
        slider.isContinuous = true
        slider.controlSize = .small
        // Matching the built-in screen, the slider only shows the level.
        slider.isEnabled = !UserDefaults.standard.bool(forKey: "matchBuiltin")
        let low = NSImageView(image: NSImage(systemSymbolName: "sun.min", accessibilityDescription: "Dimmer")!)
        let high = NSImageView(image: NSImage(systemSymbolName: "sun.max", accessibilityDescription: "Brighter")!)
        for sun in [low, high] { sun.contentTintColor = .secondaryLabelColor }
        let row = NSStackView(views: [low, slider, high])
        row.spacing = 6
        row.edgeInsets = NSEdgeInsets(top: 4, left: 14, bottom: 4, right: 14)
        row.frame = NSRect(x: 0, y: 0, width: 240, height: 28)
        follower.readBrightness { [weak self, weak slider] value, max in
            self?.brightness = (value, max)
            slider?.maxValue = Double(max)
            slider?.doubleValue = Double(value)
        }
        return row
    }

    private var brightness = (value: 50, max: 100)

    /// The monitor takes the built-in screen's brightness; the slider then only shows it.
    @objc private func toggleMatchBuiltin() {
        let defaults = UserDefaults.standard
        defaults.set(!defaults.bool(forKey: "matchBuiltin"), forKey: "matchBuiltin")
    }

    @objc private func brightnessChanged(_ sender: NSSlider) {
        brightness.value = Int(sender.doubleValue.rounded())
        follower.setBrightness(brightness.value)
    }

    @objc private func configure() {
        let view = SettingsView(inputs: snapshot.inputs, own: snapshot.own, detectedOwn: snapshot.detectedOwn)
        let window = settings ?? NSWindow(contentViewController: NSHostingController(rootView: view))
        window.contentViewController = NSHostingController(rootView: view)
        window.title = "Monitor Handoff"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        settings = window
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    @objc private func toggleLogin() {
        if SMAppService.mainApp.status == .enabled {
            try? SMAppService.mainApp.unregister()
        } else {
            try? SMAppService.mainApp.register()
        }
    }
}

private extension NSMenu {
    func addItem(disabled title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        addItem(item)
    }
}

/// The menu bar icons, all from the display symbol at one size.
enum Icons {
    private static let configuration = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)

    private static func symbol(_ name: String, _ description: String) -> NSImage? {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: description)?.withSymbolConfiguration(configuration)
        image?.isTemplate = true
        return image
    }

    static func thisMac(after name: String) -> NSAttributedString {
        let font = NSFont.menuFont(ofSize: 0)
        let title = NSMutableAttributedString(string: name + " ", attributes: [.font: font])
        let laptop = NSImage(systemSymbolName: "laptopcomputer", accessibilityDescription: "This Mac")?
            .withSymbolConfiguration(.init(pointSize: font.pointSize, weight: .regular).applying(.init(hierarchicalColor: .secondaryLabelColor)))
        if let laptop {
            let attachment = NSTextAttachment()
            attachment.image = laptop
            attachment.bounds = CGRect(x: 0, y: font.descender / 2, width: laptop.size.width, height: laptop.size.height)
            title.append(NSAttributedString(attachment: attachment))
        }
        return title
    }

    static let monitor = symbol("display", "Monitor")
    static let notResponding = symbol("display.trianglebadge.exclamationmark", "Monitor not responding")

    /// The display struck through: SF Symbols has no display.slash.
    static let handedOver: NSImage? = {
        guard let display = symbol("display", "Monitor handed over") else { return nil }
        let image = NSImage(size: display.size, flipped: false) { rect in
            display.draw(in: rect)
            let slash = NSBezierPath()
            slash.move(to: NSPoint(x: rect.minX + 1, y: rect.minY))
            slash.line(to: NSPoint(x: rect.maxX - 1, y: rect.maxY))
            NSColor.black.setStroke()
            // A gap cut around the line keeps it readable over the outline.
            NSGraphicsContext.current?.compositingOperation = .clear
            slash.lineWidth = 3.5
            slash.stroke()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            slash.lineWidth = 1.5
            slash.stroke()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Monitor handed over"
        return image
    }()
}
