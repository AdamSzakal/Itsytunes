import SwiftUI

/// Hides the lines between table rows. SwiftUI draws them whenever row striping is off and has no
/// setting for them, so this hides AppKit's separator view in each row (visible rows, on every
/// change and scroll). If a future macOS renames that view, the lines simply come back.
struct HiddenRowSeparators: NSViewRepresentable {
    final class Coordinator {
        weak var table: NSTableView?
        var observers: [NSObjectProtocol] = []

        func hide() {
            table?.enumerateAvailableRowViews { row, _ in
                for view in row.subviews where String(describing: type(of: view)).hasSuffix("SeparatorDrawingView") {
                    view.isHidden = true
                }
            }
        }

        deinit { observers.forEach(NotificationCenter.default.removeObserver) }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        // The table is added to the window after this view, so look it up on the next run loop.
        DispatchQueue.main.async {
            let coordinator = context.coordinator
            if coordinator.table == nil, let table = Self.findTable(in: view.window?.contentView) {
                coordinator.table = table
                let clipView = table.enclosingScrollView?.contentView
                clipView?.postsBoundsChangedNotifications = true
                // Scrolling and new rows create row views with their own separators.
                for (name, object) in [(NSView.boundsDidChangeNotification, clipView as NSView?), (NSView.frameDidChangeNotification, table)] {
                    coordinator.observers.append(NotificationCenter.default.addObserver(
                        forName: name, object: object, queue: .main
                    ) { [weak coordinator] _ in coordinator?.hide() })
                }
            }
            coordinator.hide()
        }
    }

    private static func findTable(in root: NSView?) -> NSTableView? {
        var stack = root.map { [$0] } ?? []
        while let view = stack.popLast() {
            if let table = view as? NSTableView { return table }
            stack += view.subviews
        }
        return nil
    }
}
