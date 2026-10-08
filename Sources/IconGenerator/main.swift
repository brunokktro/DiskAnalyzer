import AppKit
import CoreGraphics
import DiskAnalyzerCore
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Renders the app icon from code into a `.iconset` folder, which `iconutil -c icns`
// turns into `AppIcon.icns`. The tiles come from the app's own squarified treemap
// layout, so the icon is fully reproducible and the repo holds no binary assets.
//
//   swift run IconGenerator <output.iconset>

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: IconGenerator <output.iconset>\n".utf8))
    exit(64)
}
let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

/// Fixed sizes that the treemap divides; sorted descending as the algorithm expects.
let weights: [Double] = [34, 21, 13, 9, 8, 5, 4, 3, 2, 1]
let palette: [(Double, Double, Double)] = [
    (0.36, 0.55, 0.92), (0.93, 0.62, 0.24), (0.32, 0.72, 0.58), (0.86, 0.36, 0.42), (0.55, 0.47, 0.86),
    (0.30, 0.68, 0.84), (0.82, 0.42, 0.70), (0.62, 0.52, 0.38), (0.95, 0.78, 0.30), (0.62, 0.64, 0.70),
]

func color(_ rgb: (Double, Double, Double), _ alpha: Double = 1) -> CGColor {
    CGColor(srgbRed: rgb.0, green: rgb.1, blue: rgb.2, alpha: alpha)
}

func render(pixels: Int) -> CGImage? {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    let scale = Double(pixels) / 1024
    context.scaleBy(x: scale, y: scale)
    context.interpolationQuality = .high

    // macOS icon grid: 824 pt body centred on a 1024 canvas, continuous-corner radius ~185.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: CGColor(gray: 0, alpha: 0.35))
    context.addPath(shape)
    context.setFillColor(CGColor(gray: 0.1, alpha: 1))
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(shape)
    context.clip()
    let background = CGGradient(colorsSpace: space, colors: [color((0.10, 0.14, 0.27)), color((0.18, 0.24, 0.45))] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(background, start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 924), options: [])

    // Treemap panel.
    let panel = TreemapRect(x: 196, y: 196, width: 632, height: 632)
    let rects = TreemapLayout.squarify(weights: weights, in: panel)
    for (index, rect) in rects.enumerated() {
        let tile = CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height).insetBy(dx: 7, dy: 7)
        guard tile.width > 2, tile.height > 2 else { continue }
        let path = CGPath(roundedRect: tile, cornerWidth: min(28, tile.width / 4), cornerHeight: min(28, tile.height / 4), transform: nil)
        let rgb = palette[index % palette.count]
        let gradient = CGGradient(colorsSpace: space, colors: [color(rgb), color((rgb.0 * 0.78, rgb.1 * 0.78, rgb.2 * 0.78))] as CFArray, locations: [0, 1])!
        context.saveGState()
        context.addPath(path)
        context.clip()
        context.drawLinearGradient(gradient, start: CGPoint(x: tile.minX, y: tile.maxY), end: CGPoint(x: tile.maxX, y: tile.minY), options: [])
        // Soft top highlight for depth.
        context.setFillColor(CGColor(gray: 1, alpha: 0.12))
        context.fill(CGRect(x: tile.minX, y: tile.maxY - tile.height * 0.35, width: tile.width, height: tile.height * 0.35))
        context.restoreGState()
    }

    // Magnifying glass over the largest tile.
    let lensCenter = CGPoint(x: 640, y: 380)
    context.setShadow(offset: CGSize(width: 0, height: -6), blur: 18, color: CGColor(gray: 0, alpha: 0.45))
    context.setStrokeColor(CGColor(gray: 1, alpha: 1))
    context.setLineCap(.round)
    context.setLineWidth(46)
    context.move(to: CGPoint(x: lensCenter.x + 92, y: lensCenter.y - 92))
    context.addLine(to: CGPoint(x: lensCenter.x + 190, y: lensCenter.y - 190))
    context.strokePath()
    context.setShadow(offset: .zero, blur: 0, color: nil)
    context.setFillColor(CGColor(gray: 1, alpha: 0.22))
    context.fillEllipse(in: CGRect(x: lensCenter.x - 120, y: lensCenter.y - 120, width: 240, height: 240))
    context.setLineWidth(34)
    context.strokeEllipse(in: CGRect(x: lensCenter.x - 120, y: lensCenter.y - 120, width: 240, height: 240))
    context.restoreGState()

    // Hairline border.
    context.addPath(shape)
    context.setStrokeColor(CGColor(gray: 1, alpha: 0.12))
    context.setLineWidth(3)
    context.strokePath()
    return context.makeImage()
}

func write(_ image: CGImage, to url: URL) throws {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw CocoaError(.fileWriteUnknown)
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
}

// Names and pixel sizes required by iconutil(1).
let variants: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
do {
    for (name, pixels) in variants {
        guard let image = render(pixels: pixels) else { throw CocoaError(.fileWriteUnknown) }
        try write(image, to: output.appending(path: "\(name).png"))
    }
    print("Wrote \(variants.count) images to \(output.path(percentEncoded: false))")
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}
