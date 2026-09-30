import SwiftUI

struct SettingsView: View {
    @Environment(Library.self) private var library
    @State private var account = YouTubeAccount.shared
    /// Saved on Return or when Settings closes, not on every keystroke.
    @State private var keyDraft = ""

    var body: some View {
        @Bindable var library = library
        Form {
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
