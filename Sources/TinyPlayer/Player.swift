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
    var shuffle = false
    var repeatAll = false

    @ObservationIgnored private var audio: AVAudioPlayer?
    /// The table rows (sorted and filtered) at the time the user started playback.
    @ObservationIgnored private var queue: [Song] = []
    @ObservationIgnored private var timer: Timer?

    override init() {
        super.init()
        setUpRemoteCommands()
    }

    func play(_ song: Song, queue: [Song]) {
        self.queue = queue
        start(song)
    }

    func toggle() {
        guard let audio else { return }
        if audio.isPlaying { audio.pause() } else { audio.play() }
        isPlaying = audio.isPlaying
        updateNowPlaying()
    }

    func next() { advance(by: 1) }

    func previous() {
        if currentTime > 3 { seek(to: 0) } else { advance(by: -1) }
    }

    func seek(to time: Double) {
        audio?.currentTime = time
        currentTime = time
        updateNowPlaying()
    }

    private func start(_ song: Song) {
        audio?.stop()
        current = song
        guard let player = try? AVAudioPlayer(contentsOf: song.url) else { return stop() }
        player.delegate = self
        player.volume = volume
        player.play()
        audio = player
        duration = player.duration
        currentTime = 0
        isPlaying = true
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let audio = self.audio else { return }
                self.currentTime = audio.currentTime
            }
        }
        updateNowPlaying()
    }

    private func stop() {
        audio?.stop()
        audio = nil
        timer?.invalidate()
        current = nil
        isPlaying = false
        currentTime = 0
        duration = 0
        updateNowPlaying()
    }

    /// Manual next/previous wraps around; the end of a song only wraps when repeat is on.
    private func advance(by step: Int, finished: Bool = false) {
        guard let current, !queue.isEmpty else { return stop() }
        let index = queue.firstIndex { $0.id == current.id } ?? -1
        var target = index + step
        if shuffle, queue.count > 1 {
            repeat { target = Int.random(in: queue.indices) } while target == index
        } else if !queue.indices.contains(target) {
            if finished && !repeatAll { return stop() }
            target = (target + queue.count) % queue.count
        }
        start(queue[target])
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
        guard let current else {
            center.nowPlayingInfo = nil
            center.playbackState = .stopped
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
