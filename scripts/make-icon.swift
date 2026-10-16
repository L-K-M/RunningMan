import AppKit
import Foundation

let output = CommandLine.arguments.count > 1 ? URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true) : URL(fileURLWithPath: "Resources", isDirectory: true)
let iconset = output.appendingPathComponent("RunningMan.iconset", isDirectory: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func stroke(_ points: [NSPoint], width: CGFloat, color: NSColor) {
    let path = NSBezierPath()
    path.move(to: points[0])
    for point in points.dropFirst() { path.line(to: point) }
    path.lineWidth = width
    path.lineCapStyle = .round
    path.lineJoinStyle = .round
    color.setStroke()
    path.stroke()
}

func draw() {
    let bounds = NSRect(x: 48, y: 48, width: 928, height: 928)
    let tile = NSBezierPath(roundedRect: bounds, xRadius: 205, yRadius: 205)
    NSGraphicsContext.saveGraphicsState()
    tile.addClip()
    NSGradient(starting: NSColor(srgbRed: 0.17, green: 0.20, blue: 0.70, alpha: 1),
               ending: NSColor(srgbRed: 0.38, green: 0.46, blue: 1, alpha: 1))!.draw(in: bounds, angle: 58)
    stroke([NSPoint(x: 210, y: 735), NSPoint(x: 390, y: 735)], width: 27, color: NSColor.white.withAlphaComponent(0.16))
    stroke([NSPoint(x: 170, y: 647), NSPoint(x: 300, y: 647)], width: 27, color: NSColor.white.withAlphaComponent(0.12))
    stroke([NSPoint(x: 215, y: 557), NSPoint(x: 280, y: 557)], width: 27, color: NSColor.white.withAlphaComponent(0.1))
    stroke([NSPoint(x: 248, y: 292), NSPoint(x: 372, y: 308), NSPoint(x: 492, y: 471), NSPoint(x: 585, y: 626)], width: 66, color: .white)
    stroke([NSPoint(x: 495, y: 471), NSPoint(x: 614, y: 386), NSPoint(x: 590, y: 255)], width: 66, color: .white)
    stroke([NSPoint(x: 570, y: 597), NSPoint(x: 447, y: 625), NSPoint(x: 366, y: 538)], width: 57, color: .white)
    stroke([NSPoint(x: 571, y: 594), NSPoint(x: 681, y: 529), NSPoint(x: 766, y: 579)], width: 57, color: .white)
    NSColor.white.setFill()
    NSBezierPath(ovalIn: NSRect(x: 582, y: 669, width: 112, height: 112)).fill()
    NSColor(srgbRed: 0.55, green: 0.98, blue: 0.77, alpha: 1).setFill()
    NSBezierPath(ovalIn: NSRect(x: 757, y: 205, width: 82, height: 82)).fill()
    NSGraphicsContext.restoreGraphicsState()
}

for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0)!
        let context = NSGraphicsContext(bitmapImageRep: bitmap)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let transform = AffineTransform(scale: CGFloat(pixels) / 1024)
        (transform as NSAffineTransform).concat()
        draw()
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        try bitmap.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", output.appendingPathComponent("AppIcon.icns").path]
try task.run()
task.waitUntilExit()
guard task.terminationStatus == 0 else { fatalError("iconutil failed") }
try FileManager.default.removeItem(at: iconset)
print("Generated \(output.appendingPathComponent("AppIcon.icns").path)")
