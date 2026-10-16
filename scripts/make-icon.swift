import AppKit
import Foundation

/// Build a macOS icon from the canonical square PNG without drawing or cropping
/// artwork. The source's alpha and composition are preserved at every size.
private enum IconError: LocalizedError {
    case invalid(String)
    var errorDescription: String? {
        switch self { case .invalid(let message): return message }
    }
}

private func generateIcon() throws {
    guard CommandLine.arguments.count <= 3 else {
        throw IconError.invalid("Usage: swift scripts/make-icon.swift [OUTPUT_DIRECTORY] [SOURCE_PNG]")
    }
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    let output = CommandLine.arguments.count > 1
        ? URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        : root.appendingPathComponent("Resources", isDirectory: true)
    let source = CommandLine.arguments.count > 2
        ? URL(fileURLWithPath: CommandLine.arguments[2])
        : root.appendingPathComponent("Resources/AppIcon.png")
    let data = try Data(contentsOf: source)
    guard data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]),
          let bitmap = NSBitmapImageRep(data: data), let image = bitmap.cgImage else {
        throw IconError.invalid("The source icon must be a valid PNG: \(source.path)")
    }
    guard image.width == image.height, image.width >= 1024 else {
        throw IconError.invalid("The source icon must be square and at least 1024 × 1024 pixels; found \(image.width) × \(image.height).")
    }
    guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
        throw IconError.invalid("The sRGB color space is unavailable.")
    }

    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("runningman-icon-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: temporary) }
    let iconset = temporary.appendingPathComponent("RunningMan.iconset", isDirectory: true)
    try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: false)
    for size in [16, 32, 128, 256, 512] {
        for scale in [1, 2] {
            let pixels = size * scale
            guard let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8,
                bytesPerRow: pixels * 4, space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue), let _ = context.data else {
                throw IconError.invalid("Could not create the \(pixels)-pixel icon canvas.")
            }
            context.interpolationQuality = .high
            context.setBlendMode(.copy)
            context.draw(image, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
            guard let resized = context.makeImage(),
                  let png = NSBitmapImageRep(cgImage: resized).representation(using: .png, properties: [:]) else {
                throw IconError.invalid("Could not encode the \(pixels)-pixel icon.")
            }
            let suffix = scale == 2 ? "@2x" : ""
            try png.write(to: iconset.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
        }
    }
    let generated = temporary.appendingPathComponent("AppIcon.icns")
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    task.arguments = ["-c", "icns", iconset.path, "-o", generated.path]
    try task.run()
    task.waitUntilExit()
    guard task.terminationStatus == 0 else { throw IconError.invalid("iconutil failed (\(task.terminationStatus)).") }
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let destination = output.appendingPathComponent("AppIcon.icns")
    try Data(contentsOf: generated).write(to: destination, options: .atomic)
    print("Generated \(destination.path) from \(source.path)")
}

do { try generateIcon() }
catch {
    FileHandle.standardError.write(Data("make-icon: \(error.localizedDescription)\n".utf8))
    exit(1)
}
