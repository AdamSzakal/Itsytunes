import SwiftUI

/// Find and replace in one tag of several songs, with plain text or a regular expression, not case-sensitive.
struct FindReplace {
    var field: WritableKeyPath<Tags, String> = \.title
    var find = "" { didSet { compile() } }
    var replacement = ""
    /// `find` is a regular expression, and `replacement` can put back its groups: "$1".
    var isRegex = false { didSet { compile() } }
    /// The compiled `find`, when it is a valid regular expression.
    private(set) var regex: NSRegularExpression?

    /// The tags it can change.
    static let fields: [(name: String, path: WritableKeyPath<Tags, String>)] = [
        ("Title", \.title), ("Artist", \.artist), ("Album", \.album), ("Album Artist", \.albumArtist), ("Genre", \.genre),
    ]

    var isActive: Bool { !find.isEmpty && (!isRegex || regex != nil) }

    /// A regular expression that is not valid: nothing changes.
    var isInvalid: Bool { isRegex && !find.isEmpty && regex == nil }

    /// The tag with each match replaced. A changed tag loses the spaces at its ends.
    func apply(to value: String) -> String {
        guard isActive else { return value }
        let result = if let regex {
            regex.stringByReplacingMatches(in: value, range: NSRange(value.startIndex..., in: value), withTemplate: replacement)
        } else {
            value.replacingOccurrences(of: find, with: replacement, options: .caseInsensitive)
        }
        return result == value ? value : result.trimmingCharacters(in: .whitespaces)
    }

    /// Once per change, not in `apply`: that runs for every song on every key press.
    private mutating func compile() {
        regex = isRegex ? try? NSRegularExpression(pattern: find, options: .caseInsensitive) : nil
    }
}

/// The find and replace of the tag editor, laid out as Figma's batch rename: the new tags on the left, the fields
/// on the right.
struct FindReplaceView: View {
    @Binding var replace: FindReplace
    /// The tag of each song before the change, in list order.
    let values: [String]
    /// The tags to choose from: the album artist only once it is read from the files.
    let fields: [(name: String, path: WritableKeyPath<Tags, String>)]
    /// Shown: the find field takes the keyboard focus.
    let active: Bool
    @FocusState private var findFocused: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            preview
            controls.frame(width: 280)
        }
        .task(id: active) { if active { findFocused = true } }
    }

    private var preview: some View {
        let new = values.map(replace.apply)
        let changes = values.indices.filter { new[$0] != values[$0] }.count
        return VStack(alignment: .leading, spacing: 6) {
            Text(changes == 0 ? "Preview" : "\(changes) of \(values.count) songs change")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 5) {
                    ForEach(values.indices, id: \.self) { i in
                        // Unchanged tags are dim, so the songs that change stand out.
                        Text(new[i].isEmpty ? "none" : new[i])
                            .italic(new[i].isEmpty)
                            .foregroundStyle(new[i] != values[i] ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                            .lineLimit(1)
                            .help(new[i] == values[i] ? values[i] : "\(values[i]) → \(new[i].isEmpty ? "none" : new[i])")
                    }
                }
                .font(.system(size: 12))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 150)
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Find in", selection: $replace.field) {
                ForEach(fields, id: \.path) { Text($0.name).tag($0.path) }
            }
            .fixedSize()
            TextField("Find", text: $replace.find)
                .focused($findFocused)
                .help(replace.isRegex ? "A regular expression, not case-sensitive" : "Plain text, not case-sensitive")
            TextField("Replace with", text: $replace.replacement)
            Toggle("Regular expression", isOn: $replace.isRegex)
                .toggleStyle(.checkbox)
            if replace.isInvalid {
                Text("This is not a valid regular expression.")
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
            } else if replace.isRegex {
                // The few patterns most tag fixes need.
                Text(verbatim: "\\d+ a number   .* any text   ^ start   $ end\n( ) a group, put back with $1 in Replace with")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .textFieldStyle(.roundedBorder)
    }
}
