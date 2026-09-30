import Foundation

/// A regular expression compiled once, for code that runs on every song.
/// Swift `Regex` literals are rebuilt on every call (about 86 µs each, measured; this is 1.6 µs):
/// with about 20 per title, checking the library for noisy titles made launching take 2 seconds.
struct Pattern: @unchecked Sendable { // NSRegularExpression is immutable and safe to share
    private let regex: NSRegularExpression

    init(_ pattern: String) {
        regex = try! NSRegularExpression(pattern: pattern)
    }

    func replacing(in s: String, with template: String = "") -> String {
        regex.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
    }

    /// The first match's range, and each capture group (nil when the group took no part in the match).
    func firstMatch(in s: String) -> (range: Range<String.Index>, groups: [String?])? {
        guard let match = regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              let range = Range(match.range, in: s) else { return nil }
        let groups = (1..<match.numberOfRanges).map { Range(match.range(at: $0), in: s).map { String(s[$0]) } }
        return (range, groups)
    }

    /// The text between the matches.
    func split(_ s: String) -> [String] {
        var parts: [String] = []
        var start = s.startIndex
        for match in regex.matches(in: s, range: NSRange(s.startIndex..., in: s)) {
            guard let range = Range(match.range, in: s) else { continue }
            parts.append(String(s[start..<range.lowerBound]))
            start = range.upperBound
        }
        parts.append(String(s[start...]))
        return parts
    }
}
