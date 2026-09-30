import SwiftUI

@main
struct ItsytunesApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var library = Library()
    @State private var player = Player()
    @State private var downloader = Downloader()

    init() {
        // Needed when run as a bare executable (`swift run`) instead of the .app bundle.
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        Window("Itsytunes", id: "main") {
            ContentView()
                .environment(library)
                .environment(player)
                .environment(downloader)
                .frame(minWidth: 760, minHeight: 420)
        }
        .defaultSize(width: 1100, height: 700)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Choose Folder…") { library.chooseFolder() }.keyboardShortcut("o")
                Button("Rescan Folder") { library.rescan() }.keyboardShortcut("r")
                Button("Clean Up All Titles…") { NotificationCenter.default.post(name: .cleanUpAllTitles, object: nil) }
            }
            // Replaces the text Find/Spelling menus (nothing here edits text) with a Find that focuses the library search.
            CommandGroup(replacing: .textEditing) {
                Button("Find") { focusLibrarySearch() }.keyboardShortcut("f")
            }
            CommandMenu("Controls") {
                Button(player.isPlaying ? "Pause" : "Play") { player.toggle() }
                Button("Next") { player.next() }.keyboardShortcut(.rightArrow)
                Button("Previous") { player.previous() }.keyboardShortcut(.leftArrow)
            }
        }

        Settings {
            SettingsView().environment(library)
        }
    }
}

/// SwiftUI has no API to focus a toolbar `.searchable` field before macOS 15, so ask the toolbar item directly.
@MainActor
private func focusLibrarySearch() {
    let window = NSApp.keyWindow ?? NSApp.mainWindow
    let item = window?.toolbar?.items.lazy.compactMap { $0 as? NSSearchToolbarItem }.first
    item?.beginSearchInteraction()
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Music keeps playing after the window is closed; the Dock icon or Window menu opens it again.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
