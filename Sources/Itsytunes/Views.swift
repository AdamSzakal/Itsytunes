import SwiftUI

struct ContentView: View {
    @Environment(Library.self) private var library
    @Environment(Player.self) private var player
    @Environment(Downloader.self) private var downloader
    @Environment(BandcampSync.self) private var bandcampSync
    /// Selected songs. In the album and artist lists, it can instead hold the ID of the selected album or artist,
    /// which the song table ignores.
    @State private var selection: Set<Song.ID> = []
    /// Downloaded songs to show once the library has scanned them.
    @State private var pendingReveal: Set<Song.ID> = []
    /// Song, album or artist to scroll to in the table or the album and artist lists.
    @State private var scrollTarget: ScrollTarget?
    /// Albums and artists shown without their songs, in the album and artist views.
    @State private var collapsed = Set(UserDefaults.standard.stringArray(forKey: "collapsed") ?? [])
    @State private var tagRequest: TagRequest?
    @AppStorage("libraryLayout") private var layout = LibraryLayout.songs
    @AppStorage("search") private var search = ""
    /// Saved, so the app opens as it was left. The filter bar then opens too, so the hidden songs are no surprise.
    @State private var filter = UserDefaults.standard.decoded(SongFilter.self, forKey: "filter") ?? SongFilter()
    @State private var showFilters = UserDefaults.standard.decoded(SongFilter.self, forKey: "filter")?.isActive ?? false
    @State private var showYouTube = false
    @State private var showQuickSearch = false
    @State private var viewingArtwork: Song?
    /// Column order, widths and visibility, saved across launches.
    /// v2: layouts saved before the row-number column existed put it last, so they are dropped once.
    @State private var columns: TableColumnCustomization<Song> = {
        guard let data = UserDefaults.standard.data(forKey: "columns-v2") else { return TableColumnCustomization() }
        return (try? JSONDecoder().decode(TableColumnCustomization<Song>.self, from: data)) ?? TableColumnCustomization()
    }()
    @State private var sortOrder = UserDefaults.standard.decoded([SortKey].self, forKey: "sortOrder")?.compactMap(\.comparator)
        ?? [KeyPathComparator(\Song.artist), KeyPathComparator(\Song.album), KeyPathComparator(\Song.trackSort)]

    /// Songs matching the filter and the search, in library order.
    private var matches: [Song] {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty || filter.isActive else { return library.songs }
        let onlineOnly = library.onlineOnly
        return library.songs.filter { song in
            filter.includes(song, onlineOnly: onlineOnly) && (query.isEmpty
                || [song.displayTitle, song.artist, song.album, song.genre].contains { $0.localizedCaseInsensitiveContains(query) })
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
            if showFilters {
                FilterBar(filter: $filter, songs: library.songs, onlineOnly: library.onlineOnly)
                Divider()
            }
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
            } else if matches.isEmpty && filter.isActive {
                ContentUnavailableView {
                    Label("No Songs", systemImage: "line.3.horizontal.decrease.circle")
                } description: {
                    Text(filter.source == .onlineOnly && !library.includeOnlineOnly
                         ? "Online-only files are skipped. Include them in Settings."
                         : "No songs match the filters.")
                } actions: {
                    Button("Clear Filters") { filter = SongFilter() }
                }
            } else if layout == .songs {
                ScrollViewReader { table($0) }
            } else {
                Group {
                    if layout == .artists {
                        ArtistListView(songs: matches, selection: $selection, scrollTarget: $scrollTarget, collapsed: $collapsed, showArtwork: { viewingArtwork = $0 }) { tagRequest = TagRequest(songs: $0, action: $1) }
                    } else {
                        AlbumListView(songs: matches, selection: $selection, scrollTarget: $scrollTarget, collapsed: $collapsed, showArtwork: { viewingArtwork = $0 }) { tagRequest = TagRequest(songs: $0, action: $1) }
                    }
                }
                .overlay(alignment: .topTrailing) { collapseAllButton }
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
            } else if showQuickSearch {
                QuickSearch(songs: library.songs, root: library.folder?.path, onSelect: reveal) { showQuickSearch = false }
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: viewingArtwork?.id)
        .animation(.easeOut(duration: 0.1), value: showQuickSearch)
        .onAppear(perform: resume)
        .modifier(SaveViewState(filter: filter, collapsed: collapsed, sortOrder: sortOrder))
        .onChange(of: downloader.added) {
            pendingReveal = Set(downloader.added.map(\.path))
            revealDownload()
        }
        .onChange(of: bandcampSync.added) {
            pendingReveal = Set(bandcampSync.added.map(\.standardizedFileURL.path))
            revealDownload()
        }
        .onChange(of: library.scanStatus) { revealDownload() }
        // An empty title keeps the toolbar's flexible gap, which pushes the primary items to the right.
        // (Removing the title removes the gap too.) The Window menu uses the scene's name, "Itsytunes".
        .navigationTitle("")
        .toolbar {
            // Where the title was: the library folder, click to change it.
            ToolbarItem(placement: .navigation) {
                Button { library.chooseFolder() } label: {
                    Label(folderLabel, systemImage: "folder")
                        .labelStyle(.titleAndIcon)
                }
                .tooltip(folderHelp)
            }
            // Clean-up button and job chip share one fixed-width slot, lined up from the left: a slot's
            // content is centered by macOS, and a width that follows the text would move the right side.
            ToolbarItem(placement: .navigation) {
                HStack(spacing: 8) {
                    if let write = library.tagWrite {
                        StatusPill(text: "\(write.verb) \(write.done) of \(write.total) tags", job: .renaming)
                    } else if !library.noisyTitles.isEmpty {
                        Button { tagRequest = TagRequest(songs: library.noisyTitles, action: .cleanUp) } label: {
                            Label("Clean up \(library.noisyTitles.count) tags", systemImage: "wand.and.stars")
                                .labelStyle(.titleAndIcon)
                        }
                        .tooltip("\(library.noisyTitles.count) titles have upload noise, like video IDs or track numbers")
                    }
                    // A sync adds files, so the library scans all the time: the sync's progress says more.
                    if let status = bandcampSync.status {
                        StatusPill(text: status, job: .bandcamp)
                    } else if let status = library.scanStatus {
                        StatusPill(text: status, job: .scanning)
                    } else if let status = library.tagStatus {
                        StatusPill(text: status, job: .tagging)
                    }
                    Spacer(minLength: 0)
                }
                .frame(width: 340, alignment: .leading)
            }
            // Right side, so the changing items on the left don't move them.
            ToolbarItem(placement: .primaryAction) {
                Picker("View", selection: $layout) {
                    Label("Songs", systemImage: "list.bullet").tag(LibraryLayout.songs)
                    Label("Albums", systemImage: "square.stack").tag(LibraryLayout.albums)
                    Label("Artists", systemImage: "music.mic").tag(LibraryLayout.artists)
                }
                .pickerStyle(.segmented)
                .tooltip(segments: ["Songs", "Albums", "Artists"])
            }
            ToolbarItem(placement: .primaryAction) {
                Button { showYouTube = true } label: { Label("Search YouTube", systemImage: "play.rectangle") }
                    .keyboardShortcut("y")
                    .tooltip("Search YouTube  ⌘Y")
            }
            ToolbarItem(placement: .primaryAction) {
                LibrarySearchField(text: $search, prompt: "Search  ⌘F").frame(width: 200)
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    // Closing the bar clears the filters, so no song stays hidden without the bar showing why.
                    withAnimation(.easeOut(duration: 0.15)) {
                        showFilters.toggle()
                        if !showFilters { filter = SongFilter() }
                    }
                } label: {
                    // Filled while a filter is on, so hidden songs are not a surprise.
                    Label("Filter", systemImage: filter.isActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                }
                .keyboardShortcut("f", modifiers: [.command, .option])
                .tooltip(showFilters ? "Close the filters and show all songs  ⌥⌘F" : "Filter by source, artist or album  ⌥⌘F")
            }
        }
        .sheet(isPresented: $showYouTube) {
            YouTubeSheet(query: youTubeQuery)
        }
        .sheet(item: $tagRequest) { request in
            if request.action == .edit {
                TagEditorSheet(songs: request.songs)
            } else {
                FixTagsSheet(songs: request.songs, online: request.action == .fixOnline)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .cleanUpAllTitles)) { _ in
            tagRequest = TagRequest(songs: library.songs, action: .cleanUp)
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleQuickSearch)) { _ in
            if library.folder != nil { showQuickSearch.toggle() }
        }
    }

    /// Selects the downloaded songs and scrolls to them, once a scan has added all of them.
    /// Carries on where the last session stopped: the song is loaded paused, and shown in the list.
    private func resume() {
        player.library = { [library] in library.songs }
        player.restore(from: library.songs)
        if let song = player.current {
            selection = [song.id]
            scrollTarget = ScrollTarget(id: song.id)
        }
    }

    private func revealDownload() {
        guard !pendingReveal.isEmpty, library.scanStatus == nil,
              pendingReveal.isSubset(of: Set(library.songs.map(\.id))) else { return }
        search = "" // a search could hide the new songs
        selection = pendingReveal
        scrollTarget = rows.first { pendingReveal.contains($0.id) }.map { ScrollTarget(id: $0.id) }
        pendingReveal = []
    }

    /// Floats over the album and artist lists. Once anything is folded, it unfolds everything; then it folds everything.
    private var collapseAllButton: some View {
        Button(action: toggleAllGroups) {
            Image(systemName: collapsed.isEmpty ? "rectangle.compress.vertical" : "rectangle.expand.vertical")
                .font(.system(size: 13))
                .frame(width: 30, height: 30)
                .background(.regularMaterial, in: Circle())
                .overlay(Circle().strokeBorder(.separator))
                .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(collapsed.isEmpty ? "Hide the songs of every \(layout == .albums ? "album" : "artist")" : "Show all songs")
        .padding(.top, 10)
        .padding(.trailing, 18) // clear of the scroll bar
    }

    /// Goes to a quick search result in the current layout and selects it. A picked album or artist goes to the
    /// top of the list, selected as one row, so Return plays it. In the song table, that is its first song.
    private func reveal(_ result: QuickSearchResult) {
        showQuickSearch = false
        let songs = result.songs
        // The search or a filter could hide the songs.
        search = ""
        if songs.contains(where: { !filter.includes($0, onlineOnly: library.onlineOnly) }) { filter = SongFilter() }
        let root = library.folder?.path
        let first = songs[0].id
        let id: String?
        switch (layout, result) {
        case (_, .song(let song)):
            id = song.id
        case (.songs, _):
            let ids = Set(songs.map(\.id))
            id = rows.first { ids.contains($0.id) }?.id
        case (.albums, .artist(let artist)):
            // The artist's first album as listed, not a compilation the artist is also on.
            let albums = AlbumListView.albums(of: matches, root: root)
            id = (albums.first { $0.artist.caseInsensitiveCompare(artist.name) == .orderedSame }
                ?? albums.first { $0.tracks.contains { $0.id == first } })?.id
        case (.albums, .album):
            id = AlbumListView.albums(of: matches, root: root).first { $0.tracks.contains { $0.id == first } }?.id
        case (.artists, .artist):
            id = ArtistListView.artists(of: matches, root: root).first { $0.albums.contains { $0.tracks.contains { $0.id == first } } }?.id
        case (.artists, .album):
            let artists = ArtistListView.artists(of: matches, root: root)
            id = artists.lazy.compactMap { artist in
                artist.albums.first { $0.tracks.contains { $0.id == first } }.map { ArtistListView.albumID($0, of: artist) }
            }.first
        }
        guard let id else { return }
        selection = [id]
        if case .song = result {
            scrollTarget = ScrollTarget(id: id)
        } else {
            scrollTarget = ScrollTarget(id: id, anchor: .top)
        }
    }

    private func toggleAllGroups() {
        withAnimation(.easeOut(duration: 0.15)) {
            if !collapsed.isEmpty {
                collapsed = []
            } else {
                let root = library.folder?.path
                collapsed = Set(layout == .albums ? AlbumListView.albums(of: matches, root: root).map(\.id)
                                                  : ArtistListView.artists(of: matches, root: root).map(\.id))
            }
        }
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
                // Songs that repeat plays again get accent-colored numbers, except on the blue selection.
                .foregroundStyle(player.isRepeated(song) && !selection.contains(song.id) ? AnyShapeStyle(.tint)
                                 : player.current?.id == song.id ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
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
                HStack(spacing: 6) {
                    Text(song.displayTitle)
                        .font(.system(size: 12))
                        // Bold, not colored: a color would clash with the blue selection.
                        .fontWeight(player.current?.id == song.id ? .semibold : .regular)
                    if let page = song.bandcampLink { BandcampMark(page: page) }
                }
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
                Button(items.count == 1 ? "Edit Tags…" : "Edit Tags of \(items.count) Songs…") {
                    tagRequest = TagRequest(songs: items, action: .edit)
                }
                .keyboardShortcut("i")
                Button(items.count == 1 ? "Fix Tags…" : "Fix Tags of \(items.count) Songs…") {
                    tagRequest = TagRequest(songs: items, action: .fixOnline)
                }
                Button(items.count == 1 ? "Clean Up Title…" : "Clean Up \(items.count) Titles…") {
                    tagRequest = TagRequest(songs: items, action: .cleanUp)
                }
            }
        } primaryAction: { ids in
            if let item = firstSong(ids) { player.play(item, queue: rows) }
        }
        .background {
            // Invisible button, so ⌘I edits the selected songs (a context menu's shortcut only shows the key).
            Button("Edit Tags") {
                let items = rows.filter { selection.contains($0.id) }
                if !items.isEmpty { tagRequest = TagRequest(songs: items, action: .edit) }
            }
            .keyboardShortcut("i")
            .opacity(0)
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
            scroller.scrollTo(target.id, anchor: target.anchor)
            scrollTarget = nil
        }
    }
}

/// Saves the filter, the folded groups and the sort order when they change, so the next launch shows the same view.
private struct SaveViewState: ViewModifier {
    let filter: SongFilter
    let collapsed: Set<String>
    let sortOrder: [KeyPathComparator<Song>]

    func body(content: Content) -> some View {
        content
            .onChange(of: filter) { UserDefaults.standard.setEncoded(filter, forKey: "filter") }
            .onChange(of: collapsed) { UserDefaults.standard.set(Array(collapsed), forKey: "collapsed") }
            .onChange(of: sortOrder) { UserDefaults.standard.setEncoded(sortOrder.compactMap { SortKey($0) }, forKey: "sortOrder") }
    }
}

/// One sort column of the song table, in a form that can be saved.
/// `KeyPathComparator` cannot be saved itself, so the key path is stored as the column's name.
private struct SortKey: Codable {
    let column: String
    let ascending: Bool

    /// The table's sortable columns.
    private static let columns: [String: KeyPathComparator<Song>] = [
        "title": KeyPathComparator(\.displayTitle), "artist": KeyPathComparator(\.artist), "album": KeyPathComparator(\.album),
        "track": KeyPathComparator(\.trackSort), "year": KeyPathComparator(\.year), "genre": KeyPathComparator(\.genre),
        "time": KeyPathComparator(\.duration),
    ]

    init?(_ comparator: KeyPathComparator<Song>) {
        guard let column = Self.columns.first(where: { $0.value.keyPath == comparator.keyPath })?.key else { return nil }
        self.column = column
        ascending = comparator.order == .forward
    }

    var comparator: KeyPathComparator<Song>? {
        guard var comparator = Self.columns[column] else { return nil }
        comparator.order = ascending ? .forward : .reverse
        return comparator
    }
}

/// What to do with the tags of some songs.
enum TagAction {
    /// Change tags by hand in `TagEditorSheet`.
    case edit
    /// Review tags found online in `FixTagsSheet`.
    case fixOnline
    /// Review cleaned-up titles in `FixTagsSheet`.
    case cleanUp
}

/// Songs to edit or review, for the tag sheets.
struct TagRequest: Identifiable {
    let id = UUID()
    let songs: [Song]
    let action: TagAction
}

extension Notification.Name {
    /// Sent by the File menu; the main window opens the title clean-up for the whole library.
    static let cleanUpAllTitles = Notification.Name("cleanUpAllTitles")
    /// Sent by Edit > Find; the toolbar search field takes the keyboard focus.
    static let focusLibrarySearch = Notification.Name("focusLibrarySearch")
    /// Sent by Edit > Quick Search; the main window opens or closes the quick search.
    static let toggleQuickSearch = Notification.Name("toggleQuickSearch")
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
                RepeatButton()
            }

            HStack(spacing: 10) {
                ArtworkView(key: player.current?.artworkKey, size: 44)
                    .onTapGesture { if let song = player.current, song.artworkKey != nil { showArtwork(song) } }
                VStack(alignment: .leading, spacing: 2) {
                    Text(player.current?.displayTitle ?? "Not Playing")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(player.repeatMode == .song ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                        .help(player.current?.displayTitle ?? "")
                    subtitle
                        .font(.system(size: 10))
                    ProgressRow()
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

    /// "Artist — Album", with the part that repeat plays over and over in the accent color.
    private var subtitle: Text {
        guard let song = player.current else { return Text("") }
        let parts = [(song.artist, RepeatMode.artist), (song.album, .album)].filter { !$0.0.isEmpty }
        return parts.enumerated().reduce(Text("")) { text, item in
            let (name, mode) = item.element
            let part = Text(name).foregroundStyle(player.repeatMode == mode ? Color.accentColor : .secondary)
            return text + Text(item.offset > 0 ? " — " : "").foregroundStyle(.secondary) + part
        }
    }
}

/// Elapsed time, position slider and remaining time. Redrawn on every screen refresh while playing, so the
/// slider moves smoothly: `Player.currentTime` changes only twice a second.
private struct ProgressRow: View {
    @Environment(Player.self) private var player

    var body: some View {
        TimelineView(.animation(paused: !player.isPlaying)) { _ in
            let time = player.position
            HStack(spacing: 6) {
                Text(formatTime(time))
                Slider(value: Binding(get: { time }, set: { player.seek(to: $0) }), in: 0...max(player.duration, 1))
                    .controlSize(.mini)
                    .disabled(player.current == nil)
                Text("-" + formatTime(player.duration - time))
            }
        }
    }
}

/// Cycles off → song → album → artist. A small badge tells album and artist apart, and the hover text names
/// what plays again.
private struct RepeatButton: View {
    @Environment(Player.self) private var player

    @ViewBuilder private var badge: some View {
        if player.repeatMode == .album {
            // A ring, like a CD: the "opticaldisc" symbol has too much detail at this size.
            Circle().strokeBorder(.tint, lineWidth: 2.5).frame(width: 8, height: 8)
        } else {
            Image(systemName: "person.fill")
                .font(.system(size: 7, weight: .bold))
                .foregroundStyle(.tint)
        }
    }

    private var help: String {
        switch player.repeatMode {
        case .off: "Repeat: off"
        case .song: "Repeat this song"
        case .album: "Repeat this album"
        case .artist: "Repeat all songs by this artist"
        }
    }

    var body: some View {
        IconButton(symbol: player.repeatMode == .song ? "repeat.1" : "repeat", active: player.repeatMode != .off) {
            player.repeatMode = player.repeatMode.next
        }
        .overlay(alignment: .bottomTrailing) {
            if player.repeatMode == .album || player.repeatMode == .artist {
                badge
                    .padding(1.5)
                    .background(Circle().fill(.bar))
                    .offset(x: 5, y: 4)
                    .allowsHitTesting(false)
            }
        }
        .help(help)
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
        case scanning, tagging, renaming, bandcamp

        var color: Color {
            switch self {
            case .scanning: .blue
            case .tagging: .purple
            case .renaming: .orange
            case .bandcamp: .teal
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

/// Bandcamp's mark, for songs bought there. Click to open the artist's Bandcamp page.
struct BandcampMark: View {
    let page: URL

    var body: some View {
        Button { NSWorkspace.shared.open(page) } label: {
            Slant().fill(Color(red: 0.11, green: 0.63, blue: 0.76)).frame(width: 12, height: 7)
        }
        .buttonStyle(.plain)
        .help("From Bandcamp. Click to open \(page.host() ?? page.absoluteString)")
    }

    /// The slanted bar of Bandcamp's logo.
    private struct Slant: Shape {
        func path(in r: CGRect) -> Path {
            Path { p in
                p.move(to: CGPoint(x: r.minX, y: r.maxY))
                p.addLine(to: CGPoint(x: r.minX + r.width * 0.3, y: r.minY))
                p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
                p.addLine(to: CGPoint(x: r.maxX - r.width * 0.3, y: r.maxY))
                p.closeSubpath()
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
