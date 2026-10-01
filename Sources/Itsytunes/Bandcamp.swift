import Foundation

/// File formats Bandcamp offers for purchases, by its own names.
enum BandcampFormat: String, CaseIterable, Identifiable {
    case mp3_320 = "mp3-320"
    case mp3V0 = "mp3-v0"
    case flac
    case aac = "aac-hi"
    case alac

    var id: String { rawValue }

    var label: String {
        switch self {
        case .mp3_320: "MP3 320"
        case .mp3V0: "MP3 V0"
        case .flac: "FLAC"
        case .aac: "AAC"
        case .alac: "Apple Lossless"
        }
    }
}

/// The Bandcamp sign-in and the chosen format, edited in Settings.
/// Bandcamp has no public API: the app uses the "identity" cookie of a signed-in session, kept in the Keychain.
@MainActor @Observable
final class BandcampAccount {
    static let shared = BandcampAccount()
    private static let keychainAccount = "bandcamp-identity"

    /// Shown in Settings; the cookie itself is only read when syncing.
    private(set) var username = UserDefaults.standard.string(forKey: "bandcampUsername")
    var isSignedIn: Bool { username != nil }

    var format = BandcampFormat(rawValue: UserDefaults.standard.string(forKey: "bandcampFormat") ?? "") ?? .mp3_320 {
        didSet { UserDefaults.standard.set(format.rawValue, forKey: "bandcampFormat") }
    }

    /// Read from the Keychain on use, not at launch: a Keychain read can show an access prompt.
    var identity: String? { Keychain.get(Self.keychainAccount) }

    /// Checks the cookie with Bandcamp, then keeps it. Throws if Bandcamp does not accept it.
    func signIn(identity: String) async throws {
        let summary = try await BandcampAPI(identity: identity).summary()
        Keychain.set(identity, account: Self.keychainAccount)
        username = summary.username
        UserDefaults.standard.set(summary.username, forKey: "bandcampUsername")
    }

    func signOut() {
        Keychain.set("", account: Self.keychainAccount)
        username = nil
        UserDefaults.standard.removeObject(forKey: "bandcampUsername")
    }
}

/// Downloads purchases from the Bandcamp collection that are not in the library yet.
/// Synced purchases are remembered, so a deleted album is not downloaded again.
@MainActor @Observable
final class BandcampSync {
    /// Set while syncing, for the toolbar.
    private(set) var status: String?
    /// Result of the last sync, for Settings.
    private(set) var lastResult: String?
    /// Files of the last sync, for the main window to show once the library has them.
    private(set) var added: [URL] = []

    /// "p123" keys (sale item type and ID) of downloaded purchases.
    @ObservationIgnored private var synced = Set(UserDefaults.standard.stringArray(forKey: "bandcampSynced") ?? [])

    var isRunning: Bool { status != nil }

    func sync(into folder: URL) {
        let account = BandcampAccount.shared
        guard !isRunning, let identity = account.identity else { return }
        let api = BandcampAPI(identity: identity)
        let format = account.format
        status = "Bandcamp: checking collection"
        Task {
            var files: [URL] = []
            var failures: [String] = []
            do {
                let new = try await api.collection().filter { !synced.contains($0.key) }
                for (i, purchase) in new.enumerated() {
                    status = "Bandcamp: \(i + 1) of \(new.count)"
                    do {
                        files += try await api.download(purchase, format: format, into: folder)
                        synced.insert(purchase.key)
                        UserDefaults.standard.set(Array(synced), forKey: "bandcampSynced")
                    } catch {
                        failures.append("\(purchase.artist) - \(purchase.title): \(error.localizedDescription)")
                    }
                }
                lastResult = new.isEmpty ? "No new purchases." : "\(new.count - failures.count) of \(new.count) purchases added."
            } catch {
                lastResult = error.localizedDescription
            }
            if !failures.isEmpty { lastResult = ([lastResult ?? ""] + failures).joined(separator: "\n") }
            if !files.isEmpty { added = files }
            status = nil
        }
    }
}

/// The parts of Bandcamp's website API the sync uses. All calls send the session cookie.
struct BandcampAPI: Sendable {
    let identity: String

    /// Sends only the cookie set on each request: the shared session would add and keep cookies of its own.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        return URLSession(configuration: configuration)
    }()

    struct BandcampError: LocalizedError {
        let errorDescription: String?
    }

    /// A purchase that can be downloaded.
    struct Purchase: Sendable {
        let key: String
        let artist: String
        let title: String
        let downloadPage: URL
    }

    struct Summary: Decodable {
        let fan_id: Int
        let collection_summary: Details
        struct Details: Decodable { let username: String }
        var username: String { collection_summary.username }
    }

    func summary() async throws -> Summary {
        let data = try await fetch(URLRequest(url: URL(string: "https://bandcamp.com/api/fan/2/collection_summary")!))
        guard let summary = try? JSONDecoder().decode(Summary.self, from: data) else {
            throw BandcampError(errorDescription: "Bandcamp did not accept the sign-in. Sign in again in Settings.")
        }
        return summary
    }

    private struct Page: Decodable {
        struct Item: Decodable {
            let sale_item_type: String?
            let sale_item_id: Int?
            let band_name: String
            let item_title: String
            let is_preorder: Bool?
        }
        let items: [Item]
        let more_available: Bool
        let last_token: String?
        /// "p123" -> download page, only for purchases with a digital download.
        let redownload_urls: [String: String]?
    }

    /// All purchases with a download, newest first. Pre-orders are left out until they are released.
    func collection() async throws -> [Purchase] {
        let fanID = try await summary().fan_id
        var purchases: [Purchase] = []
        var token = "\(Int(Date().timeIntervalSince1970))::a::"
        while true {
            var request = URLRequest(url: URL(string: "https://bandcamp.com/api/fancollection/1/collection_items")!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["fan_id": fanID, "older_than_token": token, "count": 100])
            let page = try JSONDecoder().decode(Page.self, from: try await fetch(request))
            for item in page.items where item.is_preorder != true {
                guard let type = item.sale_item_type, let id = item.sale_item_id else { continue }
                let key = "\(type)\(id)"
                guard let link = page.redownload_urls?[key], let url = URL(string: link) else { continue }
                purchases.append(Purchase(key: key, artist: item.band_name, title: item.item_title, downloadPage: url))
            }
            guard page.more_available, let next = page.last_token, next != token else { break }
            token = next
        }
        return purchases
    }

    private struct DownloadPage: Decodable {
        struct Item: Decodable {
            struct Download: Decodable { let url: String }
            let downloads: [String: Download]?
        }
        let digital_items: [Item]
    }

    /// Downloads one purchase in `format` into `folder`: an album (a zip) into its own "Artist - Title"
    /// folder, a track as one file. Returns the audio files.
    func download(_ purchase: Purchase, format: BandcampFormat, into folder: URL) async throws -> [URL] {
        // The download page holds the file links in its page data, HTML-escaped.
        let html = String(decoding: try await fetch(URLRequest(url: purchase.downloadPage)), as: UTF8.self)
        guard let blob = html.firstMatch(of: #/id="pagedata" data-blob="([^"]*)"/#)?.1,
              let page = try? JSONDecoder().decode(DownloadPage.self, from: Data(String(blob).htmlUnescaped.utf8)),
              let downloads = page.digital_items.first?.downloads else {
            throw BandcampError(errorDescription: "No download found.")
        }
        guard let link = downloads[format.rawValue]?.url, let url = URL(string: link) else {
            throw BandcampError(errorDescription: "Not available as \(format.label).")
        }

        var request = URLRequest(url: url)
        request.setValue("identity=\(identity)", forHTTPHeaderField: "Cookie")
        let (temporary, response) = try await Self.session.download(for: request)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let name = response.suggestedFilename ?? ""
        // A web page instead of a file: Bandcamp is still preparing the download.
        guard (response as? HTTPURLResponse)?.statusCode == 200, !(response.mimeType ?? "").hasPrefix("text/") else {
            throw BandcampError(errorDescription: "Bandcamp is still preparing the download. Sync again later.")
        }

        let fm = FileManager.default
        let base = DownloadTagger.safeName("\(purchase.artist) - \(purchase.title)")
        if (name as NSString).pathExtension.lowercased() == "zip" {
            let target = DownloadTagger.unique(folder.appendingPathComponent(base))
            try unzip(temporary, to: target)
            let contents = fm.enumerator(at: target, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? []
            return contents.filter { Library.audioExtensions.contains($0.pathExtension.lowercased()) }
        }
        let ext = (name as NSString).pathExtension
        let target = DownloadTagger.unique(folder.appendingPathComponent(base).appendingPathExtension(ext.isEmpty ? "mp3" : ext))
        try fm.moveItem(at: temporary, to: target)
        return [target]
    }

    private func unzip(_ zip: URL, to folder: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", zip.path, folder.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw BandcampError(errorDescription: "Could not unpack the download.") }
    }

    private func fetch(_ request: URLRequest) async throws -> Data {
        var request = request
        request.setValue("identity=\(identity)", forHTTPHeaderField: "Cookie")
        let (data, response) = try await Self.session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw BandcampError(errorDescription: "Bandcamp is not reachable.")
        }
        return data
    }
}
