import SwiftUI

struct YouTubeSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(Library.self) private var library
    @Environment(Downloader.self) private var downloader
    @State private var account = YouTubeAccount.shared
    @State private var query: String
    @State private var results: [YouTubeVideo] = []
    @State private var loading = false
    @State private var error: String?
    @State private var missingTools: [String] = []

    init(query: String) {
        _query = State(initialValue: query)
    }

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                SearchField(prompt: "Search YouTube", text: $query) { Task { await search() } }
                    .disabled(account.apiKey.isEmpty)
                Text(hint).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .padding(16)

            Divider()
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()

            HStack {
                SettingsLink { Text("Settings…") }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(12)
        }
        .frame(width: 560, height: 460)
        .task { await search() }
        .alert("\(missingTools.joined(separator: " and ")) not installed", isPresented: Binding(
            get: { !missingTools.isEmpty }, set: { if !$0 { missingTools = [] } }
        )) {
            Button("Copy Install Command") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(Tools.installCommand, forType: .string)
            }
            Button("OK", role: .cancel) {}
        } message: {
            Text("TinyPlayer uses yt-dlp and ffmpeg to download audio. Install them with Homebrew:\n\n\(Tools.installCommand)")
        }
    }

    private var hint: String {
        guard let folder = library.folder else { return "Choose a music folder first. Downloads are saved there." }
        let path = (folder.path as NSString).abbreviatingWithTildeInPath
        return "Click a result to save its audio to \(path). Videos with chapters are split into one song per chapter."
    }

    @ViewBuilder
    private var content: some View {
        if account.apiKey.isEmpty {
            ContentUnavailableView {
                Label("Add a YouTube API Key", systemImage: "key")
            } description: {
                Text("Search uses the YouTube Data API. Add a free key in Settings.")
            } actions: {
                SettingsLink { Text("Open Settings…") }
            }
        } else if let error {
            ContentUnavailableView("Search Failed", systemImage: "exclamationmark.triangle", description: Text(error))
        } else if loading {
            ProgressView().controlSize(.small)
        } else if results.isEmpty {
            ContentUnavailableView("Search YouTube", systemImage: "play.rectangle",
                                   description: Text("The first 10 videos are listed here."))
        } else {
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(results) { video in
                        ResultRow(video: video, status: downloader.status[video.id]) { select(video) }
                    }
                }
                .padding(8)
            }
        }
    }

    private func select(_ video: YouTubeVideo) {
        missingTools = Tools.missing
        guard missingTools.isEmpty, let folder = library.folder else { return }
        downloader.download(video, into: folder)
        dismiss() // progress continues in the main window's footer
    }

    private func search() async {
        guard !account.apiKey.isEmpty, !trimmedQuery.isEmpty, !loading else { return }
        loading = true
        error = nil
        defer { loading = false }
        do {
            results = try await YouTube.search(trimmedQuery, key: account.apiKey)
        } catch {
            results = []
            self.error = error.localizedDescription
        }
    }
}

/// Rounded search field with a focus ring, matching the toolbar search.
private struct SearchField: View {
    let prompt: String
    @Binding var text: String
    let onSubmit: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .focused($focused)
                .onSubmit(onSubmit)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
            }
        }
        .font(.system(size: 14))
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 9))
        .overlay {
            RoundedRectangle(cornerRadius: 9)
                .strokeBorder(Color.accentColor.opacity(focused ? 0.5 : 0), lineWidth: 2.5)
        }
        .animation(.easeOut(duration: 0.15), value: focused)
        .onAppear { focused = true }
    }
}

private struct ResultRow: View {
    let video: YouTubeVideo
    let status: Downloader.Status?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                AsyncImage(url: video.thumbnail) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    Rectangle().fill(.quaternary)
                }
                .frame(width: 48, height: 27)
                .clipShape(RoundedRectangle(cornerRadius: 3))

                Text(video.title)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(video.channel)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: 140, alignment: .trailing)
                StatusIcon(status: status, hovering: hovering).frame(width: 20)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(.quaternary.opacity(hovering ? 0.8 : 0), in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(helpText)
        .contextMenu {
            Button("Open in Browser") { NSWorkspace.shared.open(video.url) }
            Button("Copy Link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(video.url.absoluteString, forType: .string)
            }
        }
    }

    private var helpText: String {
        if case .failed(let message)? = status { return message }
        return video.title
    }
}

private struct StatusIcon: View {
    let status: Downloader.Status?
    let hovering: Bool

    var body: some View {
        switch status {
        case nil:
            Image(systemName: "arrow.down.circle").foregroundStyle(hovering ? .primary : .tertiary)
        case .downloading(let progress)?:
            ProgressView(value: progress).progressViewStyle(.circular).controlSize(.small)
        case .processing?:
            ProgressView().controlSize(.small)
        case .done?:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed?:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }
}
