import SwiftUI

struct SettingsView: View {
    @Environment(Library.self) private var library
    @Environment(BandcampSync.self) private var bandcampSync
    @State private var account = YouTubeAccount.shared
    @State private var bandcamp = BandcampAccount.shared
    @State private var showBandcampLogin = false
    /// Saved on Return or when Settings closes, not on every keystroke.
    @State private var keyDraft = ""
    @AppStorage(MenuBarTicker.enabledKey) private var showInMenuBar = true

    var body: some View {
        @Bindable var library = library
        @Bindable var bandcamp = bandcamp
        Form {
            Section {
                Toggle("Show the playing song in the menu bar", isOn: $showInMenuBar)
            } header: {
                Text("Menu Bar")
            }

            Section {
                Toggle("Include online-only files", isOn: $library.includeOnlineOnly)
            } header: {
                Text("Library")
            } footer: {
                FormFooter {
                    Text("Files in Dropbox or iCloud that are not downloaded are skipped. Including them makes the provider download each file.")
                }
            }

            Section {
                SecureField("API Key", text: $keyDraft, prompt: Text("Paste your key"))
                    .onAppear { keyDraft = account.apiKey }
                    .onSubmit { account.apiKey = keyDraft }
                    .onDisappear { account.apiKey = keyDraft }
            } header: {
                Text("YouTube Search")
            } footer: {
                FormFooter {
                    Text("In Google Cloud Console, enable \"YouTube Data API v3\", then create a key under Credentials. The key is kept in your Keychain.")
                    Link("Open Google Cloud Console", destination: URL(string: "https://console.cloud.google.com/apis/library/youtube.googleapis.com")!)
                        .foregroundStyle(.link) // the footer's secondary color would turn it grey
                }
            }

            Section {
                if let username = bandcamp.username {
                    LabeledContent("Signed in as \(username)") { Button("Sign Out") { bandcamp.signOut() } }
                } else {
                    LabeledContent("Not signed in") { Button("Sign In…") { showBandcampLogin = true } }
                }
                Picker("Format", selection: $bandcamp.format) {
                    ForEach(BandcampFormat.allCases) { Text($0.label).tag($0) }
                }
                LabeledContent {
                    Button("Sync Now") { library.folder.map(bandcampSync.sync) }
                        .disabled(!bandcamp.isSignedIn || library.folder == nil || bandcampSync.isRunning)
                } label: {
                    Text(bandcampSync.status ?? bandcampSync.lastResult ?? "")
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled) // failures can be long; let them be copied
                }
            } header: {
                Text("Bandcamp")
            } footer: {
                FormFooter {
                    Text("Sync downloads your purchases into the music folder, and later only new ones. Albums you delete are not downloaded again. Tag fixes are saved into MP3 files only.")
                }
            }

            Section {
                ToolRow(name: "yt-dlp")
                ToolRow(name: "ffmpeg")
            } header: {
                Text("Downloads")
            } footer: {
                if !Tools.missing.isEmpty {
                    FormFooter {
                        HStack {
                            Text("Install with Homebrew: ") + Text(Tools.installCommand).monospaced()
                            Button("Copy") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(Tools.installCommand, forType: .string)
                            }
                            .controlSize(.small)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showBandcampLogin) { BandcampLoginSheet() }
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Small, left-aligned help text under a section, like System Settings.
/// (Grouped form footers are trailing-aligned and body-sized by default.)
private struct FormFooter<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) { content }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ToolRow: View {
    let name: String

    var body: some View {
        LabeledContent(name) {
            if let url = Tools.find(name) {
                HStack(spacing: 6) {
                    Text(url.path).foregroundStyle(.secondary)
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
            } else {
                HStack(spacing: 6) {
                    Text("Not installed").foregroundStyle(.secondary)
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                }
            }
        }
    }
}
