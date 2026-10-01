import Foundation

/// Command-line tools installed outside the app (Homebrew or pip).
enum Tools {
    static let installCommand = "brew install yt-dlp ffmpeg"

    /// Apps started from Finder get a minimal PATH, so the usual install folders are added.
    static var searchPath: [String] {
        let env = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let all = ["/opt/homebrew/bin", "/usr/local/bin", NSHomeDirectory() + "/.local/bin"] + env
        return all.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
    }

    static func find(_ name: String) -> URL? {
        searchPath.lazy
            .map { URL(fileURLWithPath: $0).appendingPathComponent(name) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    static var missing: [String] { ["yt-dlp", "ffmpeg"].filter { find($0) == nil } }
}

/// Downloads the audio of YouTube videos with yt-dlp into the library folder,
/// split into one file per chapter when the video has chapters.
@MainActor @Observable
final class Downloader {
    enum Status: Equatable {
        case downloading(Double)
        case processing
        case done
        case failed(String)

        var isActive: Bool {
            switch self {
            case .downloading, .processing: true
            case .done, .failed: false
            }
        }
    }

    private(set) var status: [YouTubeVideo.ID: Status] = [:]
    /// Downloads shown in the footer, oldest first. Finished ones leave after a moment; failed ones stay until dismissed.
    private(set) var visible: [YouTubeVideo] = []
    /// Files of the last finished download, for the main window to show once the library has them.
    private(set) var added: [URL] = []

    func download(_ video: YouTubeVideo, into folder: URL) {
        if let current = status[video.id], current.isActive || current == .done { return }
        guard let ytdlp = Tools.find("yt-dlp"), let ffmpeg = Tools.find("ffmpeg") else { return }
        status[video.id] = .downloading(0)
        visible.removeAll { $0.id == video.id }
        visible.append(video)
        Task {
            do {
                added = try await Self.fetch(video, into: folder, ytdlp: ytdlp, ffmpeg: ffmpeg) { update in
                    Task { @MainActor in
                        // Progress lines can arrive after the final status is set.
                        if self.status[video.id]?.isActive == true { self.status[video.id] = update }
                    }
                }
                status[video.id] = .done
                try? await Task.sleep(for: .seconds(4))
                visible.removeAll { $0.id == video.id }
            } catch {
                status[video.id] = .failed(error.localizedDescription)
            }
        }
    }

    /// Hides a failed download from the footer and lets the user try it again.
    func dismiss(_ video: YouTubeVideo) {
        visible.removeAll { $0.id == video.id }
        if case .failed? = status[video.id] { status[video.id] = nil }
    }

    private struct DownloadError: LocalizedError {
        let errorDescription: String?
    }

    private nonisolated static func fetch(
        _ video: YouTubeVideo, into folder: URL, ytdlp: URL, ffmpeg: URL,
        progress: @escaping @Sendable (Status) -> Void
    ) async throws -> [URL] {
        let fm = FileManager.default
        // Work in a temporary folder, so the library only ever sees finished files.
        let work = fm.temporaryDirectory.appendingPathComponent("Itsytunes-\(video.id)-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: work) }

        let process = Process()
        process.executableURL = ytdlp
        process.arguments = [
            "--no-playlist", "--no-warnings", "--newline",
            "--format", "bestaudio/best",
            "--extract-audio", "--audio-format", "mp3", "--audio-quality", "0",
            // No --embed-metadata: its tags describe the upload, not the music. DownloadTagger tags the files.
            "--split-chapters", "--write-info-json", "--write-thumbnail", "--convert-thumbnails", "jpg",
            "--ffmpeg-location", ffmpeg.deletingLastPathComponent().path,
            "--progress-template", "download:PROGRESS %(progress._percent_str)s",
            // Named by video ID and capped chapter names: titles can exceed the 255-byte file name limit.
            "--output", work.path + "/full/%(id)s.%(ext)s",
            "--output", "infojson:" + work.path + "/video",
            "--output", "thumbnail:" + work.path + "/cover",
            "--output", "chapter:" + work.path + "/chapters/%(id)s/%(section_number)02d - %(section_title).120B.%(ext)s",
            video.url.absoluteString,
        ]
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = Tools.searchPath.joined(separator: ":")
        process.environment = environment

        let output = Pipe(), errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        let errorLog = ErrorLog()
        output.fileHandleForReading.readabilityHandler = { handle in
            for line in String(decoding: handle.availableData, as: UTF8.self).split(separator: "\n") {
                if line.hasPrefix("PROGRESS") {
                    let number = line.dropFirst("PROGRESS".count).trimmingCharacters(in: .whitespaces).dropLast() // "42.3%"
                    if let percent = Double(number) { progress(.downloading(percent / 100)) }
                } else if line.hasPrefix("[ExtractAudio]") || line.hasPrefix("[SplitChapters]") {
                    progress(.processing)
                }
            }
        }
        errors.fileHandleForReading.readabilityHandler = { handle in
            errorLog.append(String(decoding: handle.availableData, as: UTF8.self))
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            process.terminationHandler = { process in
                output.fileHandleForReading.readabilityHandler = nil
                errors.fileHandleForReading.readabilityHandler = nil
                if process.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: DownloadError(errorDescription: errorLog.lastError ?? "yt-dlp failed."))
                }
            }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }

        progress(.processing)
        return try await DownloadTagger.finish(work: work, into: folder, ffmpeg: ffmpeg)
    }
}

/// Collects yt-dlp's error output from the pipe's background thread.
private final class ErrorLog: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""

    func append(_ chunk: String) {
        lock.withLock { text += chunk }
    }

    /// The last "ERROR: ..." line, without the prefix.
    var lastError: String? {
        lock.withLock {
            text.split(separator: "\n").last { $0.hasPrefix("ERROR:") }
                .map { $0.dropFirst("ERROR:".count).trimmingCharacters(in: .whitespaces) }
        }
    }
}
