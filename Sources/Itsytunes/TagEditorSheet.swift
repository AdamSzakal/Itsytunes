import SwiftUI

/// Edits the tags of one or more songs by hand. With several songs, a field they do not agree on shows
/// "Mixed" and only changes when typed into. Saving goes through `Library.write`, like the online fixes.
struct TagEditorSheet: View {
    let songs: [Song]
    @Environment(\.dismiss) private var dismiss
    @Environment(Library.self) private var library

    /// One text field. `original` is nil when the songs have different values.
    struct Field {
        let original: String?
        var value: String
        var edited = false

        init(_ values: [String]) {
            let first = values.first ?? ""
            original = values.allSatisfy { $0 == first } ? first : nil
            value = original ?? ""
        }

        var isMixed: Bool { original == nil && !edited }
    }

    @State private var title: Field
    @State private var artist: Field
    @State private var album: Field
    /// Not in the library cache: read from the files when the sheet opens.
    @State private var albumArtist = Field([])
    @State private var albumArtistLoaded = false
    @State private var year: Field
    @State private var genre: Field
    @State private var track: Field
    /// Several songs: number them 1, 2, 3… in the order given.
    @State private var numberInOrder = false
    /// A new cover for all songs.
    @State private var cover: Data?
    @State private var dropTargeted = false

    init(songs: [Song]) {
        self.songs = songs
        _title = State(initialValue: Field(songs.map(\.title)))
        _artist = State(initialValue: Field(songs.map(\.artist)))
        _album = State(initialValue: Field(songs.map(\.album)))
        _year = State(initialValue: Field(songs.map(\.year)))
        _genre = State(initialValue: Field(songs.map(\.genre)))
        _track = State(initialValue: Field(songs.map { $0.track.map(String.init) ?? "" }))
    }

    private var isBatch: Bool { songs.count > 1 }
    private var anyEdited: Bool {
        [title, artist, album, albumArtist, year, genre, track].contains(where: \.edited) || numberInOrder || cover != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            header.padding(20)
            Divider()
            fields.padding(20)
            Divider()
            footer.padding(12)
        }
        .frame(width: 540)
        .task {
            // Album artist is only read here; the library does not keep it.
            var values: [String] = []
            for song in songs { values.append(await MetadataReader.read(song.url).albumArtist) }
            albumArtist = Field(values)
            albumArtistLoaded = true
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: 18) {
            coverView
            VStack(alignment: .leading, spacing: 4) {
                Text(isBatch ? "\(songs.count) Songs" : songs[0].displayTitle)
                    .font(.system(size: 17, weight: .semibold))
                    .lineLimit(2)
                Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                Text(fileSummary).font(.system(size: 11)).foregroundStyle(.tertiary).padding(.top, 2)
                Spacer(minLength: 8)
                HStack(spacing: 8) {
                    Button("Choose Cover…", action: chooseCover)
                    if cover != nil { Button("Keep Old Cover") { cover = nil } }
                }
                .controlSize(.small)
            }
            Spacer(minLength: 0)
        }
        .frame(height: 128)
    }

    private var subtitle: String {
        let albums = Set(songs.map(\.album))
        let artists = Set(songs.map(\.artist))
        let artistText = artists.count == 1 ? songs[0].artist : "Several artists"
        let albumText = albums.count == 1 ? songs[0].album : "several albums"
        return [artistText, albumText].filter { !$0.isEmpty }.joined(separator: " — ")
    }

    /// "MP3 · 38 min", or "MP3, FLAC · 1 h 12 min" for mixed formats.
    private var fileSummary: String {
        let formats = Set(songs.map { $0.url.pathExtension.uppercased() }).sorted().joined(separator: ", ")
        let minutes = Int(songs.reduce(0) { $0 + $1.duration } / 60)
        let length = minutes < 60 ? "\(max(minutes, 1)) min" : "\(minutes / 60) h \(minutes % 60) min"
        return "\(formats) · \(length)"
    }

    /// The cover the songs share: click to choose a new one for all of them, or drop an image on it.
    private var coverView: some View {
        Group {
            if let cover, let image = NSImage(data: cover) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                    .frame(width: 128, height: 128)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else if Set(songs.map(\.artworkKey)).count == 1 {
                ArtworkView(key: songs[0].artworkKey, size: 128)
            } else {
                // Several covers: showing one would suggest all songs have it.
                RoundedRectangle(cornerRadius: 8).fill(.quaternary)
                    .overlay {
                        VStack(spacing: 6) {
                            Image(systemName: "photo.stack").font(.system(size: 30))
                            Text("Several covers").font(.system(size: 11))
                        }
                        .foregroundStyle(.secondary)
                    }
                    .frame(width: 128, height: 128)
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.accentColor, lineWidth: 3)
                .opacity(dropTargeted ? 1 : 0)
        }
        .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
        .onTapGesture(perform: chooseCover)
        .dropDestination(for: URL.self) { urls, _ in
            guard let data = urls.lazy.compactMap(Self.imageData).first else { return false }
            cover = data
            return true
        } isTargeted: { dropTargeted = $0 }
        .help("Click to choose a cover, or drop an image here")
    }

    private func chooseCover() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.prompt = "Use as Cover"
        if panel.runModal() == .OK, let url = panel.url, let data = Self.imageData(url) { cover = data }
    }

    /// JPEG or PNG data of an image file. Other formats (HEIC, TIFF) are converted to JPEG, which every player reads.
    private static func imageData(_ url: URL) -> Data? {
        guard url.isFileURL, let data = try? Data(contentsOf: url), let image = NSImage(data: data) else { return nil }
        if data.starts(with: [0xFF, 0xD8]) || data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return data }
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.9])
    }

    // MARK: Fields

    private var fields: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 10) {
            row("Title", $title)
            row("Artist", $artist)
            row("Album", $album)
            row("Album Artist", $albumArtist).disabled(!albumArtistLoaded)
            GridRow {
                label("Year")
                HStack(spacing: 10) {
                    field($year).frame(width: 90)
                    label("Genre")
                    field($genre)
                }
            }
            GridRow {
                label("Track")
                HStack(spacing: 12) {
                    field($track).frame(width: 90).disabled(numberInOrder)
                    if isBatch {
                        Toggle("Number 1, 2, 3… in list order", isOn: $numberInOrder).toggleStyle(.checkbox)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private func row(_ name: String, _ binding: Binding<Field>) -> some View {
        GridRow {
            label(name)
            field(binding)
        }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .gridColumnAlignment(.trailing)
    }

    /// A text field that remembers it was edited, with a button to undo the edit.
    private func field(_ binding: Binding<Field>) -> some View {
        HStack(spacing: 4) {
            TextField(binding.wrappedValue.isMixed ? "Mixed" : "", text: Binding(
                get: { binding.wrappedValue.value },
                set: { binding.wrappedValue.value = $0; binding.wrappedValue.edited = true }
            ))
            .textFieldStyle(.roundedBorder)
            if binding.wrappedValue.edited {
                Button {
                    binding.wrappedValue.value = binding.wrappedValue.original ?? ""
                    binding.wrappedValue.edited = false
                } label: {
                    Image(systemName: "arrow.uturn.backward.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Undo this change")
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            Text(songs.allSatisfy { $0.url.pathExtension.lowercased() == "mp3" }
                 ? "Changes are written into the files."
                 : "MP3 files are rewritten. Other formats change in Itsytunes only.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
            Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            Button(isBatch ? "Save \(songs.count) Songs" : "Save", action: save)
                .keyboardShortcut(.defaultAction)
                .disabled(!anyEdited)
        }
    }

    /// Only edited fields change. A field cleared by the user is removed from the file.
    private func save() {
        let edits: [(WritableKeyPath<Tags, String>, Field)] = [
            (\.title, title), (\.artist, artist), (\.album, album), (\.albumArtist, albumArtist), (\.year, year), (\.genre, genre),
        ]
        let proposals = songs.enumerated().map { index, song in
            var tags = Tags(title: song.title, artist: song.artist, album: song.album, year: song.year, genre: song.genre, track: song.track)
            var removing = Set<String>()
            for (path, field) in edits where field.edited {
                let value = field.value.trimmingCharacters(in: .whitespaces)
                tags[keyPath: path] = value
                if value.isEmpty, let id = ID3Writer.frameIDs[path] { removing.insert(id) }
            }
            if numberInOrder {
                tags.track = index + 1
            } else if track.edited {
                tags.track = Int(track.value.trimmingCharacters(in: .whitespaces))
                if tags.track == nil { removing.insert(ID3Writer.trackFrameID) }
            }
            return TagProposal(song: song, tags: tags, artworkURL: nil, artwork: cover, removing: removing)
        }
        library.write(proposals, verb: "Saving", keeping: [])
        dismiss()
    }
}
