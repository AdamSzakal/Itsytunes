import SwiftUI

@main
struct TinyPlayerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var library = Library()
    @State private var player = Player()
    @State private var downloader = Downloader()

    init() {
        // Needed when run as a bare executable (`swift run`) instead of the .app bundle.
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        Window("TinyPlayer", id: "main") {
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

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Music keeps playing after the window is closed; the Dock icon or Window menu opens it again.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
