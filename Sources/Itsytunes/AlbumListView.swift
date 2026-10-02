import SwiftUI

/// How the library is shown: one flat table, or songs grouped under their album or artist.
enum LibraryLayout: String, CaseIterable {
    case songs, albums, artists
}

/// All songs grouped by album: cover and album details on the left, a compact track list on the right.
struct AlbumListView: View {
    @Environment(Library.self) private var library
    @Environment(Player.self) private var player
    let songs: [Song]
    /// Selected songs, shared with the song table, or the selected album. The arrow keys move it.
    @Binding var selection: Set<Song.ID>
    /// Song or album to scroll to; cleared once done.
    @Binding var scrollTarget: ScrollTarget?
    /// IDs of albums shown without their songs.
    @Binding var collapsed: Set<String>
    let showArtwork: (Song) -> Void
    /// Opens the tag editor, or the review of online fixes or title clean-ups, for some songs.
    let tagAction: ([Song], TagAction) -> Void

    struct Album: Identifiable {
        let id: String
        let name: String
        let artist: String
        let year: String
        let tracks: [Song]
        /// Songs by several artists: each row names its artist.
        let isCompilation: Bool
    }

    /// Songs with the same album name are one album when they share the artist (so two "Greatest Hits" stay
    /// apart, and discs in subfolders join) or the folder (so a compilation with many artists stays together).
    /// Loose songs in the library folder join only by artist. Sorted by artist, then album.
    private var albums: [Album] { grouping(songs, root: library.folder?.path, group: Self.albums) }
    @State private var grouping = GroupingMemo<[Album]>()

    /// `root`: the library folder, whose loose songs join only by artist.
    static func albums(of songs: [Song], root: String?) -> [Album] {
        var groupIndex: [String: Int] = [:] // "a:artist|album" and "f:folder|album" keys
        var groups: [(id: String, tracks: [Song])] = []
        for song in songs {
            let album = song.album.lowercased()
            let byArtist = "a:\(song.artist.lowercased())|\(album)"
            let folder = (song.path as NSString).deletingLastPathComponent
            let byFolder = album.isEmpty || folder == root ? nil : "f:\(folder)|\(album)"
            let index = groupIndex[byArtist] ?? byFolder.flatMap { groupIndex[$0] } ?? {
                groups.append((byFolder ?? byArtist, []))
                return groups.count - 1
            }()
            groups[index].tracks.append(song)
            groupIndex[byArtist] = index
            if let byFolder { groupIndex[byFolder] = index }
        }
        return groups.map { id, tracks in
            // Sort keys worked out once per song, not in every comparison.
            let sorted = tracks.map { (song: $0, key: ($0.trackSort, $0.displayTitle)) }
                .sorted { $0.key < $1.key }
                .map(\.song)
            let first = sorted[0]
            let isCompilation = Set(sorted.map { $0.artist.lowercased() }).count > 1
            let artist = isCompilation ? "Various Artists" : first.artist
            return Album(id: id, name: first.album.isEmpty ? "Unknown Album" : first.album,
                         artist: artist.isEmpty ? "Unknown Artist" : artist,
                         year: sorted.lazy.map(\.year).first { !$0.isEmpty } ?? "", tracks: sorted,
                         isCompilation: isCompilation)
        }
        .sorted { a, b in
            let byArtist = a.artist.localizedStandardCompare(b.artist)
            if byArtist != .orderedSame { return byArtist == .orderedAscending }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    var body: some View {
        let albums = albums
        // Playback continues from one album into the next, in the order shown.
        let queue = albums.flatMap(\.tracks)
        let rows = albums.flatMap { album in
            [ListRow(id: album.id, first: album.tracks[0], group: album.id)]
                + (collapsed.contains(album.id) ? [] : album.tracks.map { ListRow(song: $0, group: album.id) })
        }
        // One highlighted row, even when the song table left several songs selected.
        let selected = rows.first { selection.contains($0.id) }?.id
        ScrollViewReader { scroller in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(albums) { album in
                        AlbumSection(album: album, queue: queue, collapsed: collapsed.contains(album.id),
                                     selected: selected, select: { selection = [$0] },
                                     showArtwork: showArtwork, tagAction: tagAction) { all in
                            collapsed.toggle(album.id, all: all ? albums.map(\.id) : nil)
                        }
                        Divider().padding(.leading, 20)
                    }
                }
                .padding(.vertical, 4)
            }
            .listKeyNavigation(rows, selection: $selection, collapsed: $collapsed, scroller: scroller) { player.play($0, queue: queue) }
            .task(id: scrollTarget) {
                guard let target = scrollTarget else { return }
                if let album = albums.first(where: { $0.id == target.id || $0.tracks.contains { $0.id == target.id } }) {
                    await target.scroll(in: album.id, collapsed: $collapsed, scroller: scroller)
                }
                scrollTarget = nil
            }
        }
    }
}

private struct AlbumSection: View {
    let album: AlbumListView.Album
    let queue: [Song]
    let collapsed: Bool
    /// ID of the highlighted row in the list.
    let selected: String?
    let select: (String) -> Void
    let showArtwork: (Song) -> Void
    let tagAction: ([Song], TagAction) -> Void
    /// `all`: Option-click, for every album.
    let toggle: (_ all: Bool) -> Void
    @Environment(Player.self) private var player

    private var cover: Song? { album.tracks.first { $0.artworkKey != nil } }

    private var details: String {
        let count = collapsed ? "\(album.tracks.count) \(album.tracks.count == 1 ? "song" : "songs")" : ""
        return [album.artist, album.year, count].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            // Smaller when collapsed, so a folded list stays compact.
            ArtworkView(key: cover?.artworkKey, size: collapsed ? 44 : 88)
                .onTapGesture { if let cover { showArtwork(cover) } }
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    CollapseTitle(text: album.name, font: .system(size: 13, weight: .semibold), collapsed: collapsed, toggle: toggle)
                    Text(details)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .padding(.leading, 14) // under the title, past the arrow
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .selectableHeader(selected: selected == album.id) { select(album.id) }
                .padding(.bottom, collapsed ? 0 : 6)
                // Numbered by position: track tags are often missing, or skip songs that are not in the library.
                if !collapsed {
                    ForEach(Array(album.tracks.enumerated()), id: \.element.id) { index, song in
                        TrackRow(song: song, number: index + 1, showArtist: album.isCompilation, playing: player.current?.id == song.id,
                                 selected: selected == song.id, select: { select(song.id) }) { player.play(song, queue: queue) }
                            .contextMenu { TrackMenu(song: song, album: album.tracks, queue: queue, tagAction: tagAction) }
                    }
                }
            }
        }
        // Collapsed, nothing else fills the width, and the list would center the section.
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.vertical, collapsed ? 10 : 14)
    }
}

/// A group title with an arrow that folds its songs away. Option-click folds or unfolds all groups, as in Finder.
struct CollapseTitle: View {
    let text: String
    let font: Font
    let collapsed: Bool
    let toggle: (_ all: Bool) -> Void

    var body: some View {
        Button { toggle(NSEvent.modifierFlags.contains(.option)) } label: {
            HStack(spacing: 5) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(collapsed ? 0 : 90))
                    .frame(width: 9)
                Text(text).font(font).lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(collapsed ? "Show songs (Option-click: all)" : "Hide songs (Option-click: all)")
    }
}

extension Set<String> {
    /// Folds or unfolds one group; with `all`, every group in it the same way.
    mutating func toggle(_ id: String, all: [String]?) {
        let collapse = !contains(id)
        withAnimation(.easeOut(duration: 0.15)) {
            if let all {
                if collapse { formUnion(all) } else { subtract(all) }
            } else if collapse {
                insert(id)
            } else {
                remove(id)
            }
        }
    }
}

/// A row the arrow keys can select in the album and artist lists: a song, or an album or artist header.
struct ListRow {
    let id: String
    /// What Return plays: the song itself, or the first song of the album or artist.
    let first: Song
    /// The album in the album list, or the artist in the artist list, that the row is in (or is). ←/→ fold it.
    let group: String

    /// The album or artist header itself: ⇧↑/⇧↓ go from one to the next.
    var isGroup: Bool { id == group }

    init(id: String, first: Song, group: String) {
        self.id = id
        self.first = first
        self.group = group
    }

    init(song: Song, group: String) {
        self.init(id: song.id, first: song, group: group)
    }
}

/// A song, or an album or artist header, to scroll to in a list.
struct ScrollTarget: Equatable {
    let id: String
    /// Where the row ends up: an album or artist at the top, so its songs are below; a song in the middle.
    var anchor = UnitPoint.center

    /// Unfolds `group`, the album or artist the target is in (or is), and scrolls to the target.
    @MainActor
    func scroll(in group: String, collapsed: Binding<Set<String>>, scroller: ScrollViewProxy) async {
        collapsed.wrappedValue.remove(group)
        // Wait for the list to lay out the new songs: scrolling in the same update does nothing.
        try? await Task.sleep(for: .milliseconds(150))
        scroller.scrollTo(group, anchor: .top)
        // A row inside a group the list has not laid out yet cannot be found: go to the group first, then the row.
        if group != id {
            try? await Task.sleep(for: .milliseconds(50))
            scroller.scrollTo(id, anchor: anchor)
        }
    }
}

extension View {
    /// Arrow keys for the album and artist lists. ↑/↓ select the previous or next row, past the songs of folded
    /// groups. ⇧↑/⇧↓ select the previous or next album or artist (⇧↑ first the one the selection is in).
    /// →/← unfold or fold the album or artist the selection is in; with Option, all of them, as Option-click does.
    /// Return plays the selected song, or the selected album or artist from its first song.
    /// `rows`: the selectable rows in the order shown.
    func listKeyNavigation(_ rows: [ListRow], selection: Binding<Set<Song.ID>>, collapsed: Binding<Set<String>>,
                           scroller: ScrollViewProxy, play: @escaping (Song) -> Void) -> some View {
        modifier(ListKeyNavigation(rows: rows, selection: selection, collapsed: collapsed, scroller: scroller, play: play))
    }

    /// Highlights an album or artist header while it is selected. A click selects it.
    func selectableHeader(selected: Bool, select: @escaping () -> Void) -> some View {
        // The highlight reaches a little past the text, as a song row's does, without moving the text.
        padding(.horizontal, 6)
            .padding(.vertical, 2)
            .selectionHighlight(selected)
            .padding(.horizontal, -6)
            .padding(.vertical, -2)
            .contentShape(Rectangle())
            // Simultaneous, so the title's fold button still works.
            .simultaneousGesture(TapGesture().onEnded(select))
    }

    /// The one highlight in the album and artist lists: the selected row, in the accent color with white text,
    /// as in a system list.
    func selectionHighlight(_ selected: Bool) -> some View {
        background(selected ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 4))
            // Secondary and tertiary text inside become shades of white.
            .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
    }
}

private struct ListKeyNavigation: ViewModifier {
    let rows: [ListRow]
    @Binding var selection: Set<Song.ID>
    @Binding var collapsed: Set<String>
    let scroller: ScrollViewProxy
    let play: (Song) -> Void
    func body(content: Content) -> some View {
        content.background(KeyCatcher(focusOn: selection, onKey: handle))
    }

    /// Returns false for keys it leaves to other views.
    private func handle(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags
        guard !flags.contains(.command) else { return false } // ⌘← and ⌘→ are Previous and Next in the menu
        switch event.keyCode {
        case 125, 126: // down, up
            move(down: event.keyCode == 125, byGroup: flags.contains(.shift))
        case 123, 124: // left, right
            fold(event.keyCode == 123, all: flags.contains(.option))
        case 36, 76: // return, keypad enter
            // Not on repeat: holding Return would start the song over and over.
            guard !event.isARepeat, let row = rows.first(where: { selection.contains($0.id) }) else { return false }
            play(row.first)
        default:
            return false
        }
        return true
    }

    private func fold(_ fold: Bool, all: Bool) {
        guard let row = rows.first(where: { selection.contains($0.id) }) else { return }
        // Headers are rows even when folded, so they list every group.
        let groups = all ? rows.filter(\.isGroup).map(\.id) : [row.group]
        withAnimation(.easeOut(duration: 0.15)) {
            if fold { collapsed.formUnion(groups) } else { collapsed.subtract(groups) }
        }
        // A folded song is gone from the list: select its album or artist instead.
        if fold, !row.isGroup {
            selection = [row.group]
            scroller.scrollTo(row.group)
        }
    }

    private func move(down: Bool, byGroup: Bool) {
        // From the last selected row going down, the first one going up; from the edge when nothing is selected.
        let current = down ? rows.lastIndex { selection.contains($0.id) } : rows.firstIndex { selection.contains($0.id) }
        let next = down ? Array(rows.indices.dropFirst((current ?? -1) + 1)) : rows.indices.prefix(current ?? rows.count).reversed()
        guard let index = next.first(where: { !byGroup || rows[$0].isGroup }) else { return }
        selection = [rows[index].id]
        scroller.scrollTo(rows[index].id, anchor: byGroup ? .top : nil)
    }
}

/// Takes the keyboard focus for the album and artist lists and gets their key presses, with the repeats while a key
/// is held down: SwiftUI's `onKeyPress` on the scroll view did not repeat.
private struct KeyCatcher: NSViewRepresentable {
    /// Each change takes the focus: a click on a row, or a quick search result, selects it. A list that appears
    /// with a selection takes it too. Other changes, such as a search, leave the focus where it is.
    let focusOn: Set<String>
    let onKey: (NSEvent) -> Bool

    final class KeyView: NSView {
        var onKey: (NSEvent) -> Bool = { _ in false }
        var focusOn: Set<String> = []

        override var acceptsFirstResponder: Bool { true }

        override func keyDown(with event: NSEvent) {
            if !onKey(event) { super.keyDown(with: event) }
        }
    }

    func makeNSView(context: Context) -> KeyView { KeyView() }

    func updateNSView(_ view: KeyView, context: Context) {
        view.onKey = onKey // the latest rows and selection
        guard view.focusOn != focusOn else { return }
        view.focusOn = focusOn
        // After this update: the quick search field may still have the focus and give it up as it closes.
        if !focusOn.isEmpty { DispatchQueue.main.async { view.window?.makeFirstResponder(view) } }
    }
}

/// The last grouping of the songs into albums or artists. Without it, every key press and selection change
/// grouped the whole library again, which made a held arrow key slow.
final class GroupingMemo<Value> {
    private var last: (songs: [Song], root: String?, value: Value)?

    func callAsFunction(_ songs: [Song], root: String?, group: ([Song], String?) -> Value) -> Value {
        if let last, last.root == root, last.songs == songs { return last.value }
        let value = group(songs, root)
        last = (songs, root, value)
        return value
    }
}

/// Right-click menu of a song in the album and artist lists.
struct TrackMenu: View {
    let song: Song
    let album: [Song]
    let queue: [Song]
    let tagAction: ([Song], TagAction) -> Void
    @Environment(Player.self) private var player

    var body: some View {
        Button("Play") { player.play(song, queue: queue) }
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([song.url]) }
        Divider()
        Button("Edit Tags…") { tagAction([song], .edit) }
        Button("Edit Tags of Album…") { tagAction(album, .edit) }
        Divider()
        Button("Fix Tags…") { tagAction([song], .fixOnline) }
        Button("Fix Tags of Album…") { tagAction(album, .fixOnline) }
        Button("Clean Up Titles of Album…") { tagAction(album, .cleanUp) }
    }
}

struct TrackRow: View {
    let song: Song
    let number: Int
    let showArtist: Bool
    let playing: Bool
    let selected: Bool
    let select: () -> Void
    let play: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if playing {
                    Image(systemName: "speaker.wave.2.fill").font(.system(size: 9))
                } else {
                    Text("\(number)")
                }
            }
            .frame(width: 20, alignment: .trailing)
            .foregroundStyle(playing ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
            Text(song.displayTitle)
                .font(.system(size: 12))
                .fontWeight(playing ? .semibold : .regular)
                .lineLimit(1)
            if showArtist {
                Text(song.artist).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            }
            if let page = song.bandcampLink { BandcampMark(page: page) }
            Spacer(minLength: 12)
            Text(formatTime(song.duration)).foregroundStyle(.secondary)
        }
        .font(.system(size: 11))
        .monospacedDigit()
        .padding(.horizontal, 6)
        .frame(height: 22)
        .selectionHighlight(selected)
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: play)
        // Simultaneous, so a click selects at once and does not wait to see if it becomes a double-click.
        .simultaneousGesture(TapGesture().onEnded(select))
        .id(song.id) // so the arrow keys can scroll to the row
    }
}
