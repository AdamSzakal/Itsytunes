import AppKit
import AVFoundation
import MediaPlayer

@MainActor @Observable
final class Player: NSObject, AVAudioPlayerDelegate {
    private(set) var current: Song?
    private(set) var isPlaying = false
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    var volume: Float = UserDefaults.standard.object(forKey: "volume") as? Float ?? 0.8 {
        didSet {
            audio?.volume = volume
            UserDefaults.standard.set(volume, forKey: "volume")
        }
    }
    var shuffle = UserDefaults.standard.bool(forKey: "shuffle") {
        didSet { UserDefaults.standard.set(shuffle, forKey: "shuffle") }
    }
    var repeatMode = RepeatMode(rawValue: UserDefaults.standard.string(forKey: "repeatMode") ?? "") ?? .off {
        didSet { UserDefaults.standard.set(repeatMode.rawValue, forKey: "repeatMode") }
    }

    @ObservationIgnored private var audio: AVAudioPlayer?
    /// The table rows (sorted and filtered) at the time the user started playback.
    @ObservationIgnored private var queue: [Song] = []
    @ObservationIgnored private var timer: Timer?
    /// Opens the file of the song that `start` was last given.
    @ObservationIgnored private var loading: Task<Void, Never>?
    /// The library's songs, for pressing play with nothing chosen (set by the main window).
    @ObservationIgnored var library: () -> [Song] = { [] }

    /// The song, position and queue at the last save, for the next launch (see `restore`).
    private struct Session: Codable {
        var song: String
        var time: Double
        var queue: [String]
    }
    private static let sessionFile = AppPaths.support.appendingPathComponent("session.json")

    override init() {
        super.init()
        setUpRemoteCommands()
        claimMediaKeys()
        // The position changes all the time, so it is saved at quit, not on every tick.
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveSession() }
        }
    }

    /// Loads the song that was playing at the last quit, paused at the same position, with the same queue.
    /// `songs`: the library, to find the saved paths in. Does nothing once a song is loaded.
    func restore(from songs: [Song]) {
        guard current == nil, let data = try? Data(contentsOf: Self.sessionFile),
              let session = try? JSONDecoder().decode(Session.self, from: data) else { return }
        let byPath = Dictionary(songs.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        guard let song = byPath[session.song] else { return }
        queue = session.queue.compactMap { byPath[$0] }
        start(song, at: session.time, playing: false)
    }

    private func saveSession() {
        guard let current else {
            try? FileManager.default.removeItem(at: Self.sessionFile)
            return
        }
        let session = Session(song: current.path, time: audio?.currentTime ?? currentTime, queue: queue.map(\.path))
        try? JSONEncoder().encode(session).write(to: Self.sessionFile)
    }

    /// macOS sends the keyboard's play key to the app that last reported playing, and if that is none
    /// (or Apple Music), it opens Apple Music. Reporting "playing" for a moment at launch makes Itsytunes
    /// that app, so the play key starts a random song instead (see `toggle`).
    private func claimMediaKeys() {
        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = [MPMediaItemPropertyTitle: "Itsytunes"]
        center.playbackState = .playing
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            if !self.isPlaying { self.updateNowPlaying() } // back to "paused", or the restored song
        }
    }

    func play(_ song: Song, queue: [Song]) {
        self.queue = queue
        start(song)
    }

    /// Play/pause. With nothing loaded yet, starts a random song in shuffle mode.
    func toggle() {
        guard current != nil else { return playRandom() }
        if let audio {
            if audio.isPlaying { audio.pause() } else { audio.play() }
            isPlaying = audio.isPlaying
        } else {
            isPlaying.toggle() // the file is still opening, and `start` plays it only if this is true
        }
        updateNowPlaying()
        saveSession()
    }

    func next() { advance(by: 1) }

    private func playRandom() {
        let songs = library()
        guard let song = songs.randomElement() else { return }
        shuffle = true
        play(song, queue: songs)
    }

    func previous() {
        if currentTime > 3 { seek(to: 0) } else { advance(by: -1) }
    }

    func seek(to time: Double) {
        audio?.currentTime = time
        currentTime = time
        updateNowPlaying()
    }

    /// `playing`: false loads the song paused, as at launch.
    private func start(_ song: Song, at time: Double = 0, playing: Bool = true) {
        audio?.stop()
        audio = nil
        loading?.cancel()
        timer?.invalidate()
        current = song
        duration = song.duration
        currentTime = time
        isPlaying = playing
        updateNowPlaying()
        saveSession()
        // Opening an online-only file (Dropbox, iCloud) waits until the provider has downloaded it,
        // which takes seconds, so it is opened off the main thread.
        let url = song.url
        loading = Task {
            let player = await Task.detached(priority: .userInitiated) { () -> AVAudioPlayer? in
                let player = try? AVAudioPlayer(contentsOf: url)
                player?.prepareToPlay()
                return player
            }.value
            guard !Task.isCancelled else { return } // another song was started meanwhile
            guard let player else { return stop() }
            player.delegate = self
            player.volume = volume
            player.currentTime = currentTime // kept if the user moved the slider meanwhile
            if isPlaying { player.play() }
            audio = player
            duration = player.duration
            timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let audio = self.audio else { return }
                    self.currentTime = audio.currentTime
                }
            }
            updateNowPlaying()
        }
    }

    private func stop() {
        audio?.stop()
        audio = nil
        loading?.cancel()
        timer?.invalidate()
        current = nil
        isPlaying = false
        currentTime = 0
        duration = 0
        updateNowPlaying()
        saveSession()
    }

    /// Manual next/previous wraps around; the end of a song only wraps when repeat is on.
    /// Repeating an album or artist keeps next and previous inside it too.
    private func advance(by step: Int, finished: Bool = false) {
        guard let current else { return stop() }
        if finished && repeatMode == .song { return start(current) }
        let pool = repeatMode == .album || repeatMode == .artist ? queue.filter(isRepeated) : queue
        guard !pool.isEmpty else { return stop() }
        let index = pool.firstIndex { $0.id == current.id } ?? -1
        var target = index + step
        if shuffle, pool.count > 1 {
            repeat { target = Int.random(in: pool.indices) } while target == index
        } else if !pool.indices.contains(target) {
            if finished && repeatMode == .off { return stop() }
            target = (target + pool.count) % pool.count
        }
        start(pool[target])
    }

    /// True for the songs that the repeat mode plays over and over: the current song, or all songs of its album
    /// or artist. An album matches as `AlbumListView.albums` groups it: same name, and same artist or folder.
    func isRepeated(_ song: Song) -> Bool {
        guard let current else { return false }
        switch repeatMode {
        case .off: return false
        case .song: return song.id == current.id
        case .artist: return song.artist.lowercased() == current.artist.lowercased()
        case .album:
            guard song.album.lowercased() == current.album.lowercased() else { return false }
            let folder = { (song: Song) in (song.path as NSString).deletingLastPathComponent }
            return song.artist.lowercased() == current.artist.lowercased() || !song.album.isEmpty && folder(song) == folder(current)
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.advance(by: 1, finished: true) }
    }

    // MARK: Media keys and Control Center

    private func setUpRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        let actions: [(MPRemoteCommand, @MainActor (Player) -> Void)] = [
            (center.togglePlayPauseCommand, { $0.toggle() }),
            (center.playCommand, { if !$0.isPlaying { $0.toggle() } }),
            (center.pauseCommand, { if $0.isPlaying { $0.toggle() } }),
            (center.nextTrackCommand, { $0.next() }),
            (center.previousTrackCommand, { $0.previous() }),
        ]
        for (command, action) in actions {
            command.addTarget { [weak self] _ in
                Task { @MainActor in if let self { action(self) } }
                return .success
            }
        }
    }

    private func updateNowPlaying() {
        let center = MPNowPlayingInfoCenter.default()
        // macOS sends the keyboard's play key to the "now playing" app, and without one it opens Apple Music.
        // So with nothing loaded, Itsytunes still shows as paused: the play key then starts a random song.
        guard let current else {
            center.nowPlayingInfo = [MPMediaItemPropertyTitle: "Itsytunes"]
            center.playbackState = .paused
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: current.displayTitle,
            MPMediaItemPropertyArtist: current.artist,
            MPMediaItemPropertyAlbumTitle: current.album,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
        ]
        if let key = current.artworkKey, let image = ArtworkStore.image(key) {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        }
        center.nowPlayingInfo = info
        center.playbackState = isPlaying ? .playing : .paused
    }
}

/// What the repeat button repeats. Each click moves to the next mode.
enum RepeatMode: String, CaseIterable {
    case off, song, album, artist

    var next: RepeatMode {
        let all = Self.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }
}
