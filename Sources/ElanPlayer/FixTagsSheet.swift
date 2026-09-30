import SwiftUI

/// Lists proposed tag changes and rewrites tags only on confirm.
/// Online: looks songs up in the catalogue (falling back to a cleaned title). Offline: cleans up titles only.
struct FixTagsSheet: View {
    let songs: [Song]
    var online = true
    @Environment(\.dismiss) private var dismiss
    @Environment(Library.self) private var library
    @State private var proposals: [TagProposal] = []
    @State private var accepted: Set<TagProposal.ID> = []
    @State private var checked = 0

    private var lookingUp: Bool { checked < songs.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(online ? "Fix Tags" : "Clean Up Tags").font(.headline)
                Text(summary).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .padding(16)
            Divider()

            if proposals.isEmpty {
                Group {
                    if lookingUp {
                        ProgressView().controlSize(.small)
                    } else {
                        ContentUnavailableView(online ? "No Better Tags Found" : "Titles Are Clean", systemImage: "tag.slash",
                                               description: Text(online ? "The online catalogue had no match for these songs."
                                                                        : "No title has noise to remove."))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(proposals) { proposal in
                    ProposalRow(proposal: proposal, isOn: Binding(
                        get: { accepted.contains(proposal.id) },
                        set: { if $0 { accepted.insert(proposal.id) } else { accepted.remove(proposal.id) } }
                    ))
                }
                .listStyle(.inset)
            }

            Divider()
            HStack {
                Text("MP3 files are rewritten. Other formats change in Elan Player only.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(accepted.count == 1 ? "Replace Tags" : "Replace Tags on \(accepted.count) Songs") {
                    apply()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(accepted.isEmpty || lookingUp)
            }
            .padding(12)
        }
        .frame(width: 620, height: 480)
        .task {
            for song in songs {
                let proposal = online ? await TagFixer.propose(for: song) : TagFixer.cleanupProposal(for: song)
                if let proposal {
                    proposals.append(proposal)
                    accepted.insert(proposal.id)
                }
                checked += 1
            }
        }
    }

    private var summary: String {
        if lookingUp { return online ? "Looking up \(checked + 1) of \(songs.count)…" : "Checking titles…" }
        let missing = songs.count - proposals.count
        return "\(proposals.count) of \(songs.count) songs have changes." + (missing > 0 ? " No match for \(missing)." : "")
    }

    private func apply() {
        // Writing continues in the background; the toolbar button shows its progress.
        // Unchecked titles were reviewed and kept, so the Clean Up button stops offering them.
        library.write(proposals.filter { accepted.contains($0.id) },
                      verb: online ? "Fixing" : "Cleaning up",
                      keeping: online ? [] : proposals.filter { !accepted.contains($0.id) }.map(\.song))
        dismiss()
    }
}

private struct ProposalRow: View {
    let proposal: TagProposal
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 3) {
                // The song as the library shows it; the file name (often noisy) is in the tooltip.
                Text(proposal.song.displayTitle).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    .help(proposal.song.url.lastPathComponent)
                Text([proposal.song.artist, proposal.song.album].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                ForEach(proposal.changes, id: \.field) { change in
                    HStack(spacing: 4) {
                        // The tag being changed, as a chip.
                        Text(change.field)
                            .font(.system(size: 10, weight: .medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                            .padding(.trailing, 2)
                        Text(change.old.isEmpty ? "none" : change.old).strikethrough(!change.old.isEmpty).foregroundStyle(.secondary)
                        Image(systemName: "arrow.right").font(.system(size: 8)).foregroundStyle(.tertiary)
                        Text(change.new)
                    }
                    .font(.system(size: 11))
                    .lineLimit(1)
                }
                if proposal.artworkURL != nil {
                    Text("New cover art").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }
        .toggleStyle(.checkbox)
        .padding(.vertical, 2)
    }
}
