// Draws icon.png, the 1024 px app icon on the macOS icon grid: swift icon.swift
import AppKit

let size = 1024.0
let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
    // The grid's rounded square: 824 px with a 185 px corner radius, centred.
    let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
    let shape = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)
    NSGraphicsContext.saveGraphicsState()
    let drop = NSShadow()
    drop.shadowColor = NSColor.black.withAlphaComponent(0.35)
    drop.shadowOffset = NSSize(width: 0, height: -10)
    drop.shadowBlurRadius = 24
    drop.set()
    NSColor(white: 0.1, alpha: 1).setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(starting: NSColor(white: 0.2, alpha: 1), ending: NSColor(white: 0.08, alpha: 1))!.draw(in: shape, angle: -90)

    func symbol(_ name: String, _ points: CGFloat, _ weight: NSFont.Weight, _ color: NSColor) -> NSImage {
        let configuration = NSImage.SymbolConfiguration(pointSize: points, weight: weight)
            .applying(.init(paletteColors: [color]))
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)!.withSymbolConfiguration(configuration)!
    }

    func draw(_ image: NSImage, centredAt centre: NSPoint, glow: NSColor) {
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = glow
        shadow.shadowBlurRadius = 36
        shadow.set()
        image.draw(in: NSRect(x: centre.x - image.size.width / 2, y: centre.y - image.size.height / 2,
                              width: image.size.width, height: image.size.height))
        NSGraphicsContext.restoreGraphicsState()
    }

    // The monitor drawn by hand: SF Symbols' display fills its screen white.
    let white = NSColor(white: 0.93, alpha: 1)
    let screen = NSBezierPath(roundedRect: NSRect(x: 232, y: 340, width: 560, height: 380), xRadius: 52, yRadius: 52)
    NSColor(white: 0.04, alpha: 1).setFill()
    screen.fill()
    NSGraphicsContext.saveGraphicsState()
    let halo = NSShadow()
    halo.shadowColor = white.withAlphaComponent(0.3)
    halo.shadowBlurRadius = 30
    halo.set()
    white.set()
    screen.lineWidth = 34
    screen.stroke()
    NSBezierPath(rect: NSRect(x: 477, y: 262, width: 70, height: 62)).fill()
    NSBezierPath(roundedRect: NSRect(x: 382, y: 232, width: 260, height: 40), xRadius: 20, yRadius: 20).fill()
    NSGraphicsContext.restoreGraphicsState()
    // The handoff: green to this Mac, orange to the other computer.
    let green = NSColor(red: 0.2, green: 0.85, blue: 0.35, alpha: 1)
    let orange = NSColor(red: 1, green: 0.55, blue: 0.15, alpha: 1)
    draw(symbol("arrow.left", 130, .bold, green), centredAt: NSPoint(x: 432, y: 530), glow: green)
    draw(symbol("arrow.right", 130, .bold, orange), centredAt: NSPoint(x: 592, y: 530), glow: orange)
    return true
}
let png = NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: "icon.png"))
