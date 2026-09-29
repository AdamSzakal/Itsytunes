import AppKit
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

/// Cover images, shared per album, kept as 512 px JPEGs in Application Support.
enum ArtworkStore {
    private static let dir: URL = {
        let dir = AppPaths.support.appendingPathComponent("Artwork", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
    private static let cache = NSCache<NSString, NSImage>()

    static func key(artist: String, album: String, path: String) -> String {
        let base = album.isEmpty ? path : "\(artist.lowercased())|\(album.lowercased())"
        return SHA256.hash(data: Data(base.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    static func url(_ key: String) -> URL { dir.appendingPathComponent(key + ".jpg") }

    static func exists(_ key: String) -> Bool { FileManager.default.fileExists(atPath: url(key).path) }

    /// Stores `data` under `key` unless an image is already there. Returns false if `data` is not an image.
    @discardableResult
    static func save(_ data: Data, key: String) -> Bool {
        if exists(key) { return true }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 512,
        ] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options),
              let dest = CGImageDestinationCreateWithURL(url(key) as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { return false }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        return CGImageDestinationFinalize(dest)
    }

    static func image(_ key: String) -> NSImage? {
        if let hit = cache.object(forKey: key as NSString) { return hit }
        guard let image = NSImage(contentsOf: url(key)) else { return nil }
        cache.setObject(image, forKey: key as NSString)
        return image
    }
}
