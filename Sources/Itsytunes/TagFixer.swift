import Foundation

/// New tags for one song, found online. Nothing is written until the user confirms.
struct TagProposal: Identifiable {
    let song: Song
    let tags: Tags
    let artworkURL: URL?
    /// A cover chosen by the user, used instead of `artworkURL`.
    var artwork: Data?
    /// ID3 frames to remove: fields the user cleared in the tag editor.
    var removing: Set<String> = []
    var id: String { song.id }

    /// Fields that differ from the song's current tags.
    var changes: [(field: String, old: String, new: String)] {
        let fields: [(String, String, String)] = [
            ("Title", song.title, tags.title),
            ("Artist", song.artist, tags.artist),
            ("Album", song.album, tags.album),
            ("Year", song.year, tags.year),
            ("Genre", song.genre, tags.genre),
            ("Track number", song.track.map(String.init) ?? "", tags.track.map(String.init) ?? ""),
        ]
        return fields.filter { !$0.2.isEmpty && $0.1 != $0.2 }.map { (field: $0.0, old: $0.1, new: $0.2) }
    }
}

/// Replaces tags that are wrong (not only missing ones) after the user reviews the changes.
enum TagFixer {
    static func propose(for song: Song) async -> TagProposal? {
        for (artist, title) in candidates(song) {
            guard let match = try? await OnlineLookup.shared.find(title: title, artist: artist, album: song.album) else { continue }
            let tags = Tags(title: match.title, artist: match.artist, album: match.album,
                            year: match.year, genre: match.genre, track: match.track)
            let tagsChange = !TagProposal(song: song, tags: tags, artworkURL: nil).changes.isEmpty
            // Wrong tags usually mean a wrong cover too; a correct song only gets a cover if it has none.
            guard tagsChange || song.artworkKey == nil else { return nil }
            return TagProposal(song: song, tags: tags, artworkURL: match.artworkURL)
        }
        return cleanupProposal(for: song)
    }

    /// Offline: the same tags with a cleaned-up title, and a track number taken from the title or file
    /// name when the song has none. Nil if there is nothing to clean.
    static func cleanupProposal(for song: Song) -> TagProposal? {
        let cleaned = TitleCleaner.cleanup(song.displayTitle, artist: song.artist, album: song.album)
        // A title cleaned earlier lost its number; the file name often still has it.
        let fileName = TitleCleaner.cleanup(song.url.deletingPathExtension().lastPathComponent, artist: song.artist, album: song.album)
        let track = song.track ?? cleaned.track ?? fileName.track
        guard cleaned.title != song.displayTitle || track != song.track else { return nil }
        let tags = Tags(title: cleaned.title, artist: song.artist, album: song.album, year: song.year, genre: song.genre, track: track)
        return TagProposal(song: song, tags: tags, artworkURL: nil)
    }

    /// (artist, title) pairs to look up: the current tags first, then the album tag and the file name.
    /// Wrong tags are common in YouTube rips, where the album tag or file name often holds the real artist.
    static func candidates(_ song: Song) -> [(String, String)] {
        var pairs: [(String, String)] = []
        let title = song.title.isEmpty ? "" : TitleCleaner.clean(song.title, artist: song.artist, album: song.album)
        if !song.artist.isEmpty, !title.isEmpty { pairs.append((song.artist, title)) }
        // Album tag "Artist - Album" (how full-album uploads are named).
        if !title.isEmpty, let artist = song.album.components(separatedBy: " - ").first, artist != song.album {
            pairs.append((artist.trimmingCharacters(in: .whitespaces), title))
        }
        // File name "Artist - Title" or "Artist-Title-<video id>".
        // The video ID goes before "_" becomes " ", as IDs can contain "_".
        let name = TitleCleaner.stripVideoID(song.url.deletingPathExtension().lastPathComponent)
            .replacingOccurrences(of: "_", with: " ")
        for separator in [" - ", " – ", "-"] {
            if let range = name.range(of: separator) {
                let artist = name[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
                let title = TitleCleaner.clean(String(name[range.upperBound...]), artist: artist, album: song.album)
                // "01 - Title": the left side is a track number, not an artist.
                if !artist.isEmpty, !title.isEmpty, Int(artist) == nil { pairs.append((artist, title)) }
                break
            }
        }
        return pairs.reduce(into: []) { result, pair in
            if !result.contains(where: { $0 == pair }) { result.append(pair) }
        }
    }

    /// Writes the proposal into the file (MP3) and returns the updated song.
    static func apply(_ proposal: TagProposal) async -> Song {
        var song = proposal.song
        var artwork = proposal.artwork
        if artwork == nil, let url = proposal.artworkURL { artwork = try? await OnlineLookup.shared.download(url) }
        song.title = proposal.tags.title
        song.artist = proposal.tags.artist
        song.album = proposal.tags.album
        song.year = proposal.tags.year
        song.genre = proposal.tags.genre
        song.track = proposal.tags.track
        if let artwork, let key = ArtworkStore.save(artwork) { song.artworkKey = key }
        if song.url.pathExtension.lowercased() == "mp3" {
            try? ID3Writer.write(proposal.tags, artwork: artwork, to: song.url, replacing: true, removing: proposal.removing)
            if let date = try? song.url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate {
                song.modified = date
            }
        }
        song.autoTagged = true
        return song
    }
}
