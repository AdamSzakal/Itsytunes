import SwiftUI

/// How the library is shown: one flat table, or songs grouped under their album.
enum LibraryLayout: String, CaseIterable {
    case songs, albums
}

/// All songs grouped by album: cover and album details on the left, a compact track list on the right.
struct AlbumListView: View {
    let songs: [Song]
    let showArtwork: (Song) -> Void
    /// Songs to review, and whether to look them up online (else only clean up titles).
    let fixTags: ([Song], _ online: Bool) -> Void

    struct Album: Identifiable {
        let id: String
        let name: String
        let artist: String
        let year: String
        let tracks: [Song]
    }

    /// Groups by album and artist (so two "Greatest Hits" stay apart), sorted by artist, then album.
    private var albums: [Album] {
        let groups = Dictionary(grouping: songs) { "\($0.artist.lowercased())|\($0.album.lowercased())" }
        return groups.map { id, tracks in
            // Sort keys worked out once per song, not in every comparison.
            let sorted = tracks.map { (song: $0, key: ($0.trackSort, $0.displayTitle)) }
                .sorted { $0.key < $1.key }
                .map(\.song)
            let first = sorted[0]
            return Album(id: id, name: first.album.isEmpty ? "Unknown Album" : first.album,
                         artist: first.artist.isEmpty ? "Unknown Artist" : first.artist,
                         year: sorted.lazy.map(\.year).first { !$0.isEmpty } ?? "", tracks: sorted)
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
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(albums) { album in
                    AlbumSection(album: album, queue: queue, showArtwork: showArtwork, fixTags: fixTags)
                    Divider().padding(.leading, 20)
                }
            }
            .padding(.vertical, 4)
        }
    }
}

private struct AlbumSection: View {
    let album: AlbumListView.Album
    let queue: [Song]
    let showArtwork: (Song) -> Void
    let fixTags: ([Song], _ online: Bool) -> Void
    @Environment(Player.self) private var player

    private var cover: Song? { album.tracks.first { $0.artworkKey != nil } }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            ArtworkView(key: cover?.artworkKey, size: 88)
                .onTapGesture { if let cover { showArtwork(cover) } }
            VStack(alignment: .leading, spacing: 0) {
                Text(album.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text([album.artist, album.year].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.bottom, 6)
                // Numbered by position: track tags are often missing, or skip songs that are not in the library.
                ForEach(Array(album.tracks.enumerated()), id: \.element.id) { index, song in
                    TrackRow(song: song, number: index + 1, playing: player.current?.id == song.id) { player.play(song, queue: queue) }
                        .contextMenu {
                            Button("Play") { player.play(song, queue: queue) }
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([song.url]) }
                            Divider()
                            Button("Fix Tags…") { fixTags([song], true) }
                            Button("Fix Tags of Album…") { fixTags(album.tracks, true) }
                            Button("Clean Up Titles of Album…") { fixTags(album.tracks, false) }
                        }
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }
}

private struct TrackRow: View {
    let song: Song
    let number: Int
    let playing: Bool
    let play: () -> Void
    @State private var hovering = false

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
            Spacer(minLength: 12)
            Text(formatTime(song.duration)).foregroundStyle(.secondary)
        }
        .font(.system(size: 11))
        .monospacedDigit()
        .padding(.horizontal, 6)
        .frame(height: 22)
        .background(.quaternary.opacity(hovering ? 0.6 : 0), in: RoundedRectangle(cornerRadius: 4))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2, perform: play)
    }
}
