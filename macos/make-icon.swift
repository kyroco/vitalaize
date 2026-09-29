// Draws the app icon: a dark rounded square holding a small board, three
// status bars in the chart colors the Trends tab uses. Writes a 1024 PNG.
import AppKit

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

let inset: CGFloat = 100
let tile = NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
NSColor(calibratedRed: 0.12, green: 0.10, blue: 0.09, alpha: 1).setFill()
NSBezierPath(roundedRect: tile, xRadius: 180, yRadius: 180).fill()

let screen = tile.insetBy(dx: 110, dy: 130)
NSColor(calibratedRed: 0.95, green: 0.94, blue: 0.93, alpha: 1).setFill()
NSBezierPath(roundedRect: screen, xRadius: 40, yRadius: 40).fill()

let colors = [
    NSColor(calibratedRed: 0x2a / 255, green: 0x78 / 255, blue: 0xd6 / 255, alpha: 1),
    NSColor(calibratedRed: 0xeb / 255, green: 0x68 / 255, blue: 0x34 / 255, alpha: 1),
    NSColor(calibratedRed: 0x1b / 255, green: 0xaf / 255, blue: 0x7a / 255, alpha: 1)
]
let heights: [CGFloat] = [0.45, 0.75, 0.6]
let barWidth = screen.width / 5
for (i, color) in colors.enumerated() {
    color.setFill()
    let x = screen.minX + barWidth * (0.75 + CGFloat(i) * 1.25)
    let h = (screen.height - 100) * heights[i]
    NSBezierPath(roundedRect: NSRect(x: x, y: screen.minY + 50, width: barWidth, height: h), xRadius: 18, yRadius: 18).fill()
}
image.unlockFocus()

let out = CommandLine.arguments[1]
let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
