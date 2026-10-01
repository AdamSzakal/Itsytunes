import Foundation

struct Song: Identifiable, Codable, Hashable, Sendable {
    let path: String
    var modified: Date
    var title = ""
    var artist = ""
    var album = ""
    var year = ""
    var genre = ""
    var track: Int?
    var duration: Double = 0
    /// Key of the cached cover image in `ArtworkStore`.
    var artworkKey: String?
    /// True once the tagger has filled what it could, so it is not asked again.
    var autoTagged = false
    /// The artist's Bandcamp page, from the comment Bandcamp writes into the files it sells.
    /// Empty when the file has none; nil when not read yet (songs cached before this was added).
    var bandcampPage: String?

    var id: String { path }
    var url: URL { URL(fileURLWithPath: path) }
    /// The title, or the file name for untagged songs. Called in every sort comparison, so it avoids
    /// building a URL (which the profiler showed as the main cost of large sorts).
    var displayTitle: String {
        title.isEmpty ? ((path as NSString).lastPathComponent as NSString).deletingPathExtension : title
    }
    var bandcampLink: URL? { bandcampPage.flatMap { $0.isEmpty ? nil : URL(string: $0) } }
    /// `Int?` is not Comparable, so untracked songs sort last.
    var trackSort: Int { track ?? .max }

    static func read(_ url: URL, modified: Date) async -> Song {
        let tags = await MetadataReader.read(url)
        var song = Song(path: url.path, modified: modified)
        song.apply(tags)
        song.duration = tags.duration
        song.bandcampPage = tags.bandcampPage
        song.artworkKey = tags.artwork.flatMap(ArtworkStore.save)
        return song
    }

    /// Copies every non-empty field of `tags` into the song.
    mutating func apply(_ tags: Tags) {
        if !tags.title.isEmpty { title = tags.title }
        if !tags.artist.isEmpty { artist = tags.artist }
        if !tags.album.isEmpty { album = tags.album }
        if !tags.year.isEmpty { year = tags.year }
        if !tags.genre.isEmpty { genre = tags.genre }
        if let t = tags.track { track = t }
    }
}

/// A set of tag values. Empty strings mean "not set".
struct Tags: Sendable {
    var title = ""
    var artist = ""
    var album = ""
    var year = ""
    var genre = ""
    var track: Int?
    var artwork: Data?
    var duration: Double = 0
    /// Read only (see `Song.bandcampPage`); writers ignore it.
    var bandcampPage = ""

    var isEmpty: Bool {
        [title, artist, album, year, genre].allSatisfy(\.isEmpty) && track == nil
    }
}

enum AppPaths {
    static let support: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            // Old app name, kept so the library cache and artwork survive the rename.
            .appendingPathComponent("TinyPlayer", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
}

func formatTime(_ seconds: Double) -> String {
    let s = max(0, Int(seconds))
    return String(format: "%d:%02d", s / 60, s % 60)
}
