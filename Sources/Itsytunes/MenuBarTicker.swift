import SwiftUI

/// "Artist – Title" of the playing song for the menu bar, like the Menu Bar Ticker app shows for Music and Spotify
/// (it asks only those two apps, so Itsytunes shows its own). A long text scrolls one letter at a time while playing.
@MainActor @Observable
final class MenuBarTicker {
    /// Nil when nothing is loaded: the menu bar then shows an icon.
    private(set) var text: String?

    @ObservationIgnored private let player: Player
    @ObservationIgnored private var full = ""
    @ObservationIgnored private var offset = 0
    @ObservationIgnored private var timer: Timer?

    /// Letters shown at once; a longer text scrolls.
    private static let width = 40
    /// Between the end of a scrolling text and its start again.
    private static let gap = "     "
    static let enabledKey = "showInMenuBar"

    init(player: Player) {
        self.player = player
        // A timer and not observation: the scrolling needs one anyway, and reading the player is cheap.
        timer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func tick() {
        guard UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true else { return }
        guard let song = player.current else {
            if text != nil { text = nil }
            return
        }
        let full = [song.artist, song.displayTitle].filter { !$0.isEmpty }.joined(separator: " – ")
        if full != self.full {
            self.full = full
            offset = 0
        } else if full.count > Self.width && player.isPlaying {
            offset = (offset + 1) % (full.count + Self.gap.count)
        }
        let shown = full.count > Self.width ? String((full + Self.gap + full).dropFirst(offset).prefix(Self.width)) : full
        if shown != text { text = shown }
    }
}

/// The menu under the song in the menu bar.
struct MenuBarMenu: View {
    @Environment(Player.self) private var player
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(player.isPlaying ? "Pause" : "Play") { player.toggle() }
        Button("Next") { player.next() }.disabled(player.current == nil)
        Button("Previous") { player.previous() }.disabled(player.current == nil)
        Divider()
        Button("Show Itsytunes") {
            openWindow(id: "main")
            NSApp.activate()
        }
    }
}
