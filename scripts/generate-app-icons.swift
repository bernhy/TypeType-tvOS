/*
 * tvOS app branding. Draws an exact vector reproduction of the official
 * TypeType logo (TV-shaped mark) from assets/TypeType-logo.svg:
 * https://github.com/TypeType-Video/TypeType-Frontend/blob/main/apps/web/public/logo.svg
 *
 * XcodeGen invokes this script before creating the project. Layered PNGs are
 * generated on macOS, not committed, and stay out of git status.
 */
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let catalog = root.appendingPathComponent("TypeTypeTV/Assets.xcassets/App Icon & Top Shelf Image.brandassets")
let baseColor = CGColor(red: 0.035, green: 0.035, blue: 0.043, alpha: 1)
let markColor = CGColor(red: 239.0 / 255, green: 68.0 / 255, blue: 68.0 / 255, alpha: 1)

func drawLogo(_ ctx: CGContext, width: Int, height: Int) {
    let scale = CGFloat(height) * 0.96 / 256
    let logoSize = 256 * scale
    ctx.saveGState()
    // Original SVG uses top-left origin (viewBox 0 0 256 256).
    ctx.translateBy(x: (CGFloat(width) - logoSize) / 2,
                    y: (CGFloat(height) + logoSize) / 2)
    ctx.scaleBy(x: scale, y: -scale)
    ctx.setStrokeColor(markColor)
    ctx.setFillColor(markColor)
    ctx.setLineWidth(16)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.addPath(CGPath(roundedRect: CGRect(x: 32, y: 72, width: 192, height: 136),
                       cornerWidth: 8, cornerHeight: 8, transform: nil))
    ctx.strokePath()
    ctx.move(to: CGPoint(x: 80, y: 24))
    ctx.addLine(to: CGPoint(x: 128, y: 72))
    ctx.addLine(to: CGPoint(x: 176, y: 24))
    ctx.strokePath()
    ctx.fillEllipse(in: CGRect(x: 176, y: 104, width: 24, height: 24))
    ctx.fillEllipse(in: CGRect(x: 176, y: 152, width: 24, height: 24))
    ctx.move(to: CGPoint(x: 152, y: 208))
    ctx.addLine(to: CGPoint(x: 152, y: 72))
    ctx.strokePath()
    ctx.restoreGState()
}

func makePNG(width: Int, height: Int, kind: String, destination: URL) throws {
    let space = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(
        data: nil, width: width, height: height,
        bitsPerComponent: 8, bytesPerRow: 0, space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { throw NSError(domain: "TypeTypeIcon", code: 1) }
    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)
    if kind != "foreground" {
        ctx.setFillColor(baseColor)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    }
    if kind != "background" {
        drawLogo(ctx, width: width, height: height)
    }
    guard let image = ctx.makeImage(),
          let out = CGImageDestinationCreateWithURL(
              destination as CFURL, UTType.png.identifier as CFString, 1, nil
          ) else { throw NSError(domain: "TypeTypeIcon", code: 2) }
    try FileManager.default.createDirectory(
        at: destination.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    CGImageDestinationAddImage(out, image, nil)
    guard CGImageDestinationFinalize(out) else {
        throw NSError(domain: "TypeTypeIcon", code: 3)
    }
}

for (name, width, height) in [("Small", 400, 240), ("Large", 1280, 768)] {
    let directory = catalog.appendingPathComponent("App Icon - \(name).imagestack")
    for layer in ["Background", "Foreground"] {
        let path = directory.appendingPathComponent(
            "\(layer).imagestacklayer/Content.imageset/\(layer.lowercased()).png"
        )
        try makePNG(width: width, height: height, kind: layer.lowercased(),
                    destination: path)
    }
}
try makePNG(width: 1920, height: 720, kind: "topshelf",
            destination: catalog.appendingPathComponent("Top Shelf Image.imageset/topshelf.png"))
