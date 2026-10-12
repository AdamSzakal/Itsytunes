import SwiftUI

/// The box around the songs that repeat plays again: a light gray background. Rows next to each other share one
/// box: the corners between them are square.
struct RepeatBox: Shape {
    /// Of the text color, so the gray suits light and dark mode.
    static let opacity = 0.06
    /// Of the songs and headers outside the boxes while they are faded.
    static let fadedOpacity = 0.35
    /// Of the fade both ways: slow, so it does not draw the eye.
    static let fadeDuration = 0.7
    /// Before the songs fade, so they do not fade the moment the pointer passes the box.
    static let fadeDelay = 1.0
    var top = true
    var bottom = true

    func path(in rect: CGRect) -> Path {
        let radius = min(6, rect.height / 2)
        return UnevenRoundedRectangle(topLeadingRadius: top ? radius : 0, bottomLeadingRadius: bottom ? radius : 0,
                                      bottomTrailingRadius: bottom ? radius : 0, topTrailingRadius: top ? radius : 0)
            .path(in: rect)
    }

    /// For each song, its row's box, or nil for a song that does not repeat. Rows next to each other share one box.
    static func rows(_ repeated: [Bool]) -> [RepeatBox?] {
        repeated.indices.map { i in
            guard repeated[i] else { return nil }
            return RepeatBox(top: i == 0 || !repeated[i - 1], bottom: i == repeated.count - 1 || !repeated[i + 1])
        }
    }

    /// Groups, of `ids` in list order, whose line below goes: no line touches a box, which sets its group apart already.
    static func hiddenDividers(_ ids: [String], boxed: Set<String>) -> Set<String> {
        Set(ids.indices.filter { boxed.contains(ids[$0]) || $0 + 1 < ids.count && boxed.contains(ids[$0 + 1]) }.map { ids[$0] })
    }

    /// The songs outside the boxes fade while the user is not looking at them: when there is a box, and neither
    /// the pointer nor the selection is outside it.
    static func fades(inside: Set<String>, selected: String?, pointerOutside: Bool) -> Bool {
        !inside.isEmpty && !pointerOutside && selected.map(inside.contains) != false
    }
}

/// Names what repeats, in the top-right corner of a repeat box.
struct RepeatChip: View {
    let mode: RepeatMode

    var body: some View {
        // The repeat button's symbols.
        Label("Repeating \(mode.rawValue)", systemImage: mode == .song ? "repeat.1" : "repeat")
            .labelStyle(ChipLabelStyle())
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            // Opaque under the light blue, so it reads on a selected row too.
            .background(Color.accentColor.opacity(0.15), in: Capsule())
            .background(Color(nsColor: .controlBackgroundColor), in: Capsule())
            .fixedSize()
    }

    private struct ChipLabelStyle: LabelStyle {
        func makeBody(configuration: Configuration) -> some View {
            HStack(spacing: 3) {
                configuration.icon.font(.system(size: 9, weight: .semibold))
                configuration.title
            }
        }
    }
}

extension View {
    /// Draws the box behind the view, the given distance outside it (inside for a negative distance),
    /// with the chip in its top-right corner.
    func repeatBox(_ box: RepeatBox?, outset: CGSize = .zero, chip: RepeatMode? = nil) -> some View {
        background {
            if let box {
                box.fill(Color.primary.opacity(RepeatBox.opacity))
                    .padding(.horizontal, -outset.width)
                    .padding(.vertical, -outset.height)
            }
        }
        .overlay(alignment: .topTrailing) {
            if box != nil, let chip {
                RepeatChip(mode: chip)
                    .padding(.top, 6 - outset.height)
                    .padding(.trailing, 6 - outset.width)
            }
        }
    }

    /// For a song or header outside the repeat boxes: fades it, and tells the list when the pointer is on it.
    /// One inside the boxes tells the list that the pointer is back. Gaps between rows change nothing.
    func repeatFade(inside: Bool, faded: Bool, pointerOutside: Binding<Bool>) -> some View {
        opacity(faded && !inside ? RepeatBox.fadedOpacity : 1)
            .onHover { if $0 { pointerOutside.wrappedValue = !inside } }
    }

    /// Makes `faded` follow `fades`, in one animation for the whole list: at once when the songs come back, and
    /// after `fadeDelay` when they fade, unless the user looks away again first. Not a delayed animation: one that
    /// is undone before it starts still plays, and the songs fade after the user has moved away.
    func repeatFadeTiming(_ fades: Bool, faded: Binding<Bool>) -> some View {
        task(id: fades) {
            if fades {
                do { try await Task.sleep(for: .seconds(RepeatBox.fadeDelay)) } catch { return } // looked away again
            }
            withAnimation(.easeInOut(duration: RepeatBox.fadeDuration)) { faded.wrappedValue = fades }
        }
    }
}

/// The repeat boxes of the song table: one around each run of rows, by index, and the fade of the other rows.
/// AppKit, because a SwiftUI table draws only inside its cells. The boxes are in a view above the table, in its
/// clip view, so they scroll with the rows, and that view lets the clicks through.
struct TableRepeatBoxes: NSViewRepresentable {
    let runs: [Range<Int>]
    let faded: Bool
    /// Whether the pointer is on a row outside the boxes. False once it leaves the table.
    let pointerOutside: (Bool) -> Void

    final class Overlay: NSView {
        weak var table: NSTableView?
        var observer: NSObjectProtocol?
        var pointerOutside: (Bool) -> Void = { _ in }
        /// Covers the other rows in the table's background color: a fade that can animate, unlike drawn rows.
        let wash = Wash()
        var runs: [Range<Int>] = [] {
            didSet {
                guard runs != oldValue else { return }
                needsDisplay = true
                wash.needsDisplay = true
            }
        }

        override init(frame: NSRect) {
            super.init(frame: frame)
            wash.alphaValue = 0
            addSubview(wash)
        }

        required init?(coder: NSCoder) { fatalError("not used") }

        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func setFrameSize(_ size: NSSize) {
            super.setFrameSize(size)
            wash.frame = bounds
            wash.needsDisplay = true
        }

        /// The rect of each run, in this view.
        func boxes(in dirtyRect: NSRect) -> [NSRect] {
            guard let table else { return [] }
            return runs.filter { $0.upperBound <= table.numberOfRows }.map { run in
                let rows = table.rect(ofRow: run.lowerBound).union(table.rect(ofRow: run.upperBound - 1))
                // Rows reach the window's edges: clear of them, the rounded corners show.
                return convert(rows, from: table).insetBy(dx: 4, dy: 0)
            }
            .filter { $0.intersects(dirtyRect) }
        }

        override func draw(_ dirtyRect: NSRect) {
            guard let context = NSGraphicsContext.current?.cgContext else { return }
            for box in boxes(in: dirtyRect) { context.addPath(RepeatBox().path(in: box).cgPath) }
            context.setFillColor(NSColor.labelColor.withAlphaComponent(RepeatBox.opacity).cgColor)
            context.fillPath()
        }

        private var faded = false

        /// Already delayed by `repeatFadeTiming`.
        func setFaded(_ faded: Bool) {
            guard faded != self.faded else { return }
            self.faded = faded
            NSAnimationContext.runAnimationGroup { context in
                context.duration = RepeatBox.fadeDuration
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                wash.animator().alphaValue = faded ? 1 : 0
            }
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                           owner: self))
        }

        override func mouseMoved(with event: NSEvent) {
            guard let table else { return }
            let row = table.row(at: table.convert(event.locationInWindow, from: nil))
            // Below the last row changes nothing, as the gaps in the album and artist lists do.
            if row >= 0 { pointerOutside(!runs.contains { $0.contains(row) }) }
        }

        override func mouseExited(with event: NSEvent) { pointerOutside(false) }

        deinit { observer.map(NotificationCenter.default.removeObserver) }

        final class Wash: NSView {
            override var isFlipped: Bool { true }
            override func hitTest(_ point: NSPoint) -> NSView? { nil }

            override func draw(_ dirtyRect: NSRect) {
                guard let overlay = superview as? Overlay, let context = NSGraphicsContext.current?.cgContext else { return }
                context.addRect(dirtyRect)
                for box in overlay.boxes(in: dirtyRect) { context.addPath(RepeatBox().path(in: box).cgPath) }
                context.setFillColor(NSColor.controlBackgroundColor.withAlphaComponent(1 - RepeatBox.fadedOpacity).cgColor)
                context.fillPath(using: .evenOdd) // all but the boxes
            }
        }
    }

    /// The runs of songs that repeat, by index.
    static func runs(_ repeated: [Bool]) -> [Range<Int>] {
        var runs: [Range<Int>] = []
        var start: Int?
        for i in 0...repeated.count {
            let isRepeated = i < repeated.count && repeated[i] // one past the end closes the last run
            if isRepeated, start == nil { start = i }
            if !isRepeated, let first = start {
                runs.append(first..<i)
                start = nil
            }
        }
        return runs
    }

    func makeCoordinator() -> Overlay { Overlay() }
    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        let overlay = context.coordinator
        overlay.runs = runs
        overlay.pointerOutside = pointerOutside
        overlay.setFaded(faded)
        guard overlay.superview == nil else { return }
        // The table is added to the window after this view, so look it up on the next run loop.
        DispatchQueue.main.async {
            guard overlay.superview == nil, let table = HiddenRowSeparators.findTable(in: view.window?.contentView),
                  let clipView = table.superview else { return }
            overlay.table = table
            overlay.frame = table.frame
            clipView.addSubview(overlay, positioned: .above, relativeTo: table)
            // New rows and wider columns change the table's size.
            overlay.observer = NotificationCenter.default.addObserver(
                forName: NSView.frameDidChangeNotification, object: table, queue: .main
            ) { [weak overlay, weak table] _ in
                guard let overlay, let table else { return }
                overlay.frame = table.frame
                overlay.needsDisplay = true
            }
        }
    }

    static func dismantleNSView(_ view: NSView, coordinator: Overlay) { coordinator.removeFromSuperview() }
}
