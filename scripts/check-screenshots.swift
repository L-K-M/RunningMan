import CoreGraphics
import Foundation
import ImageIO

/// Fail when a preview capture shows no section content. A blank capture is
/// still a valid, non-empty PNG: the toolbar renders and the area below it is
/// one flat colour. Real sections put text, cards and icons in that area.
///
/// The check samples the detail column (right of the sidebar, below the
/// toolbar) and measures how many pixels differ clearly from its most common
/// colour. Blank captures measure 0%; rendered sections measured 1.7% or more.
private let minimumDetailCoverage = 0.005
private let channelTolerance = 24
private let samplingWidth = 320

private enum CheckError: LocalizedError {
    case unreadable(String)
    var errorDescription: String? {
        switch self { case .unreadable(let path): return "Could not read \(path) as an image." }
    }
}

/// Fraction of detail-area pixels that differ from the dominant colour.
private func detailCoverage(of url: URL) throws -> Double {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        throw CheckError.unreadable(url.path)
    }
    // Downsample to a fixed width so the check costs the same at any scale.
    let width = samplingWidth
    let height = max(1, image.height * width / max(1, image.width))
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
        guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return true
    }
    guard drawn else { throw CheckError.unreadable(url.path) }

    // Rows run top to bottom in memory. Skip the sidebar (left 30%), the
    // toolbar (top 15%) and the window edges.
    let columns = (width * 30 / 100)..<(width * 95 / 100)
    let rows = (height * 15 / 100)..<(height * 95 / 100)
    var histogram: [UInt32: Int] = [:]
    var samples: [(UInt8, UInt8, UInt8)] = []
    for row in rows {
        for column in columns {
            let offset = (row * width + column) * 4
            let pixel = (pixels[offset], pixels[offset + 1], pixels[offset + 2])
            samples.append(pixel)
            histogram[UInt32(pixel.0) << 16 | UInt32(pixel.1) << 8 | UInt32(pixel.2), default: 0] += 1
        }
    }
    guard let dominant = histogram.max(by: { $0.value < $1.value })?.key, !samples.isEmpty else { return 0 }
    let background = (Int(dominant >> 16 & 0xFF), Int(dominant >> 8 & 0xFF), Int(dominant & 0xFF))
    let differing = samples.filter { pixel in
        abs(Int(pixel.0) - background.0) > channelTolerance
            || abs(Int(pixel.1) - background.1) > channelTolerance
            || abs(Int(pixel.2) - background.2) > channelTolerance
    }.count
    return Double(differing) / Double(samples.count)
}

let paths = CommandLine.arguments.dropFirst()
guard !paths.isEmpty else {
    FileHandle.standardError.write(Data("Usage: swift scripts/check-screenshots.swift IMAGE...\n".utf8))
    exit(2)
}
var blank: [String] = []
for path in paths {
    do {
        let coverage = try detailCoverage(of: URL(fileURLWithPath: path))
        print(String(format: "%@: %.1f%% detail coverage", (path as NSString).lastPathComponent, coverage * 100))
        if coverage < minimumDetailCoverage { blank.append((path as NSString).lastPathComponent) }
    } catch {
        FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
        blank.append((path as NSString).lastPathComponent)
    }
}
guard blank.isEmpty else {
    FileHandle.standardError.write(Data("Blank or unreadable preview captures: \(blank.joined(separator: ", "))\n".utf8))
    exit(1)
}
