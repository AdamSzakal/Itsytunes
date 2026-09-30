import Foundation

/// Removes upload noise from song titles, mostly left by YouTube rips and split mixes:
/// "100th electric cleaners mix | house | EC100 - 002 DR. GABBA - Rave Boi [eAWTeXE2SiQ]" -> "Rave Boi"
/// (with artist DR. GABBA), or "Hip Hop 1996 X Instrumental-y0LDKI6VERU" -> "Hip Hop 1996 X Instrumental".
enum TitleCleaner {
    private static let pipe = Pattern(#"\s+[|｜]\s+"#)
    private static let catalogue = Pattern(#"^[A-Z]{2,}\d+\s*-\s*"#)
    private static let trackNumber = Pattern(#"^(?:0(\d{1,2})(?:\s*[.)\-])?\s+|(\d{1,3})[.)]\s+|(\d{1,3})\s+-\s+)(?=\S)"#)
    private static let dashPrefix = Pattern(#"^(.+?)\s+-\s+"#)
    private static let bracketedVideoID = Pattern(#"\s*\[[A-Za-z0-9_-]{11}\]$"#)
    private static let trailingVideoID = Pattern(#"-([A-Za-z0-9_-]{11})$"#)

    static func clean(_ title: String, artist: String, album: String) -> String {
        cleanup(title, artist: artist, album: album).title
    }

    /// The cleaned title, and the track number removed from it ("001 Universal Love" -> 1), if any.
    static func cleanup(_ title: String, artist: String, album: String) -> (title: String, track: Int?) {
        var t = stripVideoID(title)
        var track: Int?

        // "Mix name | genre | Artist - Song": keep the "Artist - Song" part. Without one, every part may matter.
        let parts = pipe.split(t).map { $0.trimmingCharacters(in: .whitespaces) }
        if parts.count > 1, let song = parts.last(where: { $0.contains(" - ") }) { t = song }

        // Prefixes come in any order ("OMA - 003 Cedar", "003 OMA - Cedar"), so strip until nothing changes.
        var previous = ""
        while previous != t {
            previous = t
            t = catalogue.replacing(in: t)  // catalogue number "EC100 - "
            // Track number: zero-padded ("007 ") or with punctuation ("1. ", "02 - ").
            // A bare "99 Problems" and a time-like "4:44" stay.
            if let m = trackNumber.firstMatch(in: t) {
                track = track ?? m.groups.lazy.compactMap { $0 }.first.flatMap { Int($0) }
                t = String(t[m.range.upperBound...])
            }
            if let prefix = dashPrefix.firstMatch(in: t), let name = prefix.groups[0],
               isAlbumOrArtist(name, artist: artist, album: album) {
                t = String(t[prefix.range.upperBound...])   // "Wagon Christ - ", "Throbbing Pouch (1995) - "
            }
        }
        t = DownloadTagger.stripNoise(t)                    // "(Official Video)", "[Lyrics]", ...
        let result = t.trimmingCharacters(in: .whitespaces)
        return (result.isEmpty ? title : result, track)
    }

    /// True when `prefix` repeats the song's artist or album, so it adds nothing to the title.
    /// Other artists stay in the title, so songs of a mix are not split into separate albums.
    private static func isAlbumOrArtist(_ prefix: String, artist: String, album: String) -> Bool {
        let p = OnlineLookup.normalize(prefix)
        guard !p.isEmpty else { return false }
        return p == OnlineLookup.normalize(artist) || OnlineLookup.normalize(album).hasPrefix(p)
    }

    /// Removes a YouTube video ID: "[eAWTeXE2SiQ]" or "-y0LDKI6VERU" at the end.
    static func stripVideoID(_ s: String) -> String {
        var s = bracketedVideoID.replacing(in: s)
        if let m = trailingVideoID.firstMatch(in: s), let id = m.groups[0], looksLikeVideoID(id) {
            s = String(s[..<m.range.lowerBound])
        }
        return s
    }

    /// Video IDs are random: they have a digit, "_" or "-", or mixed case. A plain word like "Instrumentl" does not.
    private static func looksLikeVideoID(_ id: String) -> Bool {
        id.contains { $0.isNumber || $0 == "_" || $0 == "-" }
            || (id.contains { $0.isUppercase } && id.dropFirst().contains { $0.isUppercase } && id.contains { $0.isLowercase })
    }
}
