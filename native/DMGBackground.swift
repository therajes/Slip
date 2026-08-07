import AppKit

guard CommandLine.arguments.count == 2 else { exit(2) }
let size = NSSize(width: 760, height: 480)
let image = NSImage(size: size)
image.lockFocus()
let canvas = NSRect(origin: .zero, size: size)
NSGradient(colors: [
    NSColor(calibratedRed: 0.025, green: 0.045, blue: 0.11, alpha: 1),
    NSColor(calibratedRed: 0.05, green: 0.12, blue: 0.20, alpha: 1),
    NSColor(calibratedRed: 0.04, green: 0.07, blue: 0.16, alpha: 1)
])!.draw(in: canvas, angle: -20)

func glow(_ rect: NSRect, _ color: NSColor) {
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow(); shadow.shadowColor = color.withAlphaComponent(0.8); shadow.shadowBlurRadius = 90; shadow.shadowOffset = .zero; shadow.set()
    color.withAlphaComponent(0.2).setFill(); NSBezierPath(ovalIn: rect).fill()
    NSGraphicsContext.restoreGraphicsState()
}
glow(NSRect(x: -80, y: 270, width: 280, height: 250), .systemBlue)
glow(NSRect(x: 570, y: -90, width: 270, height: 250), .systemTeal)

func text(_ value: String, _ rect: NSRect, _ font: NSFont, _ color: NSColor) {
    let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .center
    value.draw(in: rect, withAttributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph])
}
text("Slip", NSRect(x: 80, y: 398, width: 600, height: 52), .systemFont(ofSize: 31, weight: .bold), .white)
text("Native iPhone sideloading, refined.", NSRect(x: 80, y: 372, width: 600, height: 30), .systemFont(ofSize: 14, weight: .medium), .white.withAlphaComponent(0.64))

let y: CGFloat = 240
let rail = NSRect(x: 282, y: y - 1.5, width: 196, height: 3)
NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow(); shadow.shadowColor = NSColor.systemBlue.withAlphaComponent(0.75); shadow.shadowBlurRadius = 17; shadow.shadowOffset = .zero; shadow.set()
NSBezierPath(roundedRect: rail, xRadius: 2, yRadius: 2).addClip()
NSGradient(colors: [.systemBlue.withAlphaComponent(0.12), NSColor(calibratedRed: 0.2, green: 0.78, blue: 1, alpha: 0.95), .systemTeal.withAlphaComponent(0.35)])!.draw(in: rail, angle: 0)
NSGraphicsContext.restoreGraphicsState()
for (index, x) in [318.0, 354.0, 390.0, 426.0].enumerated() {
    text("›", NSRect(x: x - 22, y: y - 33, width: 44, height: 58), .systemFont(ofSize: 43, weight: .medium), .white.withAlphaComponent(0.18 + CGFloat(index) * 0.18))
}
text("DRAG TO APPLICATIONS", NSRect(x: 280, y: y + 34, width: 200, height: 20), .systemFont(ofSize: 10, weight: .bold), .white.withAlphaComponent(0.46))
text("1", NSRect(x: 178, y: 305, width: 24, height: 22), .monospacedDigitSystemFont(ofSize: 13, weight: .bold), .white.withAlphaComponent(0.72))
text("2", NSRect(x: 558, y: 305, width: 24, height: 22), .monospacedDigitSystemFont(ofSize: 13, weight: .bold), .white.withAlphaComponent(0.72))

func plate(_ rect: NSRect) {
    NSGraphicsContext.saveGraphicsState(); let s = NSShadow(); s.shadowColor = .black.withAlphaComponent(0.28); s.shadowBlurRadius = 11; s.shadowOffset = NSSize(width: 0, height: -2); s.set()
    NSColor.white.withAlphaComponent(0.78).setFill(); NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2).fill(); NSGraphicsContext.restoreGraphicsState()
}
plate(NSRect(x: 143, y: 149, width: 95, height: 28)); plate(NSRect(x: 504, y: 149, width: 132, height: 28))
text("Open Slip from Applications, then connect and trust your iPhone.", NSRect(x: 100, y: 34, width: 560, height: 24), .systemFont(ofSize: 12, weight: .medium), .white.withAlphaComponent(0.56))

image.unlockFocus()
guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]) else { exit(1) }
try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]), options: .atomic)
