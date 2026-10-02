import SwiftUI

extension View {
    /// A label under the view while the pointer is on it, styled like the Dock's. Made for toolbar controls:
    /// the toolbar would cut off a SwiftUI overlay, so the label is a small window of its own.
    func tooltip(_ text: String) -> some View {
        tooltip(segments: [text])
    }

    /// One label per equal part of the view, such as the segments of a segmented picker.
    func tooltip(segments: [String]) -> some View {
        modifier(TooltipModifier(texts: segments))
    }
}

private struct TooltipModifier: ViewModifier {
    let texts: [String]
    /// The AppKit view behind the content, to find where it is on the screen.
    @State private var anchor = Anchor()

    final class Anchor {
        weak var view: NSView?
    }

    func body(content: Content) -> some View {
        content
            .background(AnchorView(anchor: anchor))
            .onContinuousHover { phase in
                switch phase {
                case .active(let location): show(at: location)
                case .ended: TooltipPanel.shared.hide()
                }
            }
    }

    private func show(at location: CGPoint) {
        guard let view = anchor.view, let window = view.window, !texts.isEmpty, view.bounds.width > 0 else { return }
        let width = view.bounds.width / CGFloat(texts.count)
        let segment = min(max(Int(location.x / width), 0), texts.count - 1)
        let rect = NSRect(x: width * CGFloat(segment), y: 0, width: width, height: view.bounds.height)
        TooltipPanel.shared.show(texts[segment], below: window.convertToScreen(view.convert(rect, to: nil)))
    }

    private struct AnchorView: NSViewRepresentable {
        let anchor: Anchor

        func makeNSView(context: Context) -> NSView {
            let view = NSView()
            anchor.view = view
            return view
        }

        func updateNSView(_ view: NSView, context: Context) {}
    }
}

/// The one window that shows the labels.
@MainActor
private final class TooltipPanel {
    static let shared = TooltipPanel()

    private let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
    private let host = NSHostingView(rootView: TooltipBubble())
    private var shown: (text: String, rect: NSRect)?
    private var pending: Task<Void, Never>?
    private var hiddenAt = Date.distantPast
    /// After a click, until the pointer leaves the control: the control's sheet or menu takes over.
    private var suppressed = false
    private var mouseMonitor: Any?

    private init() {
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false // the bubble draws its own, which follows the arrow
        panel.ignoresMouseEvents = true
        panel.level = .statusBar // above the toolbar
        panel.contentView = host
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { event in
            MainActor.assumeIsolated {
                TooltipPanel.shared.hide()
                TooltipPanel.shared.suppressed = true
            }
            return event
        }
    }

    func show(_ text: String, below rect: NSRect) {
        guard !suppressed, shown?.text != text || shown?.rect != rect else { return }
        shown = (text, rect)
        pending?.cancel()
        // As with system tooltips: a short wait for the first label, none when moving from one control to the next.
        let wait = panel.isVisible || Date().timeIntervalSince(hiddenAt) < 0.5 ? 0 : 0.5
        pending = Task { [weak self] in
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            guard let self, !Task.isCancelled else { return }
            host.rootView = TooltipBubble(text: text)
            let size = host.fittingSize
            // Centered under the control, but kept on the screen; the arrow still points at the control.
            var x = rect.midX - size.width / 2
            if let screen = NSScreen.screens.first(where: { $0.frame.intersects(rect) })?.visibleFrame {
                x = min(max(x, screen.minX - TooltipBubble.margin + 4), screen.maxX - size.width + TooltipBubble.margin - 4)
            }
            host.rootView = TooltipBubble(text: text, arrowOffset: rect.midX - (x + size.width / 2))
            panel.setFrame(NSRect(x: x, y: rect.minY - size.height + TooltipBubble.margin - 2, width: size.width, height: size.height), display: true)
            panel.orderFront(nil)
        }
    }

    func hide() {
        pending?.cancel()
        if panel.isVisible { hiddenAt = Date() }
        panel.orderOut(nil)
        shown = nil
        suppressed = false
    }
}

/// Rounded label with an arrow on top, in the window color, like the Dock's labels.
private struct TooltipBubble: View {
    var text = ""
    var arrowOffset: CGFloat = 0
    /// Room around the bubble for its shadow.
    static let margin: CGFloat = 10

    var body: some View {
        let shape = Bubble(arrowOffset: arrowOffset)
        Text(text)
            .font(.system(size: 13))
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .padding(.top, Bubble.arrowHeight)
            .background(shape.fill(Color(nsColor: .windowBackgroundColor)))
            .overlay(shape.stroke(.primary.opacity(0.25), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.3), radius: 6, y: 2)
            .padding(Self.margin)
            .fixedSize()
    }

    private struct Bubble: Shape {
        static let arrowHeight: CGFloat = 7
        var arrowOffset: CGFloat

        /// One outline, so the stroke has no line between the arrow and the box.
        func path(in r: CGRect) -> Path {
            let top = r.minY + Self.arrowHeight
            let x = r.midX + arrowOffset
            let radius: CGFloat = 7
            return Path { p in
                p.move(to: CGPoint(x: r.minX + radius, y: top))
                p.addLine(to: CGPoint(x: x - Self.arrowHeight, y: top))
                p.addLine(to: CGPoint(x: x, y: r.minY))
                p.addLine(to: CGPoint(x: x + Self.arrowHeight, y: top))
                p.addArc(tangent1End: CGPoint(x: r.maxX, y: top), tangent2End: CGPoint(x: r.maxX, y: r.maxY), radius: radius)
                p.addArc(tangent1End: CGPoint(x: r.maxX, y: r.maxY), tangent2End: CGPoint(x: r.minX, y: r.maxY), radius: radius)
                p.addArc(tangent1End: CGPoint(x: r.minX, y: r.maxY), tangent2End: CGPoint(x: r.minX, y: top), radius: radius)
                p.addArc(tangent1End: CGPoint(x: r.minX, y: top), tangent2End: CGPoint(x: r.maxX, y: top), radius: radius)
                p.closeSubpath()
            }
        }
    }
}
