import AVFoundation

enum MetadataReader {
    static func read(_ url: URL) async -> Tags {
        var tags = Tags()
        let asset = AVURLAsset(url: url)
        guard let (items, common, duration) = try? await asset.load(.metadata, .commonMetadata, .duration) else {
            return tags
        }
        tags.duration = duration.seconds.isFinite ? duration.seconds : 0

        // The first value found for a field wins; common items come first.
        for item in common + items {
            // Common items keep their format's identifier (e.g. "id3/TIT2"), so match their key.
            switch item.commonKey {
            case .commonKeyTitle?:
                fill(&tags.title, await item.string())
                continue
            case .commonKeyArtist?:
                fill(&tags.artist, await item.string())
                continue
            case .commonKeyAlbumName?:
                fill(&tags.album, await item.string())
                continue
            case .commonKeyArtwork?:
                if tags.artwork == nil { tags.artwork = try? await item.load(.dataValue) }
                continue
            default:
                break
            }
            guard let id = item.identifier else { continue }
            switch id {
            case .id3MetadataYear, .id3MetadataRecordingTime, .iTunesMetadataReleaseDate,
                 .quickTimeMetadataYear, .commonIdentifierCreationDate:
                if let s = await item.string(), s.prefix(4).allSatisfy(\.isNumber), s.count >= 4 {
                    fill(&tags.year, String(s.prefix(4)))
                }
            case .id3MetadataContentType, .iTunesMetadataUserGenre, .quickTimeMetadataGenre:
                fill(&tags.genre, await item.string().map(genreName))
            case .id3MetadataBand, .iTunesMetadataAlbumArtist:
                fill(&tags.albumArtist, await item.string())
            case .id3MetadataComments, .iTunesMetadataUserComment, .quickTimeMetadataComment:
                // Bandcamp: "Visit https://artist.bandcamp.com"
                if let s = await item.string(), let m = s.firstMatch(of: #/https?://[\w.-]+\.bandcamp\.com\S*/#) {
                    fill(&tags.bandcampPage, String(m.output))
                }
            case .id3MetadataTrackNumber:
                // "3" or "3/12"
                if tags.track == nil, let s = await item.string() {
                    tags.track = Int(s.split(separator: "/").first ?? "")
                }
            case .iTunesMetadataTrackNumber:
                // Binary: 2 pad bytes, UInt16 track, UInt16 total, ...
                if tags.track == nil, let d = try? await item.load(.dataValue), d.count >= 4 {
                    let n = Int(d[d.startIndex + 2]) << 8 | Int(d[d.startIndex + 3])
                    if n > 0 { tags.track = n }
                }
            default:
                break
            }
        }
        return tags
    }

    private static func fill(_ field: inout String, _ value: String?) {
        if field.isEmpty, let value { field = value }
    }

    /// ID3 genres can be stored as a v1 index: "17" or "(17)".
    private static func genreName(_ raw: String) -> String {
        let digits = raw.trimmingCharacters(in: CharacterSet(charactersIn: "()"))
        if let i = Int(digits), id3v1Genres.indices.contains(i) { return id3v1Genres[i] }
        return raw
    }

    private static let id3v1Genres = [
        "Blues", "Classic Rock", "Country", "Dance", "Disco", "Funk", "Grunge", "Hip-Hop", "Jazz", "Metal",
        "New Age", "Oldies", "Other", "Pop", "R&B", "Rap", "Reggae", "Rock", "Techno", "Industrial",
        "Alternative", "Ska", "Death Metal", "Pranks", "Soundtrack", "Euro-Techno", "Ambient", "Trip-Hop", "Vocal", "Jazz+Funk",
        "Fusion", "Trance", "Classical", "Instrumental", "Acid", "House", "Game", "Sound Clip", "Gospel", "Noise",
        "Alternative Rock", "Bass", "Soul", "Punk", "Space", "Meditative", "Instrumental Pop", "Instrumental Rock", "Ethnic", "Gothic",
        "Darkwave", "Techno-Industrial", "Electronic", "Pop-Folk", "Eurodance", "Dream", "Southern Rock", "Comedy", "Cult", "Gangsta",
        "Top 40", "Christian Rap", "Pop/Funk", "Jungle", "Native American", "Cabaret", "New Wave", "Psychedelic", "Rave", "Showtunes",
        "Trailer", "Lo-Fi", "Tribal", "Acid Punk", "Acid Jazz", "Polka", "Retro", "Musical", "Rock & Roll", "Hard Rock",
    ]
}

private extension AVMetadataItem {
    func string() async -> String? {
        guard let s = try? await load(.stringValue) else { return nil }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// The audio stream of a file: what the footer shows about the playing song.
struct AudioInfo: Sendable {
    var codec = ""
    /// Bits per second, from the audio track (artwork and tags not counted). 0 when unknown.
    var bitRate: Float = 0
    var sampleRate: Double = 0
    var channels = 0
    var fileSize: Int64 = 0

    static func read(_ url: URL) async -> AudioInfo {
        var info = AudioInfo()
        info.codec = url.pathExtension.uppercased() // replaced below when the track names its codec
        info.fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        guard let track = try? await AVURLAsset(url: url).loadTracks(withMediaType: .audio).first,
              let (rate, formats) = try? await track.load(.estimatedDataRate, .formatDescriptions) else { return info }
        info.bitRate = rate
        if let stream = formats.first?.audioStreamBasicDescription {
            info.sampleRate = stream.mSampleRate
            info.channels = Int(stream.mChannelsPerFrame)
            if let name = codecNames[stream.mFormatID] { info.codec = name }
        }
        return info
    }

    /// The formats AVFoundation plays. WAV and AIFF are PCM, which the file extension names better.
    private static let codecNames: [AudioFormatID: String] = [
        kAudioFormatMPEGLayer3: "MP3",
        kAudioFormatMPEG4AAC: "AAC",
        kAudioFormatMPEG4AAC_HE: "HE-AAC",
        kAudioFormatAppleLossless: "ALAC",
        kAudioFormatFLAC: "FLAC",
        kAudioFormatOpus: "Opus",
    ]

    /// "MP3 · 320 kbps · 44.1 kHz · Stereo · 9.4 MB", without the parts that are unknown.
    var summary: String {
        let channelName = switch channels {
        case 0: ""
        case 1: "Mono"
        case 2: "Stereo"
        default: "\(channels) channels"
        }
        return [
            codec,
            bitRate > 0 ? "\(Int((bitRate / 1000).rounded())) kbps" : "",
            sampleRate > 0 ? "\((sampleRate / 1000).formatted(.number.precision(.fractionLength(0...1)))) kHz" : "",
            channelName,
            fileSize > 0 ? ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file) : "",
        ].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}
