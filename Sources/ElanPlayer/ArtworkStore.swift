import AppKit
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

/// Cover images kept as 512 px JPEGs in Application Support.
/// An image's key comes from its content: songs with the same cover share one file, and
/// songs with wrong, shared album tags (common in YouTube rips) still keep their own cover.
enum ArtworkStore {
    static let dir = AppPaths.support.appendingPathComponent("Artwork", isDirectory: true)
    private static let cache = NSCache<NSString, NSImage>()

    static func url(_ key: String) -> URL { dir.appendingPathComponent(key + ".jpg") }

    /// Stores the image and returns its key, or nil if `data` is not an image.
    static func save(_ data: Data) -> String? {
        let key = SHA256.hash(data: data).prefix(12).map { String(format: "%02x", $0) }.joined()
        if FileManager.default.fileExists(atPath: url(key).path) { return key }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 512,
        ] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options),
              let dest = CGImageDestinationCreateWithURL(url(key) as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? key : nil
    }

    static func image(_ key: String) -> NSImage? {
        if let hit = cache.object(forKey: key as NSString) { return hit }
        guard let image = NSImage(contentsOf: url(key)) else { return nil }
        cache.setObject(image, forKey: key as NSString)
        return image
    }
}
