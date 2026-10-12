// Makes Resources/AppIcon.icns from Resources/AppIcon.png, the 1024 px master.
// The master is exported from Figma ("Itsytunes icon concepts", frame "7 · Jewel case, front, disc")
// with a transparent background. To change the icon, export it again over AppIcon.png and re-run.
// Run: swift scripts/make-icon.swift
import AppKit

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let master = root.appendingPathComponent("Resources/AppIcon.png")
guard let source = NSImage(contentsOf: master)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    fatalError("Cannot read \(master.path)")
}

func render(size: Int) -> Data {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let cg = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                       bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    cg.interpolationQuality = .high
    cg.draw(source, in: CGRect(x: 0, y: 0, width: size, height: size))
    let rep = NSBitmapImageRep(cgImage: cg.makeImage()!)
    return rep.representation(using: .png, properties: [:])!
}

let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try render(size: base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(size: base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}

// Smooth gradients with alpha compress badly as PNG; 256 colors with dithering look the same and are
// about 70% smaller. Only the icon sizes are reduced, never the master. Optional: `brew install pngquant`.
if let pngquant = ["/opt/homebrew/bin/pngquant", "/usr/local/bin/pngquant"].first(where: FileManager.default.isExecutableFile) {
    let files = try FileManager.default.contentsOfDirectory(atPath: iconset.path).map { iconset.appendingPathComponent($0).path }
    let quantize = Process()
    quantize.executableURL = URL(fileURLWithPath: pngquant)
    quantize.arguments = ["--quality", "85-100", "--speed", "1", "--strip", "--force", "--ext", ".png"] + files
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
print("Wrote Resources/AppIcon.icns")
