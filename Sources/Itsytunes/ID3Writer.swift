import Foundation

/// Writes an ID3v2.4 tag to the start of an MP3 file.
/// By default it only adds frames: a frame already in the file is never replaced or removed.
/// `replacing: true` overwrites frames of the same kind; use it only on files Itsytunes created itself.
enum ID3Writer {
    struct UnsupportedTag: Error {}

    static func write(_ tags: Tags, artwork: Data?, to url: URL, replacing: Bool = false) throws {
        let file = [UInt8](try Data(contentsOf: url))
        var kept: [(id: String, body: [UInt8])] = []
        var audioStart = 0

        if file.count >= 10, file[0] == 0x49, file[1] == 0x44, file[2] == 0x33 { // "ID3"
            let version = file[3], flags = file[5]
            let size = syncsafe(file[6..<10])
            audioStart = min(file.count, 10 + size + (flags & 0x10 != 0 ? 10 : 0)) // 0x10 = footer
            // Only rewrite tags we can parse safely: v2.3/v2.4, no unsynchronisation or extended header.
            // Anything else would lose the frames already there.
            guard (version == 3 || version == 4) && flags & 0xC0 == 0 else { throw UnsupportedTag() }
            guard let parsed = frames(file, end: min(10 + size, file.count), version: version) else { throw UnsupportedTag() }
            kept = parsed
        }

        var new: [(id: String, body: [UInt8])] = []
        func text(_ id: String, _ value: String) {
            if !value.isEmpty { new.append((id, [3] + Array(value.utf8))) } // 3 = UTF-8
        }
        text("TIT2", tags.title)
        text("TPE1", tags.artist)
        text("TALB", tags.album)
        text("TDRC", tags.year)
        text("TCON", tags.genre)
        text("TRCK", tags.track.map(String.init) ?? "")
        if let artwork {
            let mime = artwork.starts(with: [0x89, 0x50, 0x4E, 0x47]) ? "image/png" : "image/jpeg"
            // encoding, MIME, 0, picture type 3 (front cover), empty description, 0, data
            new.append(("APIC", [3] + Array(mime.utf8) + [0, 3, 0] + [UInt8](artwork)))
        }

        if replacing {
            let ids = Set(new.map(\.id))
            kept.removeAll { ids.contains($0.id) }
        } else {
            let existing = Set(kept.map(\.id))
            new.removeAll { existing.contains($0.id) }
        }
        guard !new.isEmpty else { return }
        var body: [UInt8] = []
        for frame in kept + new {
            body += Array(frame.id.utf8) + syncsafeBytes(frame.body.count) + [0, 0] + frame.body
        }
        body += [UInt8](repeating: 0, count: 1024) // padding, so later edits can grow in place

        let header: [UInt8] = [0x49, 0x44, 0x33, 4, 0, 0] + syncsafeBytes(body.count)
        try Data(header + body + file[audioStart...]).write(to: url, options: .atomic)
    }

    /// Returns nil if any frame cannot be carried over unchanged.
    private static func frames(_ b: [UInt8], end: Int, version: UInt8) -> [(id: String, body: [UInt8])]? {
        var result: [(id: String, body: [UInt8])] = []
        var pos = 10
        while pos + 10 <= end {
            let idBytes = b[pos..<pos + 4]
            if b[pos] == 0 { break } // padding
            guard idBytes.allSatisfy({ (0x41...0x5A).contains($0) || (0x30...0x39).contains($0) }) else { return nil }
            var id = String(decoding: idBytes, as: UTF8.self)
            let size = version == 4 ? syncsafe(b[pos + 4..<pos + 8]) : b[pos + 4..<pos + 8].reduce(0) { $0 << 8 | Int($1) }
            let frameEnd = pos + 10 + size
            // Compressed/encrypted frames have a different layout in v2.3 and v2.4.
            guard frameEnd <= end, b[pos + 9] == 0 else { return nil }
            if id == "TYER" { id = "TDRC" } // v2.3 year frame is named TDRC in v2.4
            result.append((id, Array(b[pos + 10..<frameEnd])))
            pos = frameEnd
        }
        return result
    }

    private static func syncsafe(_ bytes: ArraySlice<UInt8>) -> Int {
        bytes.reduce(0) { $0 << 7 | Int($1 & 0x7F) }
    }

    private static func syncsafeBytes(_ n: Int) -> [UInt8] {
        [21, 14, 7, 0].map { UInt8((n >> $0) & 0x7F) }
    }
}
