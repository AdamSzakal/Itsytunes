import AppKit
import CoreServices
import Observation

/// All songs inside the chosen folder and its subfolders. Rescans when files change,
/// then lets the `Tagger` fill in missing tags in the background.
@MainActor @Observable
final class Library {
    private(set) var folder: URL?
    private(set) var songs: [Song] = []
    private(set) var scanStatus: String?
    private(set) var tagStatus: String?
    /// Off by default: reading an online-only file (Dropbox, iCloud) makes the provider download it.
    var includeOnlineOnly = UserDefaults.standard.bool(forKey: "includeOnlineOnly") {
        didSet {
            UserDefaults.standard.set(includeOnlineOnly, forKey: "includeOnlineOnly")
            rescan()
        }
    }

    @ObservationIgnored private var watcher: FolderWatcher?
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var tagTask: Task<Void, Never>?
    /// Songs whose lookup failed (e.g. offline) in this session.
    @ObservationIgnored private var skipped: Set<String> = []

    private static let cacheFile = AppPaths.support.appendingPathComponent("library.json")
    nonisolated private static let audioExtensions: Set = ["mp3", "m4a", "aac", "flac", "wav", "aif", "aiff", "caf"]

    init() {
        songs = (try? JSONDecoder().decode([Song].self, from: Data(contentsOf: Self.cacheFile))) ?? []
        if let path = UserDefaults.standard.string(forKey: "folder") {
            open(URL(fileURLWithPath: path, isDirectory: true))
        }
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url { open(url) }
    }

    func open(_ url: URL) {
        let url = url.standardizedFileURL
        tagTask?.cancel()
        tagTask = nil
        songs = songs.filter { $0.path.hasPrefix(url.path + "/") }
        folder = url
        UserDefaults.standard.set(url.path, forKey: "folder")
        watcher = FolderWatcher(path: url.path) { [weak self] in self?.rescan() }
        rescan()
    }

    func rescan() {
        guard let folder else { return }
        let includeOnlineOnly = includeOnlineOnly
        scanTask?.cancel()
        scanTask = Task {
            scanStatus = "Scanning…"
            let files = await Task.detached(priority: .utility) {
                Self.audioFiles(in: folder, includeOnlineOnly: includeOnlineOnly)
            }.value
            guard !Task.isCancelled else { return }

            // Reuse cached songs whose file did not change; read tags of the rest.
            let known = Dictionary(songs.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
            var changed: [(url: URL, modified: Date)] = []
            var fresh: [Song] = []
            for file in files {
                if let song = known[file.url.path], abs(song.modified.timeIntervalSince(file.modified)) < 0.001 {
                    fresh.append(song)
                } else {
                    changed.append(file)
                }
            }
            songs = fresh

            for start in stride(from: 0, to: changed.count, by: 8) {
                guard !Task.isCancelled else { return }
                scanStatus = "Reading tags \(start + 1) of \(changed.count)"
                let batch = changed[start..<min(start + 8, changed.count)]
                let read = await withTaskGroup(of: Song.self) { group in
                    for file in batch { group.addTask { await Song.read(file.url, modified: file.modified) } }
                    return await group.reduce(into: []) { $0.append($1) }
                }
                // A newer scan (other folder, or a file change) may have started while this batch was read.
                guard !Task.isCancelled else { return }
                songs.append(contentsOf: read)
            }
            scanStatus = nil
            save()
            autoTag()
        }
    }

    private func autoTag() {
        guard tagTask == nil, let folder else { return }
        tagTask = Task {
            var done = 0
            while !Task.isCancelled,
                  let song = songs.first(where: { !$0.autoTagged && !skipped.contains($0.path) }) {
                let left = songs.filter { !$0.autoTagged && !skipped.contains($0.path) }.count
                tagStatus = "Tagging \(done + 1) of \(done + left)"
                let result = await Tagger.process(song, root: folder)
                if result.retry { skipped.insert(song.path) }
                if let i = songs.firstIndex(where: { $0.path == song.path }) { songs[i] = result.song }
                done += 1
                if done % 20 == 0 { save() }
            }
            guard !Task.isCancelled else { return }
            tagStatus = nil
            tagTask = nil
            save()
        }
    }

    private func save() {
        try? JSONEncoder().encode(songs).write(to: Self.cacheFile, options: .atomic)
    }

    nonisolated private static func audioFiles(in folder: URL, includeOnlineOnly: Bool) -> [(url: URL, modified: Date)] {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isRegularFileKey, .ubiquitousItemDownloadingStatusKey]
        guard let enumerator = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        var files: [(url: URL, modified: Date)] = []
        for case let url as URL in enumerator where audioExtensions.contains(url.pathExtension.lowercased()) {
            guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true else { continue }
            // Local files have no downloading status.
            if !includeOnlineOnly, values.ubiquitousItemDownloadingStatus == .notDownloaded { continue }
            files.append((url.standardizedFileURL, values.contentModificationDate ?? .distantPast))
        }
        return files
    }
}

/// Calls `onChange` (on the main queue) when anything inside `path` changes.
final class FolderWatcher {
    private var stream: FSEventStreamRef?
    private let onChange: @MainActor () -> Void

    init(path: String, onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
            MainActor.assumeIsolated { watcher.onChange() }
        }
        // 2 s latency groups bursts (a copy of many files) into one rescan.
        stream = FSEventStreamCreate(
            nil, callback, &context, [path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 2.0, FSEventStreamCreateFlags(kFSEventStreamCreateFlagNone)
        )
        if let stream {
            FSEventStreamSetDispatchQueue(stream, .main)
            FSEventStreamStart(stream)
        }
    }

    deinit {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
}
