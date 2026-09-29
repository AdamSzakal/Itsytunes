import SwiftUI

struct ContentView: View {
    @Environment(Library.self) private var library
    @Environment(Player.self) private var player
    @State private var selection: Song.ID?
    @State private var search = ""
    @State private var showYouTube = false
    /// Column order, widths and visibility, saved across launches.
    @State private var columns: TableColumnCustomization<Song> = {
        guard let data = UserDefaults.standard.data(forKey: "columns") else { return TableColumnCustomization() }
        return (try? JSONDecoder().decode(TableColumnCustomization<Song>.self, from: data)) ?? TableColumnCustomization()
    }()
    @State private var sortOrder = [
        KeyPathComparator(\Song.artist), KeyPathComparator(\Song.album), KeyPathComparator(\Song.trackSort),
    ]

    private var rows: [Song] {
        let query = search.trimmingCharacters(in: .whitespaces)
        let songs = query.isEmpty ? library.songs : library.songs.filter { song in
            [song.displayTitle, song.artist, song.album, song.genre].contains { $0.localizedCaseInsensitiveContains(query) }
        }
        return songs.sorted(using: sortOrder)
    }

    private var subtitle: String {
        guard let folder = library.folder else { return "" }
        return "\((folder.path as NSString).abbreviatingWithTildeInPath)  ·  \(library.songs.count) songs"
    }

    var body: some View {
        VStack(spacing: 0) {
            if library.folder == nil {
                ContentUnavailableView {
                    Label("No Music Folder", systemImage: "music.note.list")
                } description: {
                    Text("Choose a folder. TinyPlayer finds every song in it, including subfolders.")
                } actions: {
                    Button("Choose Folder…") { library.chooseFolder() }
                }
            } else {
                table
            }
            DownloadsBar()
            Divider()
            PlayerBar()
        }
        .navigationTitle("TinyPlayer")
        .navigationSubtitle(subtitle)
        .searchable(text: $search, placement: .toolbar)
        .toolbar {
            ToolbarItem {
                if let status = library.scanStatus ?? library.tagStatus { StatusPill(text: status) }
            }
            ToolbarItem {
                Button("Choose Folder…") { library.chooseFolder() }
            }
            ToolbarItem {
                Button { showYouTube = true } label: { Label("Search YouTube", systemImage: "play.rectangle") }
                    .help("Search YouTube")
            }
        }
        .sheet(isPresented: $showYouTube) {
            YouTubeSheet(query: youTubeQuery)
        }
    }

    /// "Artist Title" of the selected song, else of the playing one.
    private var youTubeQuery: String {
        guard let song = library.songs.first(where: { $0.id == selection }) ?? player.current else { return "" }
        return [song.artist, song.displayTitle].filter { !$0.isEmpty }.joined(separator: " ")
    }

    private var table: some View {
        let rows = rows
        let song = { (id: Song.ID?) in rows.first { $0.id == id } }
        // Drag headers to reorder; right-click a header to show or hide columns.
        return Table(rows, selection: $selection, sortOrder: $sortOrder, columnCustomization: $columns) {
            TableColumn("Art") { song in ArtworkView(key: song.artworkKey, size: 20) }
                .width(28)
                .customizationID("art")
            TableColumn("#", value: \Song.trackSort) { song in
                Text(song.track.map(String.init) ?? "").foregroundStyle(.secondary)
            }
            .width(32)
            .customizationID("track")
            TableColumn("Title", value: \Song.displayTitle) { song in
                let playing = player.current?.id == song.id
                HStack(spacing: 6) {
                    if playing { Image(systemName: "speaker.wave.2.fill").foregroundStyle(.tint) }
                    Text(song.displayTitle).fontWeight(playing ? .semibold : .regular)
                }
            }
            .width(min: 120, ideal: 280)
            .customizationID("title")
            .disabledCustomizationBehavior(.visibility) // a table without titles is useless
            TableColumn("Artist", value: \Song.artist)
                .width(min: 80, ideal: 180)
                .customizationID("artist")
            TableColumn("Album", value: \Song.album)
                .width(min: 80, ideal: 200)
                .customizationID("album")
            TableColumn("Year", value: \Song.year)
                .width(44)
                .customizationID("year")
            TableColumn("Genre", value: \Song.genre)
                .width(min: 60, ideal: 100)
                .customizationID("genre")
            TableColumn("Time", value: \Song.duration) { song in
                Text(formatTime(song.duration)).monospacedDigit().foregroundStyle(.secondary)
            }
            .width(48)
            .customizationID("time")
        }
        .onChange(of: columns) {
            UserDefaults.standard.set(try? JSONEncoder().encode(columns), forKey: "columns")
        }
        .contextMenu(forSelectionType: Song.ID.self) { ids in
            if let item = song(ids.first) {
                Button("Play") { player.play(item, queue: rows) }
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
            }
        } primaryAction: { ids in
            if let item = song(ids.first) { player.play(item, queue: rows) }
        }
        .onKeyPress(.space) {
            if player.current == nil, let item = song(selection) {
                player.play(item, queue: rows)
            } else {
                player.toggle()
            }
            return .handled
        }
    }
}

struct PlayerBar: View {
    @Environment(Player.self) private var player

    var body: some View {
        @Bindable var player = player
        HStack(spacing: 16) {
            HStack(spacing: 12) {
                ArtworkView(key: player.current?.artworkKey, size: 52)
                VStack(alignment: .leading, spacing: 2) {
                    Text(player.current?.displayTitle ?? "Not Playing")
                        .font(.system(size: 13, weight: .semibold))
                    Text([player.current?.artist, player.current?.album].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " — "))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .lineLimit(1)
            }
            .frame(width: 260, alignment: .leading)

            VStack(spacing: 6) {
                HStack(spacing: 22) {
                    IconButton(symbol: "shuffle", active: player.shuffle) { player.shuffle.toggle() }
                    IconButton(symbol: "backward.fill") { player.previous() }
                    Button(action: player.toggle) {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(Color(nsColor: .windowBackgroundColor))
                            .frame(width: 32, height: 32)
                            .background(Circle().fill(.primary))
                    }
                    .buttonStyle(.plain)
                    IconButton(symbol: "forward.fill") { player.next() }
                    IconButton(symbol: "repeat", active: player.repeatAll) { player.repeatAll.toggle() }
                }
                .disabled(player.current == nil)
                HStack(spacing: 8) {
                    Text(formatTime(player.currentTime))
                    Slider(value: Binding(get: { player.currentTime }, set: { player.seek(to: $0) }),
                           in: 0...max(player.duration, 1))
                        .controlSize(.mini)
                    Text("-" + formatTime(player.duration - player.currentTime))
                }
                .font(.system(size: 10, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(maxWidth: 520)
            }
            .frame(maxWidth: .infinity)

            HStack(spacing: 8) {
                Image(systemName: "speaker.fill").font(.system(size: 11)).foregroundStyle(.secondary)
                Slider(value: $player.volume, in: 0...1).controlSize(.mini).frame(width: 90)
            }
            .frame(width: 260, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.bar)
    }
}

/// One line per YouTube download, above the player bar. Hidden when nothing is downloading.
private struct DownloadsBar: View {
    @Environment(Downloader.self) private var downloader

    var body: some View {
        VStack(spacing: 0) {
            if !downloader.visible.isEmpty {
                Divider()
                VStack(spacing: 6) {
                    ForEach(downloader.visible) { video in
                        DownloadRow(video: video, status: downloader.status[video.id]) { downloader.dismiss(video) }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(.bar)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: downloader.visible.map(\.id))
    }
}

private struct DownloadRow: View {
    let video: YouTubeVideo
    let status: Downloader.Status?
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.down.circle").foregroundStyle(.secondary)
            Text(video.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
            Spacer(minLength: 12)
            switch status {
            case .downloading(let progress)?:
                ProgressView(value: progress).frame(width: 160)
                Text("\(Int(progress * 100))%").frame(width: 34, alignment: .trailing)
            case .processing?:
                ProgressView().progressViewStyle(.linear).frame(width: 160)
                Text("Converting").frame(width: 70, alignment: .trailing)
            case .done?:
                Label("Added to library", systemImage: "checkmark.circle.fill").labelStyle(StatusLabelStyle(color: .green))
            case .failed(let message)?:
                Label(message, systemImage: "exclamationmark.triangle.fill").labelStyle(StatusLabelStyle(color: .orange))
                    .help(message)
                Button(action: onDismiss) { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
            case nil:
                EmptyView()
            }
        }
        .font(.system(size: 11))
        .monospacedDigit()
        .foregroundStyle(.secondary)
    }
}

/// Colored icon, secondary text.
private struct StatusLabelStyle: LabelStyle {
    let color: Color

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon.foregroundStyle(color)
            configuration.title.lineLimit(1)
        }
    }
}

private struct IconButton: View {
    let symbol: String
    var active: Bool?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: active == nil ? 15 : 13))
                .foregroundStyle(active == true ? AnyShapeStyle(.tint) : active == false ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
        }
        .buttonStyle(.plain)
    }
}

private struct StatusPill: View {
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(.tint).frame(width: 7, height: 7)
            Text(text).font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(.tint)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Color.accentColor.opacity(0.12), in: Capsule())
    }
}

struct ArtworkView: View {
    let key: String?
    let size: CGFloat

    var body: some View {
        Group {
            if let key, let image = ArtworkStore.image(key) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Rectangle().fill(.quaternary)
                    .overlay(Image(systemName: "music.note").font(.system(size: size * 0.45)).foregroundStyle(.secondary))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size > 30 ? 6 : 3))
    }
}
