import SwiftUI

/// All playlists, each with its cover, name and songs, as the album list shows albums. Drag songs to change their
/// order, or onto another playlist to add them there. Delete removes the selected songs from their playlist.
struct PlaylistListView: View {
    @Environment(Library.self) private var library
    @Environment(Player.self) private var player
    @Environment(PlaylistStore.self) private var store
    @Environment(\.playlistSheet) private var playlistSheet
    /// The songs that the search and filters let through.
    let songs: [Song]
    /// Selected rows (see `Section.rowID`) or playlists. The arrow keys move it.
    @Binding var selection: Set<Song.ID>
    /// Row or playlist to scroll to; cleared once done.
    @Binding var scrollTarget: ScrollTarget?
    /// IDs of playlists shown without their songs.
    @Binding var collapsed: Set<String>
    let showArtwork: (Song) -> Void
    /// Opens the tag editor, or the review of online fixes, for some songs.
    let tagAction: ([Song], TagAction) -> Void
    /// The row a ⇧-click selects from.
    @State private var anchor: String?
    @State private var songIndex = GroupingMemo<SongIndex>()
    /// Where dragged songs would go.
    @State private var dropSpot: DropSpot?
    /// The pointer is on a song or playlist outside the repeat boxes, so the others do not fade.
    @State private var pointerOutsideRepeat = false
    /// The songs outside the repeat boxes are faded: `RepeatBox.fades`, a moment late.
    @State private var repeatFaded = false

    /// A playlist as listed: the songs of it that are in the library and that the search and filters let through.
    struct Section: Identifiable {
        let playlist: Playlist
        let tracks: [Track]
        var id: Playlist.ID { playlist.id }
        var songs: [Song] { tracks.map(\.song) }

        /// A song's row: a song can be in several playlists.
        func rowID(_ song: Song) -> String { Self.rowID(song.id, in: id) }

        static func rowID(_ song: Song.ID, in playlist: Playlist.ID) -> String { playlist + "\n" + song }
    }

    /// A song with the position of its entry in the playlist.
    struct Track {
        let entry: Int
        let song: Song
    }

    /// Before a row, or at the end of a playlist.
    enum DropSpot: Equatable {
        case before(String)
        case end(Playlist.ID)
    }

    /// The IDs of `songs`, the songs that the search and filters let through; nil when they let all through.
    static func shown(_ songs: [Song], in library: [Song]) -> Set<Song.ID>? {
        songs.count == library.count ? nil : Set(songs.map(\.id))
    }

    /// `shown`: see `shown(_:in:)`. While a search or filter is on, a playlist without any of its songs is left out.
    static func sections(_ playlists: [Playlist], index: SongIndex, shown: Set<Song.ID>?) -> [Section] {
        playlists.compactMap { playlist in
            // An entry of a moved file can find a song that the playlist has under its new path too.
            var seen = Set<Song.ID>()
            let tracks = playlist.entries.indices.compactMap { i -> Track? in
                guard let song = index.song(for: playlist.entries[i]), seen.insert(song.id).inserted,
                      shown?.contains(song.id) ?? true else { return nil }
                return Track(entry: i, song: song)
            }
            return shown != nil && tracks.isEmpty ? nil : Section(playlist: playlist, tracks: tracks)
        }
    }

    /// The songs of the selected rows, in list order, each once. A selected playlist stands for all its songs.
    static func songs(selected: Set<String>, in sections: [Section]) -> [Song] {
        var seen = Set<Song.ID>()
        return sections.flatMap { section in
            section.songs.filter { selected.contains(section.id) || selected.contains(section.rowID($0)) }
        }
        .filter { seen.insert($0.id).inserted }
    }

    var body: some View {
        let index = songIndex(library.songs, root: nil) { songs, _ in SongIndex(songs) }
        let sections = Self.sections(store.playlists, index: index, shown: Self.shown(songs, in: library.songs))
        if sections.isEmpty {
            if store.playlists.isEmpty {
                ContentUnavailableView {
                    Label("No Playlists", systemImage: "music.note.list")
                } description: {
                    Text("Select songs in any view, then right-click them and choose Add to Playlist.")
                } actions: {
                    Button("New Playlist") { playlistSheet(PlaylistNameRequest()) }
                }
            } else {
                ContentUnavailableView("No Songs", systemImage: "music.note.list",
                                       description: Text("No song in a playlist matches the search or filters."))
            }
        } else {
            list(sections)
        }
    }

    private func list(_ sections: [Section]) -> some View {
        // An empty playlist has no row: Return would have nothing to play.
        let rows = sections.flatMap { section in
            (section.tracks.first.map { [ListRow(id: section.id, first: $0.song, group: section.id)] } ?? [])
                + (collapsed.contains(section.id) ? [] : section.songs.map { ListRow(song: $0, group: section.id, id: section.rowID($0)) })
        }
        // The first selected row, for the repeat fade.
        let selected = rows.first { selection.contains($0.id) }?.id
        let selectedSongs = Self.songs(selected: selection, in: sections)
        // Playlist mode: one repeat box around the playlist that plays. Otherwise around the rows that repeat.
        let boxed = player.repeatMode == .playlist ? player.playlist : nil
        let inside = Set(rows.filter { row in
            row.group == boxed || row.isSong && player.repeatMode != .playlist && player.isRepeated(row.first)
        }.map(\.id))
        let hiddenDividers = RepeatBox.hiddenDividers(sections.map(\.id), boxed: Set([boxed].compactMap { $0 }))
        let fades = RepeatBox.fades(inside: inside, selected: selected, pointerOutside: pointerOutsideRepeat)
        return ScrollViewReader { scroller in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(sections) { section in
                        PlaylistSection(section: section, collapsed: collapsed.contains(section.id), boxed: boxed == section.id,
                                        faded: repeatFaded, pointerOutsideRepeat: $pointerOutsideRepeat,
                                        selection: selection, selectedSongs: selectedSongs, dropSpot: $dropSpot,
                                        select: { selection.select($0, in: rows, anchor: &anchor) },
                                        play: { play($0, in: section) },
                                        drop: { drop($0, before: $1, in: section, sections: sections) },
                                        showArtwork: showArtwork, tagAction: tagAction) { all in
                            collapsed.toggle(section.id, all: all ? sections.map(\.id) : nil)
                        }
                        Divider().padding(.leading, 20).opacity(hiddenDividers.contains(section.id) ? 0 : 1)
                    }
                }
                .padding(.vertical, 4)
            }
            .onHover { if !$0 { pointerOutsideRepeat = false } }
            .repeatFadeTiming(fades, faded: $repeatFaded)
            .listKeyNavigation(rows, selection: $selection, collapsed: $collapsed, scroller: scroller) { row in
                if let section = sections.first(where: { $0.id == row.group }) { play(row.first, in: section) }
            } delete: {
                removeSelected(in: sections)
            }
            .task(id: scrollTarget) {
                guard let target = scrollTarget else { return }
                if let section = sections.first(where: { target.id == $0.id || target.id.hasPrefix($0.id + "\n") }) {
                    await target.scroll(in: section.id, collapsed: $collapsed, scroller: scroller)
                }
                scrollTarget = nil
            }
        }
    }

    private func play(_ song: Song, in section: Section) {
        player.play(song, queue: section.songs, playlist: section.id)
    }

    /// The selected songs leave their playlists. Selected playlists stay: deleting one is in its right-click menu.
    private func removeSelected(in sections: [Section]) {
        for section in sections {
            let entries = section.tracks.filter { selection.contains(section.rowID($0.song)) }.map(\.entry)
            if !entries.isEmpty { store.remove(IndexSet(entries), from: section.id) }
        }
    }

    /// Rows dropped on a playlist, before the entry at `position` or at the end: the dragged row, or all selected rows
    /// of its playlist when it is one of them. They move within their playlist, and are added to another one.
    private func drop(_ ids: [String], before position: Int?, in target: Section, sections: [Section]) -> Bool {
        guard let id = ids.first,
              let source = sections.first(where: { id.hasPrefix($0.id + "\n") }) else { return false }
        let dragged = selection.contains(id) ? selection : [id]
        let tracks = source.tracks.filter { dragged.contains(source.rowID($0.song)) }
        if source.id == target.id {
            store.move(IndexSet(tracks.map(\.entry)), before: position, in: target.id)
        } else {
            store.add(tracks.map(\.song), to: target.id, before: position)
        }
        return true
    }
}

private struct PlaylistSection: View {
    let section: PlaylistListView.Section
    let collapsed: Bool
    /// In a repeat box: the playlist plays, and repeats.
    let boxed: Bool
    /// The songs and playlists outside the repeat boxes are faded.
    let faded: Bool
    @Binding var pointerOutsideRepeat: Bool
    /// IDs of the highlighted rows in the list.
    let selection: Set<Song.ID>
    /// The songs of the selected rows, for the right-click menu.
    let selectedSongs: [Song]
    @Binding var dropSpot: PlaylistListView.DropSpot?
    let select: (String) -> Void
    let play: (Song) -> Void
    /// Dropped rows, and the position of the entry they go before (nil: the end).
    let drop: ([String], Int?) -> Bool
    let showArtwork: (Song) -> Void
    let tagAction: ([Song], TagAction) -> Void
    /// `all`: Option-click, for every playlist.
    let toggle: (_ all: Bool) -> Void
    @Environment(Player.self) private var player
    @Environment(PlaylistStore.self) private var store
    @Environment(\.playlistSheet) private var playlistSheet

    var body: some View {
        let songs = section.songs
        // Playlist mode boxes the playlist that plays, not its songs in the other playlists.
        let repeated = songs.map { player.repeatMode != .playlist && player.isRepeated($0) }
        let rowBoxes = RepeatBox.rows(boxed ? [] : repeated)
        HStack(alignment: .top, spacing: 16) {
            PlaylistCover(songs: songs, size: collapsed ? 44 : 88)
                .onTapGesture { if let cover = songs.first(where: { $0.artworkKey != nil }) { showArtwork(cover) } }
                .repeatFade(inside: boxed, faded: faded, pointerOutside: $pointerOutsideRepeat)
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    CollapseTitle(text: section.playlist.name, font: .system(size: 13, weight: .semibold), collapsed: collapsed, toggle: toggle)
                    Text(!songs.isEmpty ? songsSummary(songs)
                         : section.playlist.entries.isEmpty ? "No songs yet. Right-click songs in any view to add them."
                         // Online-only files are not in the library unless Settings includes them.
                         : "None of its songs are in the library.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .padding(.leading, 14) // under the title, past the arrow
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .selectableHeader(selected: selection.contains(section.id)) { select(section.id) }
                // Folded or empty, the header itself shows that songs dropped on it go to the end.
                .background(dropSpot == .end(section.id) && (collapsed || songs.isEmpty) ? Color.accentColor.opacity(0.2) : .clear,
                            in: RoundedRectangle(cornerRadius: 4))
                .contextMenu { headerMenu(songs) }
                .dropDestination(for: String.self) { ids, _ in drop(ids, nil) } isTargeted: { target(.end(section.id), $0) }
                .repeatFade(inside: boxed, faded: faded, pointerOutside: $pointerOutsideRepeat)
                .padding(.bottom, collapsed ? 0 : 6)
                if !collapsed {
                    ForEach(Array(section.tracks.enumerated()), id: \.element.song.id) { index, track in
                        let rowID = section.rowID(track.song)
                        TrackRow(song: track.song, number: index + 1, showArtist: true, playing: player.current?.id == track.song.id,
                                 chip: rowBoxes.isEmpty || rowBoxes[index]?.top != true ? nil : player.repeatMode,
                                 selected: selection.contains(rowID), joined: selection.neighbors(of: index, in: songs, id: section.rowID),
                                 rowID: rowID, select: { select(rowID) }) { play(track.song) }
                            .contextMenu { trackMenu(track, rowID: rowID) }
                            .draggable(rowID)
                            .dropDestination(for: String.self) { ids, _ in drop(ids, track.entry) } isTargeted: { target(.before(rowID), $0) }
                            .overlay(alignment: .top) { if dropSpot == .before(rowID) { DropLine().offset(y: -1) } }
                            .repeatBox(rowBoxes.isEmpty ? nil : rowBoxes[index])
                            .repeatFade(inside: boxed || repeated[index], faded: faded, pointerOutside: $pointerOutsideRepeat)
                    }
                    // Below the last song: drops here go to the end.
                    Color.clear
                        .frame(height: 8)
                        .contentShape(Rectangle())
                        .overlay(alignment: .top) { if dropSpot == .end(section.id) && !songs.isEmpty { DropLine().offset(y: -1) } }
                        .dropDestination(for: String.self) { ids, _ in drop(ids, nil) } isTargeted: { target(.end(section.id), $0) }
                }
            }
        }
        // Collapsed, nothing else fills the width, and the list would center the section.
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.vertical, collapsed ? 10 : 14)
        .repeatBox(boxed ? RepeatBox() : nil, outset: CGSize(width: -10, height: -5), chip: player.repeatMode)
    }

    /// The drag is over `spot`, or has left it.
    private func target(_ spot: PlaylistListView.DropSpot, _ targeted: Bool) {
        if targeted {
            dropSpot = spot
        } else if dropSpot == spot {
            dropSpot = nil
        }
    }

    @ViewBuilder
    private func headerMenu(_ songs: [Song]) -> some View {
        Button("Play") { if let first = songs.first { play(first) } }.disabled(songs.isEmpty)
        Button("Rename…") { playlistSheet(PlaylistNameRequest(renaming: section.playlist)) }
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([section.playlist.url]) }
        Divider()
        Button("Move to Trash") { store.delete(section.id) }
    }

    /// On a selected song, it acts on all selected songs; removing, on those of this playlist.
    @ViewBuilder
    private func trackMenu(_ track: PlaylistListView.Track, rowID: String) -> some View {
        let isSelected = selection.contains(rowID)
        let items = isSelected ? selectedSongs : [track.song]
        let removing = isSelected ? section.tracks.filter { selection.contains(section.rowID($0.song)) }.map(\.entry) : [track.entry]
        Button("Play") { play(track.song) }
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(items.map(\.url)) }
        Divider()
        AddToPlaylistMenu(songs: items, excluding: section.id)
        Button(removing.count == 1 ? "Remove from Playlist" : "Remove \(removing.count) Songs from Playlist") {
            store.remove(IndexSet(removing), from: section.id)
        }
        Divider()
        Button(items.count == 1 ? "Edit Tags…" : "Edit Tags of \(items.count) Songs…") { tagAction(items, .edit) }
            .keyboardShortcut("i")
        Button(items.count == 1 ? "Fix Tags…" : "Fix Tags of \(items.count) Songs…") { tagAction(items, .fixOnline) }
    }
}

/// Where dragged songs go: a line in the accent color, as in a system list.
private struct DropLine: View {
    var body: some View {
        Capsule().fill(Color.accentColor).frame(height: 2).allowsHitTesting(false)
    }
}

/// The covers of the first four albums in a playlist, two by two, or the first cover when there are fewer.
struct PlaylistCover: View {
    let songs: [Song]
    let size: CGFloat

    private var covers: [String] {
        var keys: [String] = []
        for key in songs.lazy.compactMap(\.artworkKey) where !keys.contains(key) {
            keys.append(key)
            if keys.count == 4 { break }
        }
        return keys
    }

    var body: some View {
        let covers = covers
        if covers.count == 4 {
            Grid(horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow { tile(covers[0]); tile(covers[1]) }
                GridRow { tile(covers[2]); tile(covers[3]) }
            }
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size > 30 ? 6 : 3)) // as `ArtworkView`
        } else {
            ArtworkView(key: covers.first, size: size)
        }
    }

    private func tile(_ key: String) -> some View {
        Group {
            if let image = ArtworkStore.image(key) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Rectangle().fill(.quaternary)
            }
        }
        .frame(width: size / 2, height: size / 2)
        .clipped()
    }
}
