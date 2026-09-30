import Foundation

/// Reads a tracklist with start times from a video description, for uploads without usable chapters.
/// Handles one track per line ("04:40 Hoe Cakes", "2. Hoe Cakes - 4:40") and a whole list on one line
/// ("1. Beef Rapp - 0:01 2. Hoe Cakes - 4:40 3. Potholderz - 7:34").
enum Tracklist {
    struct Track: Equatable {
        let start: Double
        let title: String
    }

    /// The tracks, or nil if the description has no believable tracklist.
    static func parse(_ description: String, duration: Double) -> [Track]? {
        let lines = description.split(whereSeparator: \.isNewline).map(String.init)

        // One timestamp per line: the rest of the line is the title.
        let perLine: [Track] = lines.compactMap { line in
            let found = line.matches(of: timestamp)
            guard found.count == 1, let match = found.first else { return nil }
            var title = line
            title.removeSubrange(match.range)
            return Track(start: seconds(match.output), title: tidy(title))
        }
        if isBelievable(perLine, duration: duration) { return perLine }

        // Several timestamps on one line: split the line at each timestamp.
        for line in lines {
            let found = line.matches(of: timestamp)
            guard found.count >= 3 else { continue }
            // Text between two timestamps belongs to the next one ("Title - 0:01") unless the line starts
            // with a timestamp, then to the previous one ("0:01 Title").
            let titleFirst = !tidy(String(line[..<found[0].range.lowerBound])).isEmpty
            var tracks: [Track] = []
            for (i, match) in found.enumerated() {
                let range = titleFirst
                    ? (i == 0 ? line.startIndex : found[i - 1].range.upperBound)..<match.range.lowerBound
                    : match.range.upperBound..<(i + 1 < found.count ? found[i + 1].range.lowerBound : line.endIndex)
                tracks.append(Track(start: seconds(match.output), title: tidy(String(line[range]))))
            }
            if isBelievable(tracks, duration: duration) { return tracks }
        }
        return nil
    }

    /// "1:02:03" or "4:40".
    private static let timestamp = #/(?:(\d{1,2}):)?(\d{1,2}):(\d{2})/#

    private static func seconds(_ output: (Substring, Substring?, Substring, Substring)) -> Double {
        let hours = output.1.flatMap { Double($0) } ?? 0
        return hours * 3600 + (Double(output.2) ?? 0) * 60 + (Double(output.3) ?? 0)
    }

    /// "1. Beef Rapp - " -> "Beef Rapp"; "(03:12) Song" leaves "() Song" -> "Song".
    private static func tidy(_ s: String) -> String {
        s.replacing(#/[\(\[]\s*[\)\]]/#, with: "")      // brackets that held the timestamp
            .trimmingCharacters(in: CharacterSet(charactersIn: " \t-–—|:•·"))
            .replacing(#/^\d{1,3}[.)]\s*/#, with: "")    // track number
            .trimmingCharacters(in: CharacterSet(charactersIn: " \t-–—|:•·"))
    }

    /// At least three titled tracks, in order, all starting inside the video.
    private static func isBelievable(_ tracks: [Track], duration: Double) -> Bool {
        guard tracks.count >= 3, tracks.allSatisfy({ !$0.title.isEmpty }) else { return false }
        let ascending = zip(tracks, tracks.dropFirst()).allSatisfy { $0.start < $1.start }
        return ascending && (duration <= 0 || tracks.last!.start < duration)
    }

    /// Cuts `file` into one MP3 per track (stream copy, no re-encoding) and returns the new files in order.
    static func split(_ file: URL, into tracks: [Track], directory: URL, ffmpeg: URL) throws -> [URL] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try tracks.enumerated().map { i, track in
            let output = directory.appendingPathComponent(String(format: "%02d.mp3", i + 1))
            var arguments = ["-v", "error", "-y", "-ss", String(track.start), "-i", file.path]
            if i + 1 < tracks.count { arguments += ["-t", String(tracks[i + 1].start - track.start)] }
            arguments += ["-map", "0:a", "-c", "copy", output.path]
            let process = Process()
            process.executableURL = ffmpeg
            process.arguments = arguments
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
            return output
        }
    }
}
