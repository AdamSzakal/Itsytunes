import SwiftUI

/// How the library is shown: one flat table, or songs grouped under their album or artist.
enum LibraryLayout: String, CaseIterable {
    case songs, albums, artists
}

/// Which songs to show, by where they come from.
enum SongSource: String, CaseIterable, Identifiable {
    case all, bandcamp, downloaded, onlineOnly

    var id: Self { self }

    var label: String {
        switch self {
        case .all: "All Songs"
        case .bandcamp: "From Bandcamp"
        case .downloaded: "Downloaded"
        case .onlineOnly: "Online Only"
        }
    }

    /// `onlineOnly`: paths of files that are only in Dropbox or iCloud, not on this Mac.
    func includes(_ song: Song, onlineOnly: Set<String>) -> Bool {
        switch self {
        case .all: true
        case .bandcamp: song.bandcampLink != nil
        case .downloaded: !onlineOnly.contains(song.path)
        case .onlineOnly: onlineOnly.contains(song.path)
        }
    }
}

/// All songs grouped by album: cover and album details on the left, a compact track list on the right.
struct AlbumListView: View {
    @Environment(Library.self) private var library
    let songs: [Song]
    /// Song whose album to scroll to; cleared once done.
    @Binding var scrollTarget: Song.ID?
    let showArtwork: (Song) -> Void
    /// Songs to review, and whether to look them up online (else only clean up titles).
    let fixTags: ([Song], _ online: Bool) -> Void

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
    private var albums: [Album] { Self.albums(of: songs, root: library.folder?.path) }

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
        ScrollViewReader { scroller in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(albums) { album in
                        AlbumSection(album: album, queue: queue, showArtwork: showArtwork, fixTags: fixTags)
                        Divider().padding(.leading, 20)
                    }
                }
                .padding(.vertical, 4)
            }
            .task(id: scrollTarget) {
                guard let target = scrollTarget else { return }
                // Wait for the list to lay out the new songs: scrolling in the same update does nothing.
                try? await Task.sleep(for: .milliseconds(150))
                if let album = albums.first(where: { $0.tracks.contains { $0.id == target } }) {
                    scroller.scrollTo(album.id, anchor: .top)
                }
                scrollTarget = nil
            }
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
                    TrackRow(song: song, number: index + 1, showArtist: album.isCompilation, playing: player.current?.id == song.id) { player.play(song, queue: queue) }
                        .contextMenu { TrackMenu(song: song, album: album.tracks, queue: queue, fixTags: fixTags) }
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }
}

/// Right-click menu of a song in the album and artist lists.
struct TrackMenu: View {
    let song: Song
    let album: [Song]
    let queue: [Song]
    let fixTags: ([Song], _ online: Bool) -> Void
    @Environment(Player.self) private var player

    var body: some View {
        Button("Play") { player.play(song, queue: queue) }
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([song.url]) }
        Divider()
        Button("Fix Tags…") { fixTags([song], true) }
        Button("Fix Tags of Album…") { fixTags(album, true) }
        Button("Clean Up Titles of Album…") { fixTags(album, false) }
    }
}

struct TrackRow: View {
    let song: Song
    let number: Int
    let showArtist: Bool
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
        .background(.quaternary.opacity(hovering ? 0.6 : 0), in: RoundedRectangle(cornerRadius: 4))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2, perform: play)
    }
}
