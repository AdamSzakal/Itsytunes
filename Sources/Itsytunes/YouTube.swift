import Foundation
import Security

struct YouTubeVideo: Identifiable, Sendable {
    let id: String
    let title: String
    let channel: String
    let published: String
    let thumbnail: URL?
    /// Seconds; nil when the length lookup failed.
    let duration: Double?

    var url: URL { URL(string: "https://www.youtube.com/watch?v=\(id)")! }
}

/// Search through the YouTube Data API v3. Each search costs 100 of the free 10,000 daily quota units,
/// plus 1 unit for the video lengths, which the search results do not include.
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

    private struct DetailsResponse: Decodable {
        struct Item: Decodable {
            struct Details: Decodable { let duration: String }
            let id: String
            let contentDetails: Details
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
        let items = try JSONDecoder().decode(Response.self, from: data).items
        // The lengths are extra: without them the results still show.
        let durations = (try? await durations(of: items.compactMap(\.id.videoId), key: key)) ?? [:]
        return items.compactMap { item in
            guard let id = item.id.videoId else { return nil }
            return YouTubeVideo(
                id: id,
                title: item.snippet.title.htmlUnescaped,
                channel: item.snippet.channelTitle.htmlUnescaped,
                published: String(item.snippet.publishedAt.prefix(4)),
                thumbnail: item.snippet.thumbnails.medium?.url,
                duration: durations[id]
            )
        }
    }

    /// Video lengths in seconds, by video ID.
    private static func durations(of ids: [String], key: String) async throws -> [String: Double] {
        guard !ids.isEmpty else { return [:] }
        var components = URLComponents(string: "https://www.googleapis.com/youtube/v3/videos")!
        components.queryItems = [
            URLQueryItem(name: "part", value: "contentDetails"),
            URLQueryItem(name: "id", value: ids.joined(separator: ",")),
            URLQueryItem(name: "key", value: key),
        ]
        let (data, _) = try await URLSession.shared.data(from: components.url!)
        let items = try JSONDecoder().decode(DetailsResponse.self, from: data).items
        return Dictionary(items.compactMap { item in parseDuration(item.contentDetails.duration).map { (item.id, $0) } },
                          uniquingKeysWith: { first, _ in first })
    }

    /// "PT1H2M3S" -> 3723. YouTube gives lengths in ISO 8601; very long ones start with days ("P1DT2H").
    /// Live streams give "P0D", which is 0 and so shows no length.
    static func parseDuration(_ text: String) -> Double? {
        let units: [Character: Double] = ["D": 86400, "H": 3600, "M": 60, "S": 1]
        var total = 0.0, number = ""
        for character in text.dropFirst() where character != "T" { // drop the leading "P"
            if character.isNumber {
                number.append(character)
            } else if let unit = units[character], let value = Double(number) {
                total += value * unit
                number = ""
            } else {
                return nil
            }
        }
        return total > 0 ? total : nil
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
