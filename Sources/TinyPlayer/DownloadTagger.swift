import Foundation

/// Tags and files the audio yt-dlp downloaded. yt-dlp's own tags describe the upload, not the music
/// (artist = the channel, year = upload year, genre = "Music"), so they are not used. Instead the
/// artist and album or song are read from the video title, then checked against the iTunes catalogue.
enum DownloadTagger {
    /// The fields of yt-dlp's `.info.json` that are used.
    struct VideoInfo: Decodable {
        let title: String
        let uploader: String?
        let channel: String?
        // Only set for YouTube Music uploads, and then more reliable than the title.
        let artist: String?
        let album: String?
        let track: String?
        let release_year: Int?
    }

    struct Guess: Equatable {
        var artist: String
        /// Album name for a video with chapters, else song title.
        var name: String
        var year = ""
    }

    /// `work` holds `video.info.json`, an optional `cover.jpg`, and either `chapters/<any>/NN - Title.mp3`
    /// or `full/<any>.mp3`. The finished files are moved into `folder`.
    static func finish(work: URL, into folder: URL) async throws {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: work, includingPropertiesForKeys: nil)) ?? []
        let info = try JSONDecoder().decode(VideoInfo.self, from: Data(contentsOf: work.appendingPathComponent("video.info.json")))
        let thumbnail = files.first { $0.pathExtension == "jpg" }.flatMap { try? Data(contentsOf: $0) }

        let chapterDir = (try? fm.contentsOfDirectory(at: work.appendingPathComponent("chapters"), includingPropertiesForKeys: nil))?.first
        let chapters: [(file: URL, number: Int)] = ((chapterDir.flatMap {
            try? fm.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)
        }) ?? []).compactMap { file in
            guard file.pathExtension == "mp3",
                  let m = file.deletingPathExtension().lastPathComponent.wholeMatch(of: #/(\d+) - (.+)/#) else { return nil }
            return (file, Int(m.1) ?? 0)
        }
        .sorted { $0.number < $1.number }

        var guess = Self.guess(info)
        let isAlbum = !chapters.isEmpty
        let songTitles = chapters.map { chapterTitle($0.file, artist: guess.artist) }

        // One lookup per video: for an album, its first song identifies the release.
        let match = try? await OnlineLookup.shared.find(
            title: songTitles.first ?? guess.name, artist: guess.artist, album: isAlbum ? guess.name : ""
        )
        let sameAlbum = match.map { OnlineLookup.normalize($0.album) == OnlineLookup.normalize(guess.name) } ?? false
        let trusted = isAlbum ? (sameAlbum ? match : nil) : match
        if let trusted, !trusted.year.isEmpty { guess.year = trusted.year }
        var artwork: Data?
        if let url = trusted?.artworkURL { artwork = try? await OnlineLookup.shared.download(url) }
        artwork = artwork ?? thumbnail

        if isAlbum {
            let album = trusted?.album ?? guess.name
            let target = unique(folder.appendingPathComponent(safeName("\(guess.artist) - \(album)")))
            try fm.createDirectory(at: target, withIntermediateDirectories: true)
            for (chapter, title) in zip(chapters, songTitles) {
                let tags = Tags(title: title, artist: guess.artist, album: album, year: guess.year,
                                genre: trusted?.genre ?? "", track: chapter.number)
                try? ID3Writer.write(tags, artwork: artwork, to: chapter.file, replacing: true)
                let name = String(format: "%02d - ", chapter.number) + safeName(title) + ".mp3"
                try fm.moveItem(at: chapter.file, to: target.appendingPathComponent(name))
            }
        } else {
            let full = (try? fm.contentsOfDirectory(at: work.appendingPathComponent("full"), includingPropertiesForKeys: nil)) ?? []
            guard let file = full.first(where: { $0.pathExtension == "mp3" }) else { return }
            let tags = Tags(title: guess.name, artist: guess.artist, album: trusted?.album ?? "", year: guess.year,
                            genre: trusted?.genre ?? "", track: trusted?.track)
            try? ID3Writer.write(tags, artwork: artwork, to: file, replacing: true)
            try fm.moveItem(at: file, to: unique(folder.appendingPathComponent(safeName("\(guess.artist) - \(guess.name)") + ".mp3")))
        }
    }

    /// "Deep Purple - Machine Head (Full Album)" -> artist "Deep Purple", name "Machine Head".
    static func guess(_ info: VideoInfo) -> Guess {
        if let artist = info.artist, let name = info.album ?? info.track {
            // YouTube Music lists several artists as "A, B".
            let first = artist.split(separator: ",").first.map(String.init) ?? artist
            return Guess(artist: first, name: name, year: info.release_year.map(String.init) ?? "")
        }
        let title = clean(info.title)
        for separator in [" - ", " – ", " — "] {
            if let range = title.range(of: separator) {
                return Guess(artist: String(title[..<range.lowerBound]).trimmingCharacters(in: .whitespaces),
                             name: String(title[range.upperBound...]).trimmingCharacters(in: .whitespaces))
            }
        }
        // No "Artist - " in the title: the channel is the best guess ("Deep Purple - Topic", "DeepPurpleVEVO").
        let channel = (info.channel ?? info.uploader ?? "")
            .replacing(#/(?i)\s*-\s*topic$|vevo$|\s+official$/#, with: "")
        return Guess(artist: channel, name: title)
    }

    /// Removes upload noise: "(Full Album)", "[Official Video]", "| Lyrics", "Full Album".
    static func clean(_ title: String) -> String {
        title
            .replacing(#/(?i)\s*[\(\[\{][^\)\]\}]*\b(full album|official|lyrics?|audio|video|visuali[sz]er|hd|hq|4k|remaster(ed)?|explicit)\b[^\)\]\}]*[\)\]\}]/#, with: "")
            .replacing(#/\s*[|｜].*$/#, with: "")
            .replacing(#/(?i)\s+full album$/#, with: "")
            .trimmingCharacters(in: .whitespaces)
    }

    /// "01 - 1. Highway Star.mp3" -> "Highway Star"; also drops a repeated "Artist - ".
    static func chapterTitle(_ file: URL, artist: String) -> String {
        var title = file.deletingPathExtension().lastPathComponent
            .replacing(#/^\d+ - /#, with: "")                  // our own "NN - " prefix
            .replacing(#/^\s*\d{1,3}\s*[.):\-]\s*/#, with: "")  // numbering from the video description
        if !artist.isEmpty, title.lowercased().hasPrefix(artist.lowercased() + " - ") {
            title = String(title.dropFirst(artist.count + 3))
        }
        return clean(title)
    }

    /// File names cannot hold "/" and Finder shows ":" as "/".
    private static func safeName(_ s: String) -> String {
        s.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
    }

    /// "Song.mp3" -> "Song (2).mp3" when the name is taken.
    static func unique(_ url: URL) -> URL {
        var candidate = url
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let base = url.deletingPathExtension().lastPathComponent + " (\(n))"
            candidate = url.deletingLastPathComponent().appendingPathComponent(base)
            if !url.pathExtension.isEmpty { candidate.appendPathExtension(url.pathExtension) }
            n += 1
        }
        return candidate
    }
}
