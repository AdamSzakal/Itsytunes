import Foundation

/// Fills in missing tags and cover art for one song.
/// It never overwrites a tag that is already set. MP3 files get the new tags written into them;
/// other formats keep them only in the library cache.
enum Tagger {
    /// `retry` is true when a network error stopped the lookup, so it can be tried again later.
    /// `albumCover` returns the cover key another song of the same artist and album already has.
    static func process(_ song: Song, root: URL, albumCover: (_ artist: String, _ album: String) -> String?) async -> (song: Song, retry: Bool) {
        var song = song
        var add = Tags() // only fields that were missing
        let guess = FilenameGuess(url: song.url, root: root)
        if song.title.isEmpty { add.title = guess.title }
        if song.artist.isEmpty { add.artist = guess.artist ?? "" }
        if song.album.isEmpty { add.album = guess.album ?? "" }
        if song.track == nil { add.track = guess.track }

        let title = song.title.isEmpty ? add.title : song.title
        let artist = song.artist.isEmpty ? add.artist : song.artist
        var album = song.album.isEmpty ? add.album : song.album

        var art: Data?
        if song.artworkKey == nil {
            art = folderArtwork(near: song.url)
                ?? albumCover(artist, album).flatMap { try? Data(contentsOf: ArtworkStore.url($0)) }
        }

        var retry = false
        let incomplete = album.isEmpty || song.year.isEmpty || song.genre.isEmpty || (song.artworkKey == nil && art == nil)
        // Title alone matches too many songs, so the lookup needs an artist.
        if incomplete, !artist.isEmpty {
            do {
                if let match = try await OnlineLookup.shared.find(title: title, artist: artist, album: album) {
                    let sameAlbum = album.isEmpty || OnlineLookup.normalize(album) == OnlineLookup.normalize(match.album)
                    if album.isEmpty { add.album = match.album; album = match.album }
                    if song.year.isEmpty { add.year = match.year }
                    if song.genre.isEmpty { add.genre = match.genre }
                    if song.track == nil, add.track == nil, sameAlbum { add.track = match.track }
                    if song.artworkKey == nil, art == nil, let artURL = match.artworkURL {
                        art = try await OnlineLookup.shared.download(artURL)
                    }
                }
            } catch {
                retry = true
            }
        }

        song.apply(add)
        if let art, let key = ArtworkStore.save(art) { song.artworkKey = key }
        if song.url.pathExtension.lowercased() == "mp3", !add.isEmpty || art != nil {
            do {
                try ID3Writer.write(add, artwork: art, to: song.url)
                // Record the new date, so the next scan does not read the file again.
                if let date = try? song.url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate {
                    song.modified = date
                }
            } catch {
                // Read-only file: the tags stay in the library cache.
            }
        }
        song.autoTagged = !retry
        return (song, retry)
    }

    /// cover.jpg, folder.png and similar files next to the song.
    private static func folderArtwork(near url: URL) -> Data? {
        let names: Set = ["cover", "folder", "front", "album", "artwork"]
        let files = (try? FileManager.default.contentsOfDirectory(at: url.deletingLastPathComponent(), includingPropertiesForKeys: nil)) ?? []
        let match = files.first {
            ["jpg", "jpeg", "png"].contains($0.pathExtension.lowercased())
                && names.contains($0.deletingPathExtension().lastPathComponent.lowercased())
        }
        return match.flatMap { try? Data(contentsOf: $0) }
    }
}

/// Tag guesses from the file name and folders, e.g. `Artist/Album/03 - Title.mp3`
/// or `Artist - Title.mp3`.
struct FilenameGuess {
    var title: String
    var artist: String?
    var album: String?
    var track: Int?

    init(url: URL, root: URL) {
        var name = TitleCleaner.stripVideoID(url.deletingPathExtension().lastPathComponent)
            .replacingOccurrences(of: "_", with: " ")
        // "03 Title", "03. Title", "03 - Title", "1-03 Title" (disc-track)
        if let m = name.firstMatch(of: #/^(?:\d{1,2}-)?(\d{1,3})[\s.\-]+(.+)$/#) {
            track = Int(m.1)
            name = String(m.2)
        }
        let parts = name.components(separatedBy: " - ")
        if parts.count >= 2 {
            artist = parts[0].trimmingCharacters(in: .whitespaces)
            title = parts.dropFirst().joined(separator: " - ").trimmingCharacters(in: .whitespaces)
        } else {
            title = name.trimmingCharacters(in: .whitespaces)
        }

        // Folders below the library root: [..., Artist, Album] (a "CD1"/"Disc 2" folder is skipped).
        var folders = url.deletingLastPathComponent().pathComponents.dropFirst(root.pathComponents.count)
        if let last = folders.last, last.wholeMatch(of: #/(?i)(cd|disc|disk)\s*\d+/#) != nil { folders = folders.dropLast() }
        // Music.app files untagged songs under these placeholder folders.
        if folders.contains(where: { ["unknown artist", "unknown album"].contains($0.lowercased()) }) { folders = [] }
        // A single folder level is too often "Downloads" or "New", so only trust Artist/Album.
        if folders.count >= 2 {
            album = folders.last
            if artist == nil { artist = folders[folders.endIndex - 2] }
        }
    }
}

/// Song lookup through the public iTunes Search API (no key needed).
actor OnlineLookup {
    static let shared = OnlineLookup()

    struct Match {
        var title = ""
        var artist = ""
        var album = ""
        var year = ""
        var genre = ""
        var track: Int?
        var artworkURL: URL?
    }

    private struct Response: Decodable { let results: [Item] }
    private struct Item: Decodable {
        let trackName: String?
        let artistName: String?
        let collectionName: String?
        let releaseDate: String?
        let primaryGenreName: String?
        let trackNumber: Int?
        let artworkUrl100: String?
    }

    private var lastRequest = Date.distantPast

    func find(title: String, artist: String, album: String) async throws -> Match? {
        // The API allows about 20 requests per minute.
        let wait = 3 - Date().timeIntervalSince(lastRequest)
        if wait > 0 { try await Task.sleep(for: .seconds(wait)) }
        lastRequest = Date()

        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [
            URLQueryItem(name: "term", value: "\(artist) \(title)"),
            URLQueryItem(name: "media", value: "music"),
            URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "limit", value: "15"),
        ]
        let (data, response) = try await URLSession.shared.data(from: components.url!)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        let items = try JSONDecoder().decode(Response.self, from: data).results

        let t = Self.normalize(title), a = Self.normalize(artist), al = Self.normalize(album)
        guard !t.isEmpty, !a.isEmpty else { return nil }
        let hits = items.filter { item in
            let it = Self.normalize(item.trackName ?? ""), ia = Self.normalize(item.artistName ?? "")
            return !it.isEmpty && !ia.isEmpty
                && (it.hasPrefix(t) || t.hasPrefix(it))
                && (ia.contains(a) || a.contains(ia))
        }
        guard let best = hits.first(where: { !al.isEmpty && Self.normalize($0.collectionName ?? "") == al }) ?? hits.first else {
            return nil
        }
        return Match(
            title: best.trackName ?? "",
            artist: best.artistName ?? "",
            album: best.collectionName ?? "",
            year: String((best.releaseDate ?? "").prefix(4)),
            genre: best.primaryGenreName ?? "",
            track: best.trackNumber,
            artworkURL: best.artworkUrl100.flatMap { URL(string: $0.replacingOccurrences(of: "100x100bb", with: "600x600bb")) }
        )
    }

    func download(_ url: URL) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return data
    }

    /// "Teardrop (Remastered)" -> "teardrop", "Sigur Rós" -> "sigurros"
    nonisolated static func normalize(_ s: String) -> String {
        s.replacing(#/\s*[\(\[][^\)\]]*[\)\]]/#, with: "")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .filter { $0.isLetter || $0.isNumber }
    }
}
