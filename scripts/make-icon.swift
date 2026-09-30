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
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("Resources/AppIcon.icns").path]
try iconutil.run()
iconutil.waitUntilExit()
print("Wrote Resources/AppIcon.icns and Resources/AppIcon.png")
