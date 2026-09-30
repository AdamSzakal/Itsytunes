// Renders Resources/AppIcon.icns: an orangered squircle with soft light, grain and shadow.
// Drawn in code (no image editor needed), so it can be changed and rebuilt.
// Run: swift scripts/make-icon.swift
import AppKit

let canvas: CGFloat = 1024
// macOS icon grid: 824 pt body inside the 1024 canvas.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)

/// Squircle (superellipse |x|^n + |y|^n = 1): the continuous-curve corner of macOS icons.
func squircle(_ rect: CGRect, n: CGFloat = 5) -> CGPath {
    let path = CGMutablePath()
    let steps = 720
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = pow(abs(c), 2 / n) * (c < 0 ? -1 : 1)
        let y = pow(abs(s), 2 / n) * (s < 0 ? -1 : 1)
        let point = CGPoint(x: rect.midX + x * rect.width / 2, y: rect.midY + y * rect.height / 2)
        i == 0 ? path.move(to: point) : path.addLine(to: point)
    }
    path.closeSubpath()
    return path
}

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// Grey noise with a fixed seed, so every render is identical.
func grain(size: Int) -> CGImage {
    var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
    var pixels = [UInt8](repeating: 0, count: size * size)
    for i in pixels.indices {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        pixels[i] = UInt8(truncatingIfNeeded: seed >> 56)
    }
    let provider = CGDataProvider(data: Data(pixels) as CFData)!
    return CGImage(width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: size,
                   space: CGColorSpaceCreateDeviceGray(), bitmapInfo: [], provider: provider,
                   decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
}

func render(size: Int) -> Data {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let cg = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                       bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let scale = CGFloat(size) / canvas
    cg.scaleBy(x: scale, y: scale) // 1024-point coordinates, origin bottom-left
    let shape = squircle(body)

    // Drop shadow under the body.
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.35))
    cg.addPath(shape)
    cg.setFillColor(color(0xFF4500))
    cg.fillPath()
    cg.restoreGState()

    cg.saveGState()
    cg.addPath(shape)
    cg.clip()

    // Base: orangered, a little lighter at the top, deeper at the bottom.
    let base = CGGradient(colorsSpace: space, colors: [color(0xFF5A14), color(0xFF4500), color(0xDB3700)] as CFArray,
                          locations: [0, 0.5, 1])!
    cg.drawLinearGradient(base, start: CGPoint(x: 512, y: body.maxY), end: CGPoint(x: 512, y: body.minY), options: [])

    // Soft light from the top left.
    let light = CGGradient(colorsSpace: space, colors: [color(0xFFFFFF, 0.16), color(0xFFFFFF, 0)] as CFArray,
                           locations: [0, 1])!
    cg.drawRadialGradient(light, startCenter: CGPoint(x: 330, y: 860), startRadius: 0,
                          endCenter: CGPoint(x: 330, y: 860), endRadius: 620, options: [])

    // Shade toward the lower edge.
    let shade = CGGradient(colorsSpace: space, colors: [color(0x000000, 0), color(0x000000, 0.22)] as CFArray,
                           locations: [0, 1])!
    cg.drawLinearGradient(shade, start: CGPoint(x: 512, y: 420), end: CGPoint(x: 512, y: body.minY), options: [])

    // Grain: fine noise, blended so it only adds texture, not a color shift.
    cg.saveGState()
    cg.setBlendMode(.overlay)
    cg.setAlpha(0.16)
    cg.interpolationQuality = .none
    cg.draw(grain(size: max(64, size / 2)), in: body)
    cg.restoreGState()

    // Rim: bright hairline along the top edge, dark along the bottom.
    cg.setLineWidth(6)
    cg.addPath(squircle(body.insetBy(dx: 3, dy: 3)))
    cg.replacePathWithStrokedPath()
    cg.clip()
    let rim = CGGradient(colorsSpace: space, colors: [color(0xFFFFFF, 0.45), color(0xFFFFFF, 0), color(0x000000, 0.18)] as CFArray,
                         locations: [0, 0.45, 1])!
    cg.drawLinearGradient(rim, start: CGPoint(x: 512, y: body.maxY), end: CGPoint(x: 512, y: body.minY), options: [])
    cg.restoreGState()

    let rep = NSBitmapImageRep(cgImage: cg.makeImage()!)
    return rep.representation(using: .png, properties: [:])!
}

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try render(size: base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(size: base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
try render(size: 1024).write(to: root.appendingPathComponent("Resources/AppIcon.png"))

// Smooth gradients with alpha compress badly as PNG; 256 colors with dithering look the same and are
// about 70% smaller. Optional: `brew install pngquant`.
if let pngquant = ["/opt/homebrew/bin/pngquant", "/usr/local/bin/pngquant"].first(where: FileManager.default.isExecutableFile) {
    let files = try FileManager.default.contentsOfDirectory(atPath: iconset.path).map { iconset.appendingPathComponent($0).path }
    let quantize = Process()
    quantize.executableURL = URL(fileURLWithPath: pngquant)
    quantize.arguments = ["--quality", "85-100", "--speed", "1", "--strip", "--force", "--ext", ".png"]
        + files + [root.appendingPathComponent("Resources/AppIcon.png").path]
    try quantize.run()
    quantize.waitUntilExit()
}

// Write the .icns directly: iconutil re-encodes the PNGs and would undo the size saving above.
// Format: "icns" + total length, then per image a 4-letter type + length (both include the 8-byte header).
let types: [(type: String, file: String)] = [
    ("icp4", "icon_16x16"), ("ic11", "icon_16x16@2x"), ("icp5", "icon_32x32"), ("ic12", "icon_32x32@2x"),
    ("ic07", "icon_128x128"), ("ic13", "icon_128x128@2x"), ("ic08", "icon_256x256"), ("ic14", "icon_256x256@2x"),
    ("ic09", "icon_512x512"), ("ic10", "icon_512x512@2x"),
]
func bigEndian(_ n: Int) -> Data { withUnsafeBytes(of: UInt32(n).bigEndian) { Data($0) } }
var images = Data()
for entry in types {
    let png = try Data(contentsOf: iconset.appendingPathComponent(entry.file + ".png"))
    images += Data(entry.type.utf8) + bigEndian(png.count + 8) + png
}
try (Data("icns".utf8) + bigEndian(images.count + 8) + images).write(to: root.appendingPathComponent("Resources/AppIcon.icns"))
print("Wrote Resources/AppIcon.icns and Resources/AppIcon.png")
