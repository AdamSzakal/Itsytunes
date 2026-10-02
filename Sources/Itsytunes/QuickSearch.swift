import SwiftUI

/// An artist, album or song found by the quick search.
enum QuickSearchResult: Identifiable {
    case artist(ArtistListView.Artist)
    case album(AlbumListView.Album)
    case song(Song)

    var id: String {
        switch self {
        case .artist(let artist): artist.id // starts with "artist:"
        case .album(let album): "album:" + album.id
        case .song(let song): song.id // a path
        }
    }

    /// The songs to select and scroll to.
    var songs: [Song] {
        switch self {
        case .artist(let artist): artist.albums.flatMap(\.tracks)
        case .album(let album): album.tracks
        case .song(let song): [song]
        }
    }

    fileprivate var title: String {
        switch self {
        case .artist(let artist): artist.name
        case .album(let album): album.name
        case .song(let song): song.displayTitle
        }
    }

    fileprivate var details: String {
        switch self {
        case .artist(let artist):
            let count = artist.albums.count
            return "\(count) \(count == 1 ? "album" : "albums")"
        case .album(let album): return [album.artist, album.year].filter { !$0.isEmpty }.joined(separator: " · ")
        case .song(let song): return [song.artist, song.album].filter { !$0.isEmpty }.joined(separator: " · ")
        }
    }

    fileprivate var kind: String {
        switch self {
        case .artist: "Artist"
        case .album: "Album"
        case .song: "Song"
        }
    }
}

/// ⌘K: a field over the window that finds an artist, album or song, and goes to it in the list.
/// ↓/↑ choose a result, Return goes to it, Esc or a click outside closes.
struct QuickSearch: View {
    let songs: [Song]
    /// The library folder (see `AlbumListView.albums`).
    let root: String?
    let onSelect: (QuickSearchResult) -> Void
    let onClose: () -> Void
    @State private var query = ""
    @State private var highlighted = 0
    @State private var keyMonitor: Any?
    /// Grouped once when the search opens, not on every key.
    @State private var artists: [ArtistListView.Artist] = []
    @State private var albums: [AlbumListView.Album] = []

    private static let rowHeight: CGFloat = 36

    private var results: [QuickSearchResult] {
        let words = query.split(separator: " ").map(String.init)
        guard !words.isEmpty else { return [] }
        return Self.best(artists, words, limit: 4) { $0.name }.map(QuickSearchResult.artist)
            + Self.best(albums, words, limit: 6) { "\($0.name) \($0.artist)" }.map(QuickSearchResult.album)
            + Self.best(songs, words, limit: 12) { "\($0.displayTitle) \($0.artist)" }.map(QuickSearchResult.song)
    }

    /// Items whose text has every word, those starting with the first word first.
    private static func best<T>(_ items: [T], _ words: [String], limit: Int, text: (T) -> String) -> [T] {
        var starts: [T] = []
        var others: [T] = []
        for item in items where starts.count < limit {
            let text = text(item)
            guard words.allSatisfy({ text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }) else { continue }
            if text.range(of: words[0], options: [.caseInsensitive, .diacriticInsensitive, .anchored]) != nil {
                starts.append(item)
            } else if others.count < limit {
                others.append(item)
            }
        }
        return Array((starts + others).prefix(limit))
    }

    var body: some View {
        let results = results
        ZStack(alignment: .top) {
            Color.black.opacity(0.2)
                .contentShape(Rectangle())
                .onTapGesture(perform: onClose)
            VStack(spacing: 0) {
                SearchField(prompt: "Go to an artist, album or song", text: $query) {}
                    .padding(10)
                if !results.isEmpty {
                    Divider()
                    ScrollViewReader { scroller in
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(Array(results.enumerated()), id: \.element.id) { index, result in
                                    QuickSearchRow(result: result, highlighted: index == highlighted) { onSelect(result) }
                                        .frame(height: Self.rowHeight)
                                        .id(result.id)
                                }
                            }
                            .padding(6)
                        }
                        // As tall as the results, up to ten rows.
                        .frame(height: CGFloat(min(results.count, 10)) * Self.rowHeight + 12)
                        .onChange(of: highlighted) {
                            if results.indices.contains(highlighted) { scroller.scrollTo(results[highlighted].id) }
                        }
                    }
                }
            }
            .frame(width: 540)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator))
            .shadow(color: .black.opacity(0.25), radius: 20, y: 8)
            .padding(.top, 50)
        }
        .onChange(of: query) { highlighted = 0 }
        .onAppear {
            artists = ArtistListView.artists(of: songs, root: root)
            albums = AlbumListView.albums(of: songs, root: root)
            // A local monitor sees the keys before the search field does, which would use ↑/↓ to move its cursor.
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: handleKey)
        }
        .onDisappear { keyMonitor.map(NSEvent.removeMonitor) }
    }

    /// Returns nil for a handled key, so no other view gets it.
    private func handleKey(_ event: NSEvent) -> NSEvent? {
        let results = results
        switch event.keyCode {
        case 53: // escape
            onClose()
        case 125 where !results.isEmpty: // down
            highlighted = min(highlighted + 1, results.count - 1)
        case 126 where !results.isEmpty: // up
            highlighted = max(highlighted - 1, 0)
        case 36, 76: // return, keypad enter
            guard !results.isEmpty else { return event }
            onSelect(results[min(highlighted, results.count - 1)])
        default:
            return event
        }
        return nil
    }
}

private struct QuickSearchRow: View {
    let result: QuickSearchResult
    let highlighted: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                switch result {
                case .artist:
                    Image(systemName: "music.mic")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(width: 26, height: 26)
                        .background(.quaternary, in: Circle())
                case .album(let album):
                    ArtworkView(key: album.tracks.first { $0.artworkKey != nil }?.artworkKey, size: 26)
                case .song(let song):
                    ArtworkView(key: song.artworkKey, size: 26)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(result.title).font(.system(size: 12.5, weight: .medium))
                    Text(result.details).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .lineLimit(1)
                Spacer(minLength: 8)
                Text(result.kind).font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 8)
            .frame(maxHeight: .infinity)
            .background(highlighted ? AnyShapeStyle(Color.accentColor.opacity(0.25)) : AnyShapeStyle(.quaternary.opacity(hovering ? 0.8 : 0)),
                        in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
