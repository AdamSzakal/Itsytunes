import SwiftUI

struct ContentView: View {
    @Environment(Library.self) private var library
    @Environment(Player.self) private var player
    @Environment(Downloader.self) private var downloader
    @State private var selection: Set<Song.ID> = []
    /// Downloaded songs to show once the library has scanned them.
    @State private var pendingReveal: Set<Song.ID> = []
    /// Song to scroll to in the table or album list.
    @State private var scrollTarget: Song.ID?
    @State private var fixing: FixRequest?
    @AppStorage("libraryLayout") private var layout = LibraryLayout.songs
    @State private var search = ""
    @State private var showYouTube = false
    @State private var viewingArtwork: Song?
    /// Column order, widths and visibility, saved across launches.
    /// v2: layouts saved before the row-number column existed put it last, so they are dropped once.
    @State private var columns: TableColumnCustomization<Song> = {
        guard let data = UserDefaults.standard.data(forKey: "columns-v2") else { return TableColumnCustomization() }
        return (try? JSONDecoder().decode(TableColumnCustomization<Song>.self, from: data)) ?? TableColumnCustomization()
    }()
    @State private var sortOrder = [
        KeyPathComparator(\Song.artist), KeyPathComparator(\Song.album), KeyPathComparator(\Song.trackSort),
    ]

    /// Songs matching the search, in library order.
    private var matches: [Song] {
        let query = search.trimmingCharacters(in: .whitespaces)
        return query.isEmpty ? library.songs : library.songs.filter { song in
            [song.displayTitle, song.artist, song.album, song.genre].contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    private var rows: [Song] { matches.sorted(using: sortOrder) }

    /// "Parent › Folder", so the button reads as a chosen folder and not only a name.
    private var folderLabel: String {
        guard let folder = library.folder else { return "Choose Folder…" }
        let parent = folder.deletingLastPathComponent().lastPathComponent
        return parent.isEmpty || parent == "/" ? folder.lastPathComponent : "\(parent) › \(folder.lastPathComponent)"
    }

    /// Full path and song count, shown when hovering the folder button.
    private var folderHelp: String {
        guard let folder = library.folder else { return "Choose a music folder" }
        return "\((folder.path as NSString).abbreviatingWithTildeInPath)  ·  \(library.songs.count) songs"
    }

    var body: some View {
        VStack(spacing: 0) {
            Group {
            if library.folder == nil {
                ContentUnavailableView {
                    Label("No Music Folder", systemImage: "music.note.list")
                } description: {
                    Text("Choose a folder. Itsytunes finds every song in it, including subfolders.")
                } actions: {
                    Button("Choose Folder…") { library.chooseFolder() }
                }
            } else if !search.isEmpty && matches.isEmpty {
                ContentUnavailableView.search(text: search)
            } else if layout == .albums {
                AlbumListView(songs: matches, scrollTarget: $scrollTarget, showArtwork: { viewingArtwork = $0 }) { fixing = FixRequest(songs: $0, online: $1) }
            } else {
                ScrollViewReader { table($0) }
            }
            }
            // Always fill the space: the empty states only take their own height, which moved the player bar up.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            DownloadsBar()
            Divider()
            PlayerBar { viewingArtwork = $0 }
        }
        .overlay {
            if let song = viewingArtwork {
                ArtworkViewer(song: song) { viewingArtwork = nil }
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: viewingArtwork?.id)
        .onAppear { player.library = { [library] in library.songs } }
        .onChange(of: downloader.added) {
            pendingReveal = Set(downloader.added.map(\.path))
            revealDownload()
        }
        .onChange(of: library.scanStatus) { revealDownload() }
        // An empty title keeps the toolbar's flexible gap, which pushes the primary items to the right.
        // (Removing the title removes the gap too.) The Window menu uses the scene's name, "Itsytunes".
        .navigationTitle("")
        .searchable(text: $search, placement: .toolbar, prompt: "Search  ⌘F")
        .toolbar {
            // Where the title was: the library folder, click to change it.
            ToolbarItem(placement: .navigation) {
                Button { library.chooseFolder() } label: {
                    Label(folderLabel, systemImage: "folder")
                        .labelStyle(.titleAndIcon)
                }
                .help(folderHelp)
            }
            // Clean-up button and job chip share one fixed-width slot, lined up from the left: a slot's
            // content is centered by macOS, and a width that follows the text would move the right side.
            ToolbarItem(placement: .navigation) {
                HStack(spacing: 8) {
                    if let write = library.tagWrite {
                        StatusPill(text: "\(write.verb) \(write.done) of \(write.total) tags", job: .renaming)
                    } else if !library.noisyTitles.isEmpty {
                        Button { fixing = FixRequest(songs: library.noisyTitles, online: false) } label: {
                            Label("Clean up \(library.noisyTitles.count) tags", systemImage: "wand.and.stars")
                                .labelStyle(.titleAndIcon)
                        }
                        .help("\(library.noisyTitles.count) titles have upload noise, like video IDs or track numbers")
                    }
                    if let status = library.scanStatus {
                        StatusPill(text: status, job: .scanning)
                    } else if let status = library.tagStatus {
                        StatusPill(text: status, job: .tagging)
                    }
                    Spacer(minLength: 0)
                }
                .frame(width: 340, alignment: .leading)
            }
            // Right side, next to the search field, so the changing items on the left don't move them.
            ToolbarItem(placement: .primaryAction) {
                Picker("View", selection: $layout) {
                    Label("Songs", systemImage: "list.bullet").tag(LibraryLayout.songs)
                    Label("Albums", systemImage: "square.stack").tag(LibraryLayout.albums)
                }
                .pickerStyle(.segmented)
                .help("Show songs as a list or grouped by album")
            }
            ToolbarItem(placement: .primaryAction) {
                Button { showYouTube = true } label: { Label("Search YouTube", systemImage: "play.rectangle") }
                    .keyboardShortcut("k")
                    .help("Search YouTube (⌘K)")
            }
        }
        .sheet(isPresented: $showYouTube) {
            YouTubeSheet(query: youTubeQuery)
        }
        .sheet(item: $fixing) { FixTagsSheet(songs: $0.songs, online: $0.online) }
        .onReceive(NotificationCenter.default.publisher(for: .cleanUpAllTitles)) { _ in
            fixing = FixRequest(songs: library.songs, online: false)
        }
    }

    /// Selects the downloaded songs and scrolls to them, once a scan has added all of them.
    private func revealDownload() {
        guard !pendingReveal.isEmpty, library.scanStatus == nil,
              pendingReveal.isSubset(of: Set(library.songs.map(\.id))) else { return }
        search = "" // a search could hide the new songs
        selection = pendingReveal
        scrollTarget = rows.first { pendingReveal.contains($0.id) }?.id
        pendingReveal = []
    }

    /// "Artist Title" of the selected song, else of the playing one.
    private var youTubeQuery: String {
        guard let song = library.songs.first(where: { selection.contains($0.id) }) ?? player.current else { return "" }
        return [song.artist, song.displayTitle].filter { !$0.isEmpty }.joined(separator: " ")
    }

    private func table(_ scroller: ScrollViewProxy) -> some View {
        let rows = rows
        let rowNumbers = Dictionary(rows.enumerated().map { ($1.id, $0 + 1) }, uniquingKeysWith: { a, _ in a })
        // First of the given songs in table order.
        let firstSong = { (ids: Set<Song.ID>) in rows.first { ids.contains($0.id) } }
        // Drag headers to reorder; right-click a header to show or hide columns.
        return Table(rows, selection: $selection, sortOrder: $sortOrder, columnCustomization: $columns) {
            // Position in the current sort and filter; cannot be moved or hidden.
            TableColumn("#") { song in
                Group {
                    if player.current?.id == song.id {
                        Image(systemName: "speaker.wave.2.fill").font(.system(size: 11))
                    } else {
                        Text(rowNumbers[song.id].map(String.init) ?? "")
                    }
                }
                .foregroundStyle(player.current?.id == song.id ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 34, ideal: 34, max: 34) // a fixed max, or as the last column it would stretch
            .customizationID("row")
            .disabledCustomizationBehavior(.all)
            TableColumn("Art") { song in
                ArtworkView(key: song.artworkKey, size: 18)
                    .onTapGesture { if song.artworkKey != nil { viewingArtwork = song } }
            }
            .width(24)
            .customizationID("art")
            TableColumn("Title", value: \Song.displayTitle) { song in
                Text(song.displayTitle)
                    .font(.system(size: 12))
                    // Bold, not colored: a color would clash with the blue selection.
                    .fontWeight(player.current?.id == song.id ? .semibold : .regular)
            }
            .width(min: 120, ideal: 300)
            .customizationID("title")
            .disabledCustomizationBehavior(.visibility) // a table without titles is useless
            TableColumn("Artist", value: \Song.artist) { Text($0.artist).foregroundStyle(.secondary) }
                .width(min: 80, ideal: 200)
                .customizationID("artist")
            TableColumn("Album", value: \Song.album) { Text($0.album).foregroundStyle(.secondary) }
                .width(min: 80, ideal: 200)
                .customizationID("album")
            TableColumn("Track", value: \Song.trackSort) { song in
                Text(song.track.map(String.init) ?? "").foregroundStyle(.secondary)
            }
            .width(44)
            .customizationID("track")
            .defaultVisibility(.hidden)
            TableColumn("Year", value: \Song.year) { Text($0.year).foregroundStyle(.secondary) }
                .width(50)
                .customizationID("year")
            TableColumn("Genre", value: \Song.genre) { Text($0.genre).foregroundStyle(.secondary) }
                .width(min: 60, ideal: 110)
                .customizationID("genre")
            TableColumn(Text("\(Image(systemName: "clock"))"), value: \Song.duration) { song in
                Text(formatTime(song.duration))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(52)
            .customizationID("time")
        }
        .font(.system(size: 11))
        .monospacedDigit()
        .alternatingRowBackgrounds(.disabled)
        .background(HiddenRowSeparators())
        .onChange(of: columns) {
            UserDefaults.standard.set(try? JSONEncoder().encode(columns), forKey: "columns-v2")
        }
        .contextMenu(forSelectionType: Song.ID.self) { ids in
            if let item = firstSong(ids) {
                let items = rows.filter { ids.contains($0.id) }
                Button("Play") { player.play(item, queue: rows) }
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(items.map(\.url)) }
                Divider()
                Button(items.count == 1 ? "Fix Tags…" : "Fix Tags of \(items.count) Songs…") {
                    fixing = FixRequest(songs: items, online: true)
                }
                Button(items.count == 1 ? "Clean Up Title…" : "Clean Up \(items.count) Titles…") {
                    fixing = FixRequest(songs: items, online: false)
                }
            }
        } primaryAction: { ids in
            if let item = firstSong(ids) { player.play(item, queue: rows) }
        }
        .onKeyPress(.space) {
            if player.current == nil, let item = firstSong(selection) {
                player.play(item, queue: rows)
            } else {
                player.toggle()
            }
            return .handled
        }
        // A task, not onChange: the table may appear with the target already set (after a search is cleared).
        .task(id: scrollTarget) {
            guard let target = scrollTarget else { return }
            // Wait for the list to lay out the new songs: scrolling in the same update does nothing.
            try? await Task.sleep(for: .milliseconds(150))
            scroller.scrollTo(target, anchor: .center)
            scrollTarget = nil
        }
    }
}

/// Songs to review in `FixTagsSheet`, with or without an online lookup.
struct FixRequest: Identifiable {
    let id = UUID()
    let songs: [Song]
    let online: Bool
}

extension Notification.Name {
    /// Sent by the File menu; the main window opens the title clean-up for the whole library.
    static let cleanUpAllTitles = Notification.Name("cleanUpAllTitles")
}

struct PlayerBar: View {
    @Environment(Player.self) private var player
    let showArtwork: (Song) -> Void

    var body: some View {
        @Bindable var player = player
        // Controls | center display (cover, title, progress) | volume.
        // The display takes all free width, so long titles are rarely cut.
        HStack(spacing: 20) {
            HStack(spacing: 18) {
                IconButton(symbol: "shuffle", active: player.shuffle) { player.shuffle.toggle() }
                IconButton(symbol: "backward.fill") { player.previous() }
                    .disabled(player.current == nil)
                Button(action: player.toggle) {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Color(nsColor: .windowBackgroundColor))
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(.primary))
                }
                .buttonStyle(.plain)
                IconButton(symbol: "forward.fill") { player.next() }
                    .disabled(player.current == nil)
                IconButton(symbol: "repeat", active: player.repeatAll) { player.repeatAll.toggle() }
            }

            HStack(spacing: 10) {
                ArtworkView(key: player.current?.artworkKey, size: 44)
                    .onTapGesture { if let song = player.current, song.artworkKey != nil { showArtwork(song) } }
                VStack(alignment: .leading, spacing: 2) {
                    Text(player.current?.displayTitle ?? "Not Playing")
                        .font(.system(size: 12, weight: .semibold))
                        .help(player.current?.displayTitle ?? "")
                    Text([player.current?.artist, player.current?.album].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " — "))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        Text(formatTime(player.currentTime))
                        Slider(value: Binding(get: { player.currentTime }, set: { player.seek(to: $0) }),
                               in: 0...max(player.duration, 1))
                            .controlSize(.mini)
                            .disabled(player.current == nil)
                        Text("-" + formatTime(player.duration - player.currentTime))
                    }
                    .font(.system(size: 10, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                }
                .lineLimit(1)
            }
            .padding(6)
            .frame(maxWidth: 760)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            .frame(maxWidth: .infinity)

            HStack(spacing: 8) {
                Image(systemName: "speaker.fill").font(.system(size: 11)).foregroundStyle(.secondary)
                Slider(value: $player.volume, in: 0...1).controlSize(.mini).frame(width: 80)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
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
            Text(video.title).font(.system(size: 11, weight: .medium)).lineLimit(1)
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
        .font(.system(size: 10))
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

/// A running background job: spinner and text in the job's color.
private struct StatusPill: View {
    /// One color per job, so it is clear what is running.
    enum Job {
        case scanning, tagging, renaming

        var color: Color {
            switch self {
            case .scanning: .blue
            case .tagging: .purple
            case .renaming: .orange
            }
        }
    }

    let text: String
    let job: Job

    var body: some View {
        HStack(spacing: 6) {
            Spinner(color: job.color)
            Text(text).font(.system(size: 10, weight: .medium))
        }
        .foregroundStyle(job.color)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(job.color.opacity(0.14), in: Capsule())
    }
}

/// Small spinner in any color (the system spinner is always grey).
/// A Core Animation layer does the turning in the render server: a SwiftUI animation redrew the window
/// on every frame (and once also moved the chip), which made scanning and tagging feel laggy.
private struct Spinner: NSViewRepresentable {
    let color: Color

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 9, height: 9))
        view.wantsLayer = true
        let arc = CAShapeLayer()
        arc.frame = view.bounds
        arc.path = CGPath(ellipseIn: view.bounds.insetBy(dx: 0.75, dy: 0.75), transform: nil)
        arc.fillColor = nil
        arc.lineWidth = 1.5
        arc.lineCap = .round
        arc.strokeEnd = 0.7
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = -2 * Double.pi // clockwise
        spin.duration = 0.8
        spin.repeatCount = .infinity
        arc.add(spin, forKey: "spin")
        view.layer?.addSublayer(arc)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        (view.layer?.sublayers?.first as? CAShapeLayer)?.strokeColor = NSColor(color).cgColor
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSView, context: Context) -> CGSize? {
        CGSize(width: 9, height: 9)
    }
}

private extension View {
    /// The folder button replaces the title. macOS 14 cannot remove it, so there the title stays.
    @ViewBuilder
    func hidingToolbarTitle() -> some View {
        if #available(macOS 15, *) {
            toolbar(removing: .title)
        } else {
            self
        }
    }
}

/// Cover art at full size over the window. Click anywhere or press Esc to close.
private struct ArtworkViewer: View {
    let song: Song
    let onClose: () -> Void
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            // Blur what is behind, so the window's own text does not show through the caption.
            Rectangle().fill(.ultraThinMaterial)
            Rectangle().fill(.black.opacity(0.5))
            VStack(spacing: 14) {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: min(image.size.width, 800), maxHeight: min(image.size.height, 800))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .shadow(color: .black.opacity(0.5), radius: 30, y: 12)
                }
                VStack(spacing: 2) {
                    Text(song.album.isEmpty ? song.displayTitle : song.album).font(.headline)
                    Text(song.artist).font(.subheadline).opacity(0.7)
                }
                .foregroundStyle(.white)
            }
            .padding(40)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onClose)
        .background {
            // Invisible button, so Esc closes the viewer.
            Button("Close", action: onClose).keyboardShortcut(.cancelAction).opacity(0)
        }
        .task(id: song.id) {
            // Show the cached 512 px cover at once, then the file's own (often larger) cover.
            image = song.artworkKey.flatMap(ArtworkStore.image)
            if let data = await MetadataReader.read(song.url).artwork, let full = NSImage(data: data),
               full.size.width > (image?.size.width ?? 0) {
                image = full
            }
        }
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
