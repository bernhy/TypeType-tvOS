/*
 * TypeType tvOS icon pipeline.
 *
 * Vector artwork: assets/TypeType-logo.svg (Rotmetall).
 * CoreGraphics reproduces the SVG's original TV geometry, four extruded
 * shadow layers, anodized-metal gradient, metallic knobs and specular rim.
 *
 * XcodeGen runs this script before generating the Xcode project. The layered
 * App Icon PNGs, Top Shelf image and TypeTypeLogo sidebar PNG are generated
 * from the same vector primitives; do not commit generated PNGs.
 */
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let catalog = root.appendingPathComponent(
    "TypeTypeTV/Assets.xcassets/App Icon & Top Shelf Image.brandassets"
)
let sourceURL = root.appendingPathComponent("assets/TypeType-logo.svg")
let svg = try String(contentsOf: sourceURL, encoding: .utf8)
// Fail rather than silently shipping the previous flat artwork if the
// source SVG is replaced without updating its paired vector renderer.
guard svg.contains("id=\"anod\""), svg.contains("id=\"metalDot\""),
      svg.contains("M152 208V72"), svg.contains("points=\"80 24 128 72 176 24\"") else {
    fatalError("Expected Rotmetall TypeType-logo.svg; update the icon renderer as well.")
}

func color(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
    CGColor(
        red: CGFloat((hex >> 16) & 0xff) / 255,
        green: CGFloat((hex >> 8) & 0xff) / 255,
        blue: CGFloat(hex & 0xff) / 255,
        alpha: alpha
    )
}
let baseColor = color(0x09090b)

func strokeGeometry() -> CGPath {
    let path = CGMutablePath()
    path.addRoundedRect(
        in: CGRect(x: 32, y: 72, width: 192, height: 136),
        cornerWidth: 8, cornerHeight: 8
    )
    path.move(to: CGPoint(x: 80, y: 24))
    path.addLine(to: CGPoint(x: 128, y: 72))
    path.addLine(to: CGPoint(x: 176, y: 24))
    path.move(to: CGPoint(x: 152, y: 208))
    path.addLine(to: CGPoint(x: 152, y: 72))
    return path
}
let markPath = strokeGeometry()
let knobRects = [
    CGRect(x: 176, y: 104, width: 24, height: 24),
    CGRect(x: 176, y: 152, width: 24, height: 24)
]

func applyStrokeStyle(_ ctx: CGContext, width: CGFloat) {
    ctx.setLineWidth(width)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
}

func flatLayer(
    _ ctx: CGContext, x: CGFloat = 0, y: CGFloat = 0,
    lineColor: UInt32, dotColor: UInt32? = nil,
    alpha: CGFloat = 1, width: CGFloat = 16
) {
    ctx.saveGState()
    ctx.translateBy(x: x, y: y)
    ctx.setAlpha(alpha)
    applyStrokeStyle(ctx, width: width)
    ctx.setStrokeColor(color(lineColor))
    ctx.addPath(markPath)
    ctx.strokePath()
    ctx.setFillColor(color(dotColor ?? lineColor))
    for rect in knobRects { ctx.fillEllipse(in: rect) }
    ctx.restoreGState()
}

func makeGradient(_ stops: [(CGFloat, UInt32)]) -> CGGradient {
    let space = CGColorSpaceCreateDeviceRGB()
    let colors = stops.map { color($0.1) } as CFArray
    let locations = stops.map { $0.0 }
    guard let result = CGGradient(
        colorsSpace: space, colors: colors, locations: locations
    ) else { fatalError("Cannot create TypeType Rotmetall gradient") }
    return result
}
let redMetal = makeGradient([
    (0, 0xffe8df), (0.16, 0xfd9a92), (0.27, 0xf2474c),
    (0.48, 0xbb1d31), (0.56, 0xfd6670), (0.70, 0xd42b41),
    (1, 0x741326)
])
let knobMetal = makeGradient([
    (0, 0xffe2d5), (0.27, 0xff8a85), (0.44, 0xd63145),
    (0.60, 0xf35762), (1, 0x831b32)
])

func metalLayer(_ ctx: CGContext) {
    // Fill the stroked geometry with the same anodized-red palette as the
    // SVG's #anod gradient; CGContext draws its colors under a clipping path.
    ctx.saveGState()
    applyStrokeStyle(ctx, width: 16)
    ctx.addPath(markPath)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    ctx.drawLinearGradient(
        redMetal, start: CGPoint(x: 28, y: 20),
        end: CGPoint(x: 218, y: 213),
        options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
    )
    ctx.restoreGState()

    for rect in knobRects {
        ctx.saveGState()
        ctx.addEllipse(in: rect)
        ctx.clip()
        ctx.drawLinearGradient(
            knobMetal,
            start: CGPoint(x: rect.minX, y: rect.minY),
            end: CGPoint(x: rect.maxX, y: rect.maxY),
            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
        )
        ctx.restoreGState()
    }
}

func drawLogo(_ ctx: CGContext, width: Int, height: Int) {
    let scale = CGFloat(height) * 0.96 / 256
    let logoSize = 256 * scale
    ctx.saveGState()
    // SVG coordinates use a top-left origin.
    ctx.translateBy(
        x: (CGFloat(width) - logoSize) / 2,
        y: (CGFloat(height) + logoSize) / 2
    )
    ctx.scaleBy(x: scale, y: -scale)

    // Depth: identical offsets, opacity and shading to 04-rotmetall.svg.
    flatLayer(ctx, x: 6, y: 6.7, lineColor: 0x2c0a19, alpha: 0.20)
    flatLayer(ctx, x: 4.6, y: 5, lineColor: 0x4b0f22, alpha: 0.45)
    flatLayer(ctx, x: 3, y: 3.5, lineColor: 0x731e2b, alpha: 0.78)
    flatLayer(ctx, x: 1.5, y: 1.8, lineColor: 0xae2639)

    metalLayer(ctx)
    // Narrow, offset white reflection across the enamel surface.
    flatLayer(ctx, x: -1.45, y: -1.5,
              lineColor: 0xfff0eb, alpha: 0.42, width: 3.7)
    flatLayer(ctx, lineColor: 0x781a2d, dotColor: 0x771b2f,
              alpha: 0.24, width: 1.6)
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
          let output = CGImageDestinationCreateWithURL(
              destination as CFURL, UTType.png.identifier as CFString, 1, nil
          ) else { throw NSError(domain: "TypeTypeIcon", code: 2) }
    try FileManager.default.createDirectory(
        at: destination.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    CGImageDestinationAddImage(output, image, nil)
    guard CGImageDestinationFinalize(output) else {
        throw NSError(domain: "TypeTypeIcon", code: 3)
    }
}

for (name, width, height) in [
    ("Small", 400, 240),
    ("Large", 1280, 768)
] {
    let directory = catalog.appendingPathComponent("App Icon - \(name).imagestack")
    for layer in ["Background", "Foreground"] {
        let path = directory.appendingPathComponent(
            "\(layer).imagestacklayer/Content.imageset/\(layer.lowercased()).png"
        )
        try makePNG(width: width, height: height, kind: layer.lowercased(),
                    destination: path)
    }
}

try makePNG(
    width: 1920, height: 720, kind: "topshelf",
    destination: catalog.appendingPathComponent("Top Shelf Image.imageset/topshelf.png")
)
// The main navigation's Image("TypeTypeLogo") resolves to this same mark.
try makePNG(
    width: 128, height: 128, kind: "foreground",
    destination: root.appendingPathComponent(
        "TypeTypeTV/Assets.xcassets/TypeTypeLogo.imageset/typetype-logo.png"
    )
)
