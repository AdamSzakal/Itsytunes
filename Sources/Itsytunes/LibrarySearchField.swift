import SwiftUI

/// The library search in the toolbar. AppKit's own search field, so it looks like `.searchable`, but it can
/// stand anywhere in the toolbar: `.searchable` is always the last item, and the filter button goes after it.
struct LibrarySearchField: NSViewRepresentable {
    @Binding var text: String
    let prompt: String

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = prompt
        // Search on every key, as `.searchable` does, and not only on Return.
        field.sendsSearchStringImmediately = true
        field.target = context.coordinator
        field.action = #selector(Coordinator.changed(_:))
        context.coordinator.focusOnFind(field)
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.text = $text
        if field.stringValue != text { field.stringValue = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject {
        var text: Binding<String>
        private var observer: Any?

        init(text: Binding<String>) {
            self.text = text
        }

        deinit {
            observer.map(NotificationCenter.default.removeObserver)
        }

        /// Typing and the clear button both send the action.
        @objc func changed(_ field: NSSearchField) {
            text.wrappedValue = field.stringValue
        }

        /// Edit > Find puts the keyboard focus in the field.
        func focusOnFind(_ field: NSSearchField) {
            observer = NotificationCenter.default.addObserver(forName: .focusLibrarySearch, object: nil, queue: .main) { [weak field] _ in
                field?.window?.makeFirstResponder(field)
            }
        }
    }
}
