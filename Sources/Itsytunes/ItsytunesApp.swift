import SwiftUI

@main
struct ItsytunesApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var library = Library()
    @State private var player: Player
    @State private var ticker: MenuBarTicker
    @State private var downloader = Downloader()
    @State private var bandcampSync = BandcampSync()
    @State private var playlists = PlaylistStore()

    init() {
        // Needed when run as a bare executable (`swift run`) instead of the .app bundle.
        NSApplication.shared.setActivationPolicy(.regular)
        let player = Player()
        _player = State(initialValue: player)
        _ticker = State(initialValue: MenuBarTicker(player: player))
        appDelegate.player = player
    }

    var body: some Scene {
        Window("Itsytunes", id: "main") {
            ContentView()
                .environment(library)
                .environment(player)
                .environment(downloader)
                .environment(bandcampSync)
                .environment(playlists)
                .modifier(MenuBarTicker.WindowOpener(ticker: ticker))
                .frame(minWidth: 760, minHeight: 420)
        }
        .defaultSize(width: 1100, height: 700)
        .commands {
            CommandGroup(after: .newItem) {
                Button("New Playlist from Selection…") { NotificationCenter.default.post(name: .newPlaylistFromSelection, object: nil) }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                    .disabled(library.folder == nil)
                Divider()
                Button("Choose Folder…") { library.chooseFolder() }.keyboardShortcut("o")
                Button("Rescan Folder") { library.rescan() }.keyboardShortcut("r")
                Button("Sync Bandcamp") { library.folder.map(bandcampSync.sync) }
                    .disabled(!BandcampAccount.shared.isSignedIn || library.folder == nil || bandcampSync.isRunning)
                Button("Clean Up All Titles…") { NotificationCenter.default.post(name: .cleanUpAllTitles, object: nil) }
            }
            // Replaces the text Find/Spelling menus (nothing here edits text) with a Find that focuses the library search.
            CommandGroup(replacing: .textEditing) {
                Button("Find") { NotificationCenter.default.post(name: .focusLibrarySearch, object: nil) }
                    .keyboardShortcut("f")
                Button("Quick Search…") { NotificationCenter.default.post(name: .toggleQuickSearch, object: nil) }
                    .keyboardShortcut("k")
            }
            CommandMenu("Controls") {
                Button(player.isPlaying ? "Pause" : "Play") { player.toggle() }
                Button("Next") { player.next() }.keyboardShortcut(.rightArrow)
                Button("Previous") { player.previous() }.keyboardShortcut(.leftArrow)
            }
        }

        Settings {
            SettingsView().environment(library).environment(bandcampSync)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set by the app, for the Dock menu.
    var player: Player?

    /// ⌘← and ⌘→ move to the start and end of a text field, but they are also Previous and Next in the Controls
    /// menu, and the menu gets a key before a field does: typing in a field changed the song. A local monitor sees
    /// the key first, and gives it to the field that is being edited.
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard let editor = event.window?.firstResponder as? NSText, // the field editor of a text field
                  event.keyCode == 123 || event.keyCode == 124, // left, right
                  event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command
            else { return event }
            editor.keyDown(with: event)
            return nil
        }
    }

    /// Music keeps playing after the window is closed; the Dock icon or Window menu opens it again.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Asked each time the Dock menu opens, so it shows the player as it is now.
    @MainActor func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        guard let player else { return nil }
        let menu = NSMenu()
        menu.autoenablesItems = false // Next and Previous are off with no song
        menu.addPlayerControls(player)
        return menu
    }
}
