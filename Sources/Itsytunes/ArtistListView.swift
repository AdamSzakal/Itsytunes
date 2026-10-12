import SwiftUI

/// All songs grouped by artist, then by album. Songs on a compilation are listed under their own artist.
struct ArtistListView: View {
    @Environment(Library.self) private var library
    @Environment(Player.self) private var player
    let songs: [Song]
    /// Selected songs, shared with the song table, or the selected artist or album. The arrow keys move it.
    @Binding var selection: Set<Song.ID>
    /// Song, album or artist to scroll to; cleared once done.
    @Binding var scrollTarget: ScrollTarget?
    /// IDs of artists shown without their albums.
    @Binding var collapsed: Set<String>
    let showArtwork: (Song) -> Void
    /// Opens the tag editor, or the review of online fixes or title clean-ups, for some songs.
    let tagAction: ([Song], TagAction) -> Void

    struct Artist: Identifiable {
        let id: String
        let name: String
        /// Oldest first, as a discography reads.
        let albums: [AlbumListView.Album]
    }

    private var artists: [Artist] { grouping(songs, root: library.folder?.path, group: Self.artists) }
    @State private var grouping = GroupingMemo<[Artist]>()
    /// The pointer is on a song, album or artist outside the repeat boxes, so the others do not fade.
    @State private var pointerOutsideRepeat = false
    /// The songs outside the repeat boxes are faded: `RepeatBox.fades`, a moment late.
    @State private var repeatFaded = false

    /// ID of an album header in the artist list. Album IDs alone can repeat: a compilation is listed under each of its artists.
    static func albumID(_ album: AlbumListView.Album, of artist: Artist) -> String { "\(artist.id)|\(album.id)" }

    /// `root`: the library folder (see `AlbumListView.albums`).
    static func artists(of songs: [Song], root: String?) -> [Artist] {
        // "artist:" keeps the IDs apart from album IDs, which share the set of collapsed groups.
        Dictionary(grouping: songs) { "artist:" + $0.artist.lowercased() }
            .map { id, songs in
                let albums = AlbumListView.albums(of: songs, root: root).sorted { a, b in
                    a.year != b.year ? a.year < b.year : a.name.localizedStandardCompare(b.name) == .orderedAscending
                }
                return Artist(id: id, name: songs[0].artist.isEmpty ? "Unknown Artist" : songs[0].artist, albums: albums)
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        let artists = artists
        // Playback continues from one artist into the next, in the order shown.
        let queue = artists.flatMap { $0.albums.flatMap(\.tracks) }
        let rows = artists.flatMap { artist in
            [ListRow(id: artist.id, first: artist.albums[0].tracks[0], group: artist.id)]
                + (collapsed.contains(artist.id) ? [] : artist.albums.flatMap { album in
                    [ListRow(id: Self.albumID(album, of: artist), first: album.tracks[0], group: artist.id)]
                        + album.tracks.map { ListRow(song: $0, group: artist.id) }
                })
        }
        // One highlighted row, even when the song table left several songs selected.
        let selected = rows.first { selection.contains($0.id) }?.id
        // Artist mode: one repeat box around the artist. Album mode: one around the album. Otherwise around the rows.
        let repeats = { (album: AlbumListView.Album) in album.tracks.allSatisfy(player.isRepeated) }
        let boxedArtists = Set(player.repeatMode != .artist ? [] : artists.filter { $0.albums.allSatisfy(repeats) }.map(\.id))
        let boxedAlbums = Set(player.repeatMode != .album ? [] : artists.flatMap { artist in
            artist.albums.filter(repeats).map { Self.albumID($0, of: artist) }
        })
        let inside = Set(rows.filter { row in
            boxedArtists.contains(row.group) || boxedAlbums.contains(row.id) || row.id == row.first.id && player.isRepeated(row.first)
        }.map(\.id))
        let hiddenDividers = RepeatBox.hiddenDividers(artists.map(\.id), boxed: boxedArtists)
        let fades = RepeatBox.fades(inside: inside, selected: selected, pointerOutside: pointerOutsideRepeat)
        ScrollViewReader { scroller in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(artists) { artist in
                        ArtistSection(artist: artist, queue: queue, collapsed: collapsed.contains(artist.id),
                                      boxed: boxedArtists.contains(artist.id), boxedAlbums: boxedAlbums,
                                      faded: repeatFaded, pointerOutsideRepeat: $pointerOutsideRepeat,
                                      selected: selected, select: { selection = [$0] },
                                      showArtwork: showArtwork, tagAction: tagAction) { all in
                            collapsed.toggle(artist.id, all: all ? artists.map(\.id) : nil)
                        }
                        Divider().padding(.leading, 20).opacity(hiddenDividers.contains(artist.id) ? 0 : 1)
                    }
                }
                .padding(.vertical, 4)
            }
            .onHover { if !$0 { pointerOutsideRepeat = false } }
            .repeatFadeTiming(fades, faded: $repeatFaded)
            .listKeyNavigation(rows, selection: $selection, collapsed: $collapsed, scroller: scroller) { player.play($0, queue: queue) }
            .task(id: scrollTarget) {
                guard let target = scrollTarget else { return }
                let artist = artists.first { artist in
                    artist.id == target.id || artist.albums.contains {
                        Self.albumID($0, of: artist) == target.id || $0.tracks.contains { $0.id == target.id }
                    }
                }
                if let artist { await target.scroll(in: artist.id, collapsed: $collapsed, scroller: scroller) }
                scrollTarget = nil
            }
        }
    }
}

private struct ArtistSection: View {
    let artist: ArtistListView.Artist
    let queue: [Song]
    let collapsed: Bool
    /// In a repeat box (artist mode).
    let boxed: Bool
    /// IDs of the albums in a repeat box (album mode), as `ArtistListView.albumID` makes them.
    let boxedAlbums: Set<String>
    /// The songs, albums and artists outside the repeat boxes are faded.
    let faded: Bool
    @Binding var pointerOutsideRepeat: Bool
    /// ID of the highlighted row in the list.
    let selected: String?
    let select: (String) -> Void
    let showArtwork: (Song) -> Void
    let tagAction: ([Song], TagAction) -> Void
    /// `all`: Option-click, for every artist.
    let toggle: (_ all: Bool) -> Void
    @Environment(Player.self) private var player

    private var summary: String {
        let songs = artist.albums.reduce(0) { $0 + $1.tracks.count }
        let albums = artist.albums.count
        return "\(albums) \(albums == 1 ? "album" : "albums") · \(songs) \(songs == 1 ? "song" : "songs")"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                CollapseTitle(text: artist.name, font: .system(size: 15, weight: .semibold), collapsed: collapsed, toggle: toggle)
                Text(summary).font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .selectableHeader(selected: selected == artist.id) { select(artist.id) }
            .repeatFade(inside: boxed, faded: faded, pointerOutside: $pointerOutsideRepeat)
            ForEach(collapsed ? [] : artist.albums) { album in
                let albumID = ArtistListView.albumID(album, of: artist)
                let albumInside = boxed || boxedAlbums.contains(albumID)
                let repeated = album.tracks.map(player.isRepeated)
                let rowBoxes = RepeatBox.rows(albumInside ? [] : repeated)
                HStack(alignment: .top, spacing: 12) {
                    let cover = album.tracks.first { $0.artworkKey != nil }
                    ArtworkView(key: cover?.artworkKey, size: 44)
                        .onTapGesture { if let cover { showArtwork(cover) } }
                        .repeatFade(inside: albumInside, faded: faded, pointerOutside: $pointerOutsideRepeat)
                    VStack(alignment: .leading, spacing: 0) {
                        Text([album.name, album.year].filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .selectableHeader(selected: selected == albumID) { select(albumID) }
                            .repeatFade(inside: albumInside, faded: faded, pointerOutside: $pointerOutsideRepeat)
                            .id(albumID)
                            .padding(.bottom, 4)
                        ForEach(Array(album.tracks.enumerated()), id: \.element.id) { index, song in
                            TrackRow(song: song, number: index + 1, showArtist: false, playing: player.current?.id == song.id,
                                     chip: rowBoxes.isEmpty || rowBoxes[index]?.top != true ? nil : player.repeatMode, selected: selected == song.id, select: { select(song.id) }) {
                                player.play(song, queue: queue)
                            }
                            .contextMenu { TrackMenu(song: song, album: album.tracks, queue: queue, tagAction: tagAction) }
                            .repeatBox(rowBoxes.isEmpty ? nil : rowBoxes[index])
                            .repeatFade(inside: albumInside || repeated[index], faded: faded, pointerOutside: $pointerOutsideRepeat)
                        }
                    }
                }
                .repeatBox(!boxed && albumInside ? RepeatBox() : nil, outset: CGSize(width: 6, height: 5), chip: player.repeatMode)
            }
        }
        // Collapsed, nothing else fills the width, and the list would center the section.
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.vertical, collapsed ? 10 : 14)
        .repeatBox(boxed ? RepeatBox() : nil, outset: CGSize(width: -10, height: -5), chip: player.repeatMode)
    }
}
