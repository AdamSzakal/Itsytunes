import SwiftUI

/// All songs grouped by artist, then by album. Songs on a compilation are listed under their own artist.
struct ArtistListView: View {
    @Environment(Library.self) private var library
    let songs: [Song]
    /// Song whose artist to scroll to; cleared once done.
    @Binding var scrollTarget: Song.ID?
    let showArtwork: (Song) -> Void
    /// Songs to review, and whether to look them up online (else only clean up titles).
    let fixTags: ([Song], _ online: Bool) -> Void

    struct Artist: Identifiable {
        let id: String
        let name: String
        /// Oldest first, as a discography reads.
        let albums: [AlbumListView.Album]
    }

    private var artists: [Artist] {
        let root = library.folder?.path
        return Dictionary(grouping: songs) { $0.artist.lowercased() }
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
        ScrollViewReader { scroller in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(artists) { artist in
                        ArtistSection(artist: artist, queue: queue, showArtwork: showArtwork, fixTags: fixTags)
                        Divider().padding(.leading, 20)
                    }
                }
                .padding(.vertical, 4)
            }
            .task(id: scrollTarget) {
                guard let target = scrollTarget else { return }
                // Wait for the list to lay out the new songs: scrolling in the same update does nothing.
                try? await Task.sleep(for: .milliseconds(150))
                if let artist = artists.first(where: { $0.albums.contains { $0.tracks.contains { $0.id == target } } }) {
                    scroller.scrollTo(artist.id, anchor: .top)
                }
                scrollTarget = nil
            }
        }
    }
}

private struct ArtistSection: View {
    let artist: ArtistListView.Artist
    let queue: [Song]
    let showArtwork: (Song) -> Void
    let fixTags: ([Song], _ online: Bool) -> Void
    @Environment(Player.self) private var player

    private var summary: String {
        let songs = artist.albums.reduce(0) { $0 + $1.tracks.count }
        let albums = artist.albums.count
        return "\(albums) \(albums == 1 ? "album" : "albums") · \(songs) \(songs == 1 ? "song" : "songs")"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(artist.name).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                Text(summary).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            ForEach(artist.albums) { album in
                HStack(alignment: .top, spacing: 12) {
                    let cover = album.tracks.first { $0.artworkKey != nil }
                    ArtworkView(key: cover?.artworkKey, size: 44)
                        .onTapGesture { if let cover { showArtwork(cover) } }
                    VStack(alignment: .leading, spacing: 0) {
                        Text([album.name, album.year].filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .padding(.bottom, 4)
                        ForEach(Array(album.tracks.enumerated()), id: \.element.id) { index, song in
                            TrackRow(song: song, number: index + 1, showArtist: false, playing: player.current?.id == song.id) {
                                player.play(song, queue: queue)
                            }
                            .contextMenu { TrackMenu(song: song, album: album.tracks, queue: queue, fixTags: fixTags) }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }
}
