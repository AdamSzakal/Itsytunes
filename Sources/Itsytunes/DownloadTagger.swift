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
        let description: String?
        let duration: Double?
    }

    struct Guess: Equatable {
        var artist: String
        /// Album name for a video with chapters, else song title.
        var name: String
        var year = ""
        /// The title had no artist, so the channel was used.
        var artistFromChannel = false
    }

    /// `work` holds `video.info.json`, an optional `cover.jpg`, `full/<any>.mp3`, and possibly
    /// `chapters/<any>/NN - Title.mp3`. The finished files are moved into `folder`.
    /// Without usable chapters, a tracklist in the description is used to split the full file (needs `ffmpeg`),
    /// else, for a full-album upload, the song lengths of that album in the iTunes catalogue.
    /// Every title goes through the `TitleCleaner`, so downloads need no clean-up afterwards.
    /// Returns the saved files.
    static func finish(work: URL, into folder: URL, ffmpeg: URL?) async throws -> [URL] {
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
        // Some uploads have broken chapters: one holding the whole tracklist ("1. Beef Rapp - 0:01 2. Hoe
        // Cakes - 4:40 ..."). Splitting by those gives junk files, so keep the full file instead.
        let broken = chapters.contains {
            // yt-dlp writes ":" in file names as "：" (full width).
            $0.file.lastPathComponent.matches(of: #/\d{1,2}[:：⧸]\d{2}/#).count >= 2
        }
        let full = (try? fm.contentsOfDirectory(at: work.appendingPathComponent("full"), includingPropertiesForKeys: nil))?
            .first { $0.pathExtension == "mp3" }
        // Longer than most songs, or called a full album: the title names an album, not a song.
        let looksLikeAlbum = (info.duration ?? 0) >= 480 || info.title.localizedCaseInsensitiveContains("full album")
        let catalogue = looksLikeAlbum ? try? await OnlineLookup.shared.album(guess.name, artist: guess.artist) : nil

        // A tracklist of song lengths: YouTube takes the lengths for start times, so its chapters are wrong.
        let listed = Tracklist.lengths(info.description ?? "", duration: info.duration ?? 0)

        // Songs of the album, in order: a tracklist of lengths from the description, else yt-dlp's chapters,
        // else a tracklist of start times from the description, else the catalogue's song lengths.
        var songs: [(file: URL, number: Int, title: String)] = []
        if let listed, let full, let ffmpeg,
           let tracks = Tracklist.fromLengths(listed, file: full, duration: info.duration ?? 0, ffmpeg: ffmpeg),
           let files = try? Tracklist.split(full, into: tracks, directory: work.appendingPathComponent("tracks"), ffmpeg: ffmpeg) {
            songs = zip(files, tracks).enumerated().map { i, pair in
                (pair.0, i + 1, TitleCleaner.clean(pair.1.title, artist: guess.artist, album: guess.name))
            }
        } else if chapters.count >= 2 && !broken && listed == nil {
            songs = chapters.map { ($0.file, $0.number, chapterTitle($0.file, artist: guess.artist)) }
        } else if let full, let ffmpeg,
                  let tracks = Tracklist.parse(info.description ?? "", duration: info.duration ?? 0),
                  let files = try? Tracklist.split(full, into: tracks, directory: work.appendingPathComponent("tracks"), ffmpeg: ffmpeg) {
            songs = zip(files, tracks).enumerated().map { i, pair in
                (pair.0, i + 1, TitleCleaner.clean(pair.1.title, artist: guess.artist, album: guess.name))
            }
        } else if let full, let ffmpeg, let catalogue,
                  let tracks = Tracklist.fromLengths(catalogue.tracks.map { ($0.title, $0.duration) },
                                                     file: full, duration: info.duration ?? 0, ffmpeg: ffmpeg),
                  let files = try? Tracklist.split(full, into: tracks, directory: work.appendingPathComponent("tracks"), ffmpeg: ffmpeg) {
            songs = zip(files, catalogue.tracks).map { ($0, $1.number, $1.title) }
        }
        let isAlbum = !songs.isEmpty
        let songTitles = songs.map(\.title)

        // One lookup per video: the catalogue album, else for an album its first song identifies the release.
        // An unsplit full album is not looked up as a song: a song with the album's name may be on another release.
        var match = catalogue?.match
        // A fan upload may be titled with only the artist ("The Chemical Brothers" on a channel "Arte Ruido").
        // If the catalogue has the first song by that artist, its album names the release.
        if match == nil, isAlbum, guess.artistFromChannel, let first = songTitles.first,
           let found = try? await OnlineLookup.shared.find(title: first, artist: guess.name, album: "") {
            guess.artist = found.artist
            guess.name = found.album
            match = found
        }
        if match == nil, isAlbum || !looksLikeAlbum {
            match = try? await OnlineLookup.shared.find(
                title: isAlbum ? (songTitles.first ?? guess.name) : guess.name, artist: guess.artist, album: isAlbum ? guess.name : ""
            )
        }
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
            return try songs.map { song in
                let tags = Tags(title: song.title, artist: guess.artist, album: album, year: guess.year,
                                genre: trusted?.genre ?? "", track: song.number)
                try? ID3Writer.write(tags, artwork: artwork, to: song.file, replacing: true)
                let name = String(format: "%02d - ", song.number) + safeName(song.title) + ".mp3"
                let saved = target.appendingPathComponent(name)
                try fm.moveItem(at: song.file, to: saved)
                return saved
            }
        } else {
            guard let file = full else { return [] }
            // An album that could not be split keeps the album name, so it is not an "Unknown Album".
            let album = trusted?.album ?? (looksLikeAlbum ? guess.name : info.album ?? "")
            let tags = Tags(title: guess.name, artist: guess.artist, album: album, year: guess.year,
                            genre: trusted?.genre ?? "", track: looksLikeAlbum ? nil : trusted?.track)
            try? ID3Writer.write(tags, artwork: artwork, to: file, replacing: true)
            let saved = unique(folder.appendingPathComponent(safeName("\(guess.artist) - \(guess.name)") + ".mp3"))
            try fm.moveItem(at: file, to: saved)
            return [saved]
        }
    }

    /// "Deep Purple - Machine Head (Full Album)" -> artist "Deep Purple", name "Machine Head".
    static func guess(_ info: VideoInfo) -> Guess {
        // A track name means one song (a song upload also names its album); an album name alone, a whole album.
        if let artist = info.artist, let name = info.track ?? info.album {
            // YouTube Music lists several artists as "A, B".
            let first = artist.split(separator: ",").first.map(String.init) ?? artist
            return Guess(artist: first, name: name, year: info.release_year.map(String.init) ?? "")
        }
        let title = clean(info.title)
        for separator in [" - ", " – ", " — "] {
            if let range = title.range(of: separator) {
                return Guess(artist: String(title[..<range.lowerBound]).trimmingCharacters(in: .whitespaces),
                             name: TitleCleaner.clean(String(title[range.upperBound...]), artist: "", album: ""))
            }
        }
        // MF DOOM "Mm.. Food": the name in double quotes.
        if let m = title.firstMatch(of: #/^(.+?)\s+["“](.+?)["”]/#) {
            return Guess(artist: String(m.1), name: String(m.2))
        }
        // No "Artist - " in the title: the channel is the best guess ("Deep Purple - Topic", "DeepPurpleVEVO").
        let channel = (info.channel ?? info.uploader ?? "")
            .replacing(#/(?i)\s*-\s*topic$|vevo$|\s+official$/#, with: "")
        return Guess(artist: channel, name: title, artistFromChannel: true)
    }

    /// Removes upload noise: "(Full Album)", "[Official Video]", "| Lyrics", "Full Album".
    static func clean(_ title: String) -> String {
        stripNoise(pipeTail.replacing(in: title))
    }

    private static let pipeTail = Pattern(#"\s*[|｜].*$"#)
    private static let noiseBrackets = Pattern(
        #"(?i)\s*[\(\[\{][^\)\]\}]*\b(full album|official|lyrics?|audio|video|visuali[sz]er|hd|hq|4k|remaster(ed)?|explicit)\b[^\)\]\}]*[\)\]\}]"#
    )
    private static let fullAlbumSuffix = Pattern(#"(?i)\s+full album$"#)

    /// Removes "(Official Video)"-style brackets and a trailing "Full Album", keeping the rest.
    static func stripNoise(_ title: String) -> String {
        fullAlbumSuffix.replacing(in: noiseBrackets.replacing(in: title))
            .trimmingCharacters(in: .whitespaces)
    }

    /// "01 - 1. Highway Star.mp3" -> "Highway Star"; also drops a repeated "Artist - ".
    static func chapterTitle(_ file: URL, artist: String) -> String {
        let title = file.deletingPathExtension().lastPathComponent
            .replacing(#/^\d+ - /#, with: "")  // our own "NN - " prefix
        return TitleCleaner.clean(title, artist: artist, album: "")
    }

    /// File names cannot hold "/", Finder shows ":" as "/", and a name may have at most 255 bytes.
    static func safeName(_ s: String) -> String {
        let name = s.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        return name.count > 120 ? String(name.prefix(120)).trimmingCharacters(in: .whitespaces) + "…" : name
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
