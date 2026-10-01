import Foundation
import Security

struct YouTubeVideo: Identifiable, Sendable {
    let id: String
    let title: String
    let channel: String
    let published: String
    let thumbnail: URL?

    var url: URL { URL(string: "https://www.youtube.com/watch?v=\(id)")! }
}

/// Search through the YouTube Data API v3. Each search costs 100 of the free 10,000 daily quota units.
enum YouTube {
    struct APIError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private struct Response: Decodable {
        struct Item: Decodable {
            struct ID: Decodable { let videoId: String? }
            struct Snippet: Decodable {
                struct Thumbs: Decodable {
                    struct Thumb: Decodable { let url: URL }
                    let medium: Thumb?
                }
                let title: String
                let channelTitle: String
                let publishedAt: String
                let thumbnails: Thumbs
            }
            let id: ID
            let snippet: Snippet
        }
        let items: [Item]
    }

    private struct ErrorResponse: Decodable {
        struct Body: Decodable { let message: String }
        let error: Body
    }

    static func search(_ query: String, key: String, limit: Int = 10) async throws -> [YouTubeVideo] {
        var components = URLComponents(string: "https://www.googleapis.com/youtube/v3/search")!
        components.queryItems = [
            URLQueryItem(name: "part", value: "snippet"),
            URLQueryItem(name: "type", value: "video"),
            URLQueryItem(name: "maxResults", value: String(limit)),
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "key", value: key),
        ]
        let (data, response) = try await URLSession.shared.data(from: components.url!)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            let message = (try? JSONDecoder().decode(ErrorResponse.self, from: data))?.error.message
            throw APIError(message: message?.htmlUnescaped ?? "YouTube search failed.")
        }
        return try JSONDecoder().decode(Response.self, from: data).items.compactMap { item in
            guard let id = item.id.videoId else { return nil }
            return YouTubeVideo(
                id: id,
                title: item.snippet.title.htmlUnescaped,
                channel: item.snippet.channelTitle.htmlUnescaped,
                published: String(item.snippet.publishedAt.prefix(4)),
                thumbnail: item.snippet.thumbnails.medium?.url
            )
        }
    }
}

extension String {
    /// "Rock &amp; Roll" -> "Rock & Roll". YouTube titles and Bandcamp page data come HTML-escaped.
    /// "&amp;" goes last, so "&amp;quot;" becomes "&quot;" and not a quote.
    var htmlUnescaped: String {
        [("&quot;", "\""), ("&#39;", "'"), ("&lt;", "<"), ("&gt;", ">"), ("&amp;", "&")]
            .reduce(self) { $0.replacingOccurrences(of: $1.0, with: $1.1) }
    }
}

/// The YouTube API key, edited in Settings and read by the search sheet.
@MainActor @Observable
final class YouTubeAccount {
    static let shared = YouTubeAccount()
    private static let keychainAccount = "youtube-api-key"

    /// Read from the Keychain on first use, not at launch: a Keychain read can show an access prompt.
    @ObservationIgnored private var cached: String?

    var apiKey: String {
        get {
            access(keyPath: \.apiKey)
            if cached == nil { cached = Keychain.get(Self.keychainAccount) ?? "" }
            return cached ?? ""
        }
        set {
            let key = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard key != apiKey else { return }
            withMutation(keyPath: \.apiKey) { cached = key }
            Keychain.set(key, account: Self.keychainAccount)
        }
    }
}

/// Stores the API key in the login Keychain instead of the plain-text defaults file.
enum Keychain {
    private static let service = "local.tinyplayer" // old app name, kept so the saved key still works

    static func get(_ account: String) -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account,
            kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    static func set(_ value: String, account: String) {
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
        SecItemDelete(query as CFDictionary)
        guard !value.isEmpty else { return }
        var item = query
        item[kSecValueData] = Data(value.utf8)
        SecItemAdd(item as CFDictionary, nil)
    }
}
