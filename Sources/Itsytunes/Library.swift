import AppKit
import CoreServices
import Observation

/// All songs inside the chosen folder and its subfolders. Rescans when files change,
/// then lets the `Tagger` fill in missing tags in the background.
@MainActor @Observable
final class Library {
    private(set) var folder: URL?
    private(set) var songs: [Song] = [] {
        didSet { refreshNoisyTitles() }  // also runs inside init: Observation turns this into a computed property
    }
    /// Set while confirmed tag changes are written, for the toolbar button's spinner.
    private(set) var tagWrite: (verb: String, done: Int, total: Int)?
    /// Songs whose title the `TitleCleaner` would change, minus titles the user chose to keep.
    private(set) var noisyTitles: [Song] = []
    /// Clean-up check result per song state ("path|title|artist|album|track"). The check runs several
    /// patterns over each title; without this, every library change re-checked every song on the main thread.
    @ObservationIgnored private var noisyCache: [String: Bool] = [:]
    @ObservationIgnored private var noisyTask: Task<Void, Never>?
    /// "path|title" of titles the user reviewed and left unchanged.
    @ObservationIgnored private var keptTitles = Set(UserDefaults.standard.stringArray(forKey: "keptTitles") ?? [])
    private(set) var scanStatus: String?
    private(set) var tagStatus: String?
    /// Off by default: reading an online-only file (Dropbox, iCloud) makes the provider download it.
    var includeOnlineOnly = UserDefaults.standard.bool(forKey: "includeOnlineOnly") {
        didSet {
            UserDefaults.standard.set(includeOnlineOnly, forKey: "includeOnlineOnly")
            rescan(restart: true)
        }
    }

    @ObservationIgnored private var watcher: FolderWatcher?
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    /// Files changed during a scan: scan once more when it ends.
    @ObservationIgnored private var rescanPending = false
    @ObservationIgnored private var tagTask: Task<Void, Never>?
    /// Songs whose lookup failed (e.g. offline) in this session.
    @ObservationIgnored private var skipped: Set<String> = []

    /// v2: cover keys come from image content. v1 keyed covers by album, so it is dropped once.
    private static let cacheFile = AppPaths.support.appendingPathComponent("library-v2.json")
    private static let oldCacheFile = AppPaths.support.appendingPathComponent("library.json")
    nonisolated private static let audioExtensions: Set = ["mp3", "m4a", "aac", "flac", "wav", "aif", "aiff", "caf"]

    init() {
        if FileManager.default.fileExists(atPath: Self.oldCacheFile.path) {
            try? FileManager.default.removeItem(at: Self.oldCacheFile)
            try? FileManager.default.removeItem(at: ArtworkStore.dir)
        }
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
        rescan(restart: true)
    }

    /// Scans the folder. A scan that is running finishes first (then one more follows), so a folder that
    /// changes all the time, like a syncing Dropbox, still gets scanned to the end.
    /// `restart` stops the running scan instead, for a new folder or setting.
    func rescan(restart: Bool = false) {
        guard let folder else { return }
        if scanTask != nil && !restart {
            rescanPending = true
            return
        }
        let includeOnlineOnly = includeOnlineOnly
        scanTask?.cancel()
        rescanPending = false
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
                // Keep progress: a long first scan (e.g. a syncing Dropbox) may be cut short by quitting.
                if start % 80 == 0 { save() }
            }
            scanStatus = nil
            save()
            scanTask = nil
            if rescanPending { rescan() } else { autoTag() }
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
                let covers = albumCovers()
                let result = await Tagger.process(song, root: folder) { covers[Self.albumID($0, $1)] }
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

    /// Album ID -> the cover key of one song on that album.
    private func albumCovers() -> [String: String] {
        var covers: [String: String] = [:]
        for song in songs where !song.album.isEmpty {
            if let key = song.artworkKey { covers[Self.albumID(song.artist, song.album)] = key }
        }
        return covers
    }

    private nonisolated static func albumID(_ artist: String, _ album: String) -> String {
        "\(artist.lowercased())|\(album.lowercased())"
    }

    /// Replaces a song after its tags changed (see `TagFixer`).
    /// Writes confirmed tag changes in the background, one file at a time.
    /// `kept` are reviewed titles the user left unchecked (see `keepTitles`).
    func write(_ proposals: [TagProposal], verb: String, keeping kept: [Song]) {
        guard !proposals.isEmpty || !kept.isEmpty else { return }
        tagWrite = (verb, 0, proposals.count)
        Task {
            for proposal in proposals {
                update(await TagFixer.apply(proposal))
                tagWrite?.done += 1
            }
            keepTitles(of: kept)
            tagWrite = nil
        }
    }

    /// Stops offering these titles for clean-up. The title is part of the key, so a later change is offered again.
    func keepTitles(of songs: [Song]) {
        keptTitles.formUnion(songs.map(Self.keptKey))
        UserDefaults.standard.set(Array(keptTitles), forKey: "keptTitles")
        refreshNoisyTitles()
    }

    /// Updates `noisyTitles` in the background, once per burst of changes (a scan changes `songs` many
    /// times), so launching and scanning never wait for it. Only songs not seen before are checked.
    private func refreshNoisyTitles() {
        noisyTask?.cancel()
        let songs = songs, kept = keptTitles, cache = noisyCache
        noisyTask = Task {
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            let result = await Task.detached(priority: .utility) { Self.noisy(songs, kept: kept, cache: cache) }.value
            guard !Task.isCancelled else { return }
            noisyCache = result.cache
            noisyTitles = result.noisy
        }
    }

    private nonisolated static func noisy(_ songs: [Song], kept: Set<String>, cache: [String: Bool]) -> (noisy: [Song], cache: [String: Bool]) {
        var cache = cache
        let noisy = songs.filter { song in
            guard !kept.contains(keptKey(song)) else { return false }
            let key = "\(song.path)|\(song.displayTitle)|\(song.artist)|\(song.album)|\(song.track ?? 0)"
            if let noisy = cache[key] { return noisy }
            let noisy = TagFixer.cleanupProposal(for: song) != nil
            cache[key] = noisy
            return noisy
        }
        return (noisy, cache)
    }

    private nonisolated static func keptKey(_ song: Song) -> String { "\(song.path)|\(song.displayTitle)" }

    func update(_ song: Song) {
        guard let i = songs.firstIndex(where: { $0.path == song.path }) else { return }
        songs[i] = song
        save()
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
