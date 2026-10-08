import SwiftUI

/// Which songs to show, by where they come from.
enum SongSource: String, CaseIterable, Identifiable, Codable {
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

/// The songs the filter bar lets through. Artist and album names compare without case.
struct SongFilter: Equatable, Codable {
    var source = SongSource.all
    var artist: String?
    var album: String?

    var isActive: Bool { self != SongFilter() }

    func includes(_ song: Song, onlineOnly: Set<String>) -> Bool {
        source.includes(song, onlineOnly: onlineOnly) && Self.same(song.artist, artist) && Self.same(song.album, album)
    }

    /// True when no name is chosen, or the value is that name.
    static func same(_ value: String, _ name: String?) -> Bool {
        name.map { value.caseInsensitiveCompare($0) == .orderedSame } ?? true
    }
}

/// Dropdowns under the toolbar: where songs come from, artist, and album. The album list only has
/// albums of the chosen artist, so the two narrow down together.
struct FilterBar: View {
    @Binding var filter: SongFilter
    let songs: [Song]
    let onlineOnly: Set<String>

    var body: some View {
        let inSource = songs.filter { filter.source.includes($0, onlineOnly: onlineOnly) }
        let artists = Self.names(inSource.map(\.artist))
        let albums = Self.names(inSource.filter { SongFilter.same($0.artist, filter.artist) }.map(\.album))
        HStack(spacing: 16) {
            Picker("Source", selection: $filter.source) {
                ForEach(SongSource.allCases) { Text($0.label).tag($0) }
            }
            .frame(maxWidth: 200)
            Picker("Artist", selection: $filter.artist) {
                Text("All Artists").tag(String?.none)
                Divider()
                ForEach(artists, id: \.self) { Text($0).tag(String?.some($0)) }
            }
            .frame(maxWidth: 260)
            Picker("Album", selection: $filter.album) {
                Text("All Albums").tag(String?.none)
                Divider()
                ForEach(albums, id: \.self) { Text($0).tag(String?.some($0)) }
            }
            .frame(maxWidth: 300)
            Spacer(minLength: 0)
            if filter.isActive {
                Button("Clear") { filter = SongFilter() }
            }
        }
        .pickerStyle(.menu)
        .controlSize(.small)
        .font(.system(size: 11))
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .background(.bar)
        // A new source can leave the chosen artist without songs, and a new artist the chosen album:
        // then show all of them.
        .onChange(of: artists) {
            if let artist = filter.artist, !artists.contains(where: { $0.caseInsensitiveCompare(artist) == .orderedSame }) {
                filter.artist = nil
            }
        }
        .onChange(of: albums) {
            if let album = filter.album, !albums.contains(where: { $0.caseInsensitiveCompare(album) == .orderedSame }) {
                filter.album = nil
            }
        }
    }

    /// Names as first spelled, without repeats that differ only in case, sorted.
    private static func names(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}
