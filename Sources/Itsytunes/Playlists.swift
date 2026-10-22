import SwiftUI

/// A playlist: an .m3u8 file in the Playlists folder of the library, so it syncs with the songs (Dropbox, iCloud)
/// and other players can open it. Paths are relative to the file, so the library folder can move.
struct Playlist: Identifiable, Equatable {
    let url: URL
    /// The songs in order. An entry whose file is not in the library stays: the file may only be online, or not
    /// scanned yet, and writing the playlist must not drop it.
    var entries: [Entry]

    struct Entry: Equatable {
        /// Absolute.
        var path: String
        /// From the #EXTINF line: finds the song again after its file was renamed or moved.
        var artist = ""
        var title = ""
        var duration: Int?
    }

    /// "playlist:" keeps the IDs apart from songs, albums and artists, which share the selection and the folded groups.
    var id: String { "playlist:" + url.path }
    var name: String { url.deletingPathExtension().lastPathComponent }

    static let fileExtensions: Set = ["m3u8", "m3u"]

    init(url: URL, entries: [Entry]) {
        self.url = url
        self.entries = entries
    }

    /// Reads an .m3u8 or .m3u file, as other players write them too: absolute or relative paths, file URLs,
    /// or Windows paths.
    init?(contentsOf url: URL) {
        guard let data = try? Data(contentsOf: url),
              // Older .m3u files are often Latin-1, which always decodes.
              let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { return nil }
        let folder = url.deletingLastPathComponent()
        var entries: [Entry] = []
        var info: Entry?
        // A song twice would be two rows with one ID.
        var seen = Set<String>()
        for line in text.components(separatedBy: .newlines) {
            let line = line.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\u{FEFF}")))
            if line.hasPrefix("#EXTINF:") {
                info = Self.info(line)
            } else if !line.isEmpty, !line.hasPrefix("#") {
                var entry = info ?? Entry(path: "")
                entry.path = Self.path(line, relativeTo: folder)
                if seen.insert(entry.path).inserted { entries.append(entry) }
                info = nil
            }
        }
        self.init(url: url, entries: entries)
    }

    /// "#EXTINF:207,Artist - Title": length in seconds (-1 when unknown), then the name.
    private static func info(_ line: String) -> Entry {
        let rest = line.dropFirst("#EXTINF:".count)
        let comma = rest.firstIndex(of: ",") ?? rest.endIndex
        var entry = Entry(path: "")
        // Some players put attributes after the length: "#EXTINF:207 tvg-id="x",…".
        entry.duration = rest[..<comma].split(separator: " ").first.flatMap { Int($0) }.flatMap { $0 >= 0 ? $0 : nil }
        let name = comma < rest.endIndex ? String(rest[rest.index(after: comma)...]) : ""
        if let dash = name.range(of: " - ") {
            entry.artist = String(name[..<dash.lowerBound])
            entry.title = String(name[dash.upperBound...])
        } else {
            entry.title = name
        }
        return entry
    }

    private static func path(_ line: String, relativeTo folder: URL) -> String {
        if line.hasPrefix("file://"), let url = URL(string: line) { return url.standardizedFileURL.path }
        let line = line.replacingOccurrences(of: "\\", with: "/")
        let url = line.hasPrefix("/") ? URL(fileURLWithPath: line) : folder.appendingPathComponent(line)
        return url.standardizedFileURL.path
    }

    /// The file's text. Paths inside `root`, the library folder, are relative to the Playlists folder in it.
    func text(root: String) -> String {
        var lines = ["#EXTM3U"]
        for entry in entries {
            if !entry.title.isEmpty {
                lines.append("#EXTINF:\(entry.duration ?? -1),\(entry.artist.isEmpty ? "" : entry.artist + " - ")\(entry.title)")
            }
            lines.append(entry.path.hasPrefix(root + "/") ? "../" + entry.path.dropFirst(root.count + 1) : entry.path)
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

extension Playlist.Entry {
    init(_ song: Song) {
        self.init(path: song.path, artist: song.artist, title: song.displayTitle, duration: Int(song.duration.rounded()))
    }
}

/// The library's songs by path, and by artist and title for playlist entries whose file was renamed or moved.
struct SongIndex {
    private let byPath: [String: Song]
    private let byName: [String: [Song]]

    init(_ songs: [Song]) {
        byPath = Dictionary(songs.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        byName = Dictionary(grouping: songs) { Self.key($0.artist, $0.displayTitle) }
    }

    func song(for entry: Playlist.Entry) -> Song? {
        if let song = byPath[entry.path] { return song }
        guard !entry.title.isEmpty else { return nil }
        // The same song: as long as the playlist says, give or take a few seconds.
        return byName[Self.key(entry.artist, entry.title)]?.first { song in
            entry.duration.map { abs(Double($0) - song.duration) < 3 } ?? true
        }
    }

    private static func key(_ artist: String, _ title: String) -> String { "\(artist.lowercased())|\(title.lowercased())" }
}

/// The playlists of the library folder. The main window reloads them after each scan of the folder, so changes
/// made in other apps or on other Macs show. Each change is written to the playlist's file at once.
@MainActor @Observable
final class PlaylistStore {
    /// By name.
    private(set) var playlists: [Playlist] = []
    /// The library's songs, to bring the entries up to date when a playlist is written (set by the main window).
    @ObservationIgnored var library: () -> [Song] = { [] }
    @ObservationIgnored private var root: URL?

    private var directory: URL? { root?.appendingPathComponent("Playlists", isDirectory: true) }

    func load(_ root: URL?) {
        self.root = root
        guard let directory else { return playlists = [] }
        // By name in `directory`: the URLs that the listing gives can spell the folder another way ("/private/tmp"),
        // and then relative paths would not match the songs' paths.
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        let loaded = names.filter { !$0.hasPrefix(".") && Playlist.fileExtensions.contains(($0 as NSString).pathExtension.lowercased()) }
            .compactMap { Playlist(contentsOf: directory.appendingPathComponent($0)) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        // Most scans have other causes: the views only update when a playlist changed.
        if loaded != playlists { playlists = loaded }
    }

    /// Writes a new playlist with the songs, and returns its ID. Nil when there is no library folder or no file
    /// could be written.
    @discardableResult
    func create(named name: String, songs: [Song]) -> Playlist.ID? {
        guard let url = fileURL(for: name) else { return nil }
        var seen = Set<String>()
        let playlist = Playlist(url: url, entries: songs.filter { seen.insert($0.path).inserted }.map(Playlist.Entry.init))
        guard write(playlist) else { return nil }
        playlists.append(playlist)
        sort()
        return playlist.id
    }

    /// Adds the songs that the playlist does not have yet, before the entry at `position`, or at the end.
    func add(_ songs: [Song], to id: Playlist.ID, before position: Int? = nil) {
        update(id) { entries in
            let paths = Set(entries.map(\.path))
            entries.insert(contentsOf: songs.filter { !paths.contains($0.path) }.map(Playlist.Entry.init),
                           at: min(position ?? entries.count, entries.count))
        }
    }

    func remove(_ positions: IndexSet, from id: Playlist.ID) {
        update(id) { $0.remove(atOffsets: positions) }
    }

    /// Moves entries before the entry at `position`, or to the end.
    func move(_ positions: IndexSet, before position: Int?, in id: Playlist.ID) {
        update(id) { $0.move(fromOffsets: positions, toOffset: position ?? $0.count) }
    }

    func rename(_ id: Playlist.ID, to name: String) {
        guard let i = playlists.firstIndex(where: { $0.id == id }), let url = fileURL(for: name, renaming: playlists[i].url),
              url != playlists[i].url, (try? FileManager.default.moveItem(at: playlists[i].url, to: url)) != nil else { return }
        playlists[i] = Playlist(url: url, entries: playlists[i].entries)
        sort()
    }

    /// Moves the playlist's file to the Trash.
    func delete(_ id: Playlist.ID) {
        guard let playlist = playlists.first(where: { $0.id == id }),
              (try? FileManager.default.trashItem(at: playlist.url, resultingItemURL: nil)) != nil else { return }
        playlists.removeAll { $0.id == id }
    }

    /// Changes a playlist's entries and writes it. The entries of songs in the library first get the songs' path and
    /// tags as they are now: a moved file gets its new path, and the #EXTINF lines follow tag edits.
    private func update(_ id: Playlist.ID, _ change: (inout [Playlist.Entry]) -> Void) {
        guard let i = playlists.firstIndex(where: { $0.id == id }) else { return }
        let index = SongIndex(library())
        var playlist = playlists[i]
        // One for one, so the positions the caller has stay right.
        playlist.entries = playlist.entries.map { entry in index.song(for: entry).map(Playlist.Entry.init) ?? entry }
        change(&playlist.entries)
        // A moved file whose new path was in the playlist too is now there twice.
        var seen = Set<String>()
        playlist.entries = playlist.entries.filter { seen.insert($0.path).inserted }
        // A file written starts a scan, and a sync of the file.
        if playlist != playlists[i], write(playlist) { playlists[i] = playlist }
    }

    private func write(_ playlist: Playlist) -> Bool {
        guard let root else { return false }
        do {
            try FileManager.default.createDirectory(at: playlist.url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try playlist.text(root: root.path).write(to: playlist.url, atomically: true, encoding: .utf8)
            return true
        } catch {
            return false
        }
    }

    private func sort() {
        playlists.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The file for a playlist name that no other playlist has: "Name 2" when "Name" is taken. `renaming`: the file
    /// of the playlist being renamed, which does not count, so a change of case is possible.
    private func fileURL(for name: String, renaming current: URL? = nil) -> URL? {
        guard let directory else { return nil }
        // A file name cannot hold "/", and Finder shows ":" as "/". A leading "." would hide the file.
        var base = name.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        while base.hasPrefix(".") { base.removeFirst() }
        if base.isEmpty { base = "Untitled Playlist" }
        var number = 1
        while true {
            let candidate = number == 1 ? base : "\(base) \(number)"
            let url = directory.appendingPathComponent(candidate).appendingPathExtension("m3u8")
            let taken = playlists.contains { $0.url != current && $0.name.caseInsensitiveCompare(candidate) == .orderedSame }
                || current?.path.lowercased() != url.path.lowercased() && FileManager.default.fileExists(atPath: url.path)
            if !taken { return url }
            number += 1
        }
    }
}

/// "7 songs · 28 min", or "22 songs · 1 h 31 min".
func songsSummary(_ songs: [Song]) -> String {
    let minutes = Int(songs.reduce(0) { $0 + $1.duration } / 60)
    let length = minutes < 60 ? "\(max(minutes, 1)) min" : "\(minutes / 60) h \(minutes % 60) min"
    return "\(songs.count) \(songs.count == 1 ? "song" : "songs") · \(length)"
}

/// A playlist to name: a new one with some songs, or one to rename.
struct PlaylistNameRequest: Identifiable {
    let id = UUID()
    var songs: [Song] = []
    var renaming: Playlist?
}

extension EnvironmentValues {
    /// Opens the sheet that names a new playlist, or renames one. Set by the main window.
    @Entry var playlistSheet: (PlaylistNameRequest) -> Void = { _ in }
}

/// "Add to Playlist" in the right-click menus: a new playlist of the songs, or one of the playlists.
struct AddToPlaylistMenu: View {
    let songs: [Song]
    /// Not offered: the playlist the songs are listed in.
    var excluding: Playlist.ID?
    @Environment(PlaylistStore.self) private var store
    @Environment(\.playlistSheet) private var playlistSheet

    var body: some View {
        Menu("Add to Playlist") {
            Button(songs.count == 1 ? "New Playlist from Song…" : "New Playlist from \(songs.count) Songs…") {
                playlistSheet(PlaylistNameRequest(songs: songs))
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            let playlists = store.playlists.filter { $0.id != excluding }
            if !playlists.isEmpty { Divider() }
            ForEach(playlists) { playlist in
                Button(playlist.name) { store.add(songs, to: playlist.id) }
            }
        }
    }
}

/// Names a new playlist, or a playlist being renamed. The name is the file's name.
struct PlaylistNameSheet: View {
    let request: PlaylistNameRequest
    @Environment(\.dismiss) private var dismiss
    @Environment(PlaylistStore.self) private var store
    @State private var name: String
    @FocusState private var nameFocused: Bool

    init(request: PlaylistNameRequest) {
        self.request = request
        _name = State(initialValue: request.renaming?.name ?? "Untitled Playlist")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(request.renaming == nil ? "New Playlist" : "Rename Playlist").font(.headline)
                if !request.songs.isEmpty {
                    Text(songsSummary(request.songs)).font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 10) {
                Text("Name").font(.system(size: 12)).foregroundStyle(.secondary)
                TextField("", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .focused($nameFocused)
            }
            Text("Saved as an .m3u8 file in the Playlists folder of your music folder.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(request.renaming == nil ? "Create" : "Rename", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 400)
        .onAppear { nameFocused = true }
    }

    private func save() {
        if let playlist = request.renaming {
            store.rename(playlist.id, to: name)
        } else {
            store.create(named: name, songs: request.songs)
        }
        dismiss()
    }
}
