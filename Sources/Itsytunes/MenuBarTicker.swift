import SwiftUI

/// "Artist – Title" of the playing song in the menu bar, like the Menu Bar Ticker app shows for Music and Spotify
/// (it asks only those two apps, so Itsytunes shows its own). A long text pans smoothly while playing.
/// An AppKit status item and not a `MenuBarExtra`: its label is only text, so it cannot move by less than a letter.
@MainActor
final class MenuBarTicker: NSObject, NSMenuDelegate {
    private let player: Player
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let marquee = MarqueeView()
    private var full: String?
    private var timer: Timer?
    private var visibility: NSKeyValueObservation?
    /// Set by the main window, which has the SwiftUI action that opens it again after it is closed.
    var openMainWindow: (() -> Void)?

    static let enabledKey = "showInMenuBar"
    private static var isEnabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }

    init(player: Player) {
        self.player = player
        super.init()
        item.autosaveName = "Itsytunes"
        item.behavior = .removalAllowed // ⌘-dragging it out of the menu bar turns the setting off
        item.isVisible = Self.isEnabled
        if let button = item.button {
            button.addSubview(marquee)
            marquee.frame = button.bounds
            marquee.autoresizingMask = [.width, .height]
        }
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        visibility = item.observe(\.isVisible) { item, _ in
            MainActor.assumeIsolated {
                if item.isVisible != Self.isEnabled { UserDefaults.standard.set(item.isVisible, forKey: Self.enabledKey) }
            }
        }
        // A timer and not observation: reading the player and the setting is cheap. The panning itself is Core Animation.
        timer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        tick()
    }

    private func tick() {
        if item.isVisible != Self.isEnabled { item.isVisible = Self.isEnabled }
        guard item.isVisible, let button = item.button else { return }
        let full = player.current.map { [$0.artist, $0.displayTitle].filter { !$0.isEmpty }.joined(separator: " – ") }
        if full != self.full {
            self.full = full
            button.image = full == nil ? NSImage(systemSymbolName: "music.note", accessibilityDescription: "Itsytunes") : nil
            button.setAccessibilityTitle(full)
            marquee.text = full ?? ""
            item.length = full == nil ? NSStatusItem.squareLength : marquee.width
        }
        marquee.isPanning = player.isPlaying
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(MenuItem(player.isPlaying ? "Pause" : "Play") { [player] in player.toggle() })
        menu.addItem(MenuItem("Next", enabled: player.current != nil) { [player] in player.next() })
        menu.addItem(MenuItem("Previous", enabled: player.current != nil) { [player] in player.previous() })
        menu.addItem(.separator())
        menu.addItem(MenuItem("Show Itsytunes") { [weak self] in
            self?.openMainWindow?()
            NSApp.activate()
        })
    }

    /// Gives the ticker the action that opens the main window.
    struct WindowOpener: ViewModifier {
        let ticker: MenuBarTicker
        @Environment(\.openWindow) private var openWindow

        func body(content: Content) -> some View {
            content.onAppear { ticker.openMainWindow = { openWindow(id: "main") } }
        }
    }
}

/// A menu item that runs a closure.
private final class MenuItem: NSMenuItem {
    private let run: () -> Void

    init(_ title: String, enabled: Bool = true, run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(runAction), keyEquivalent: "")
        target = self
        isEnabled = enabled
    }

    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func runAction() { run() }
}

/// The text in the status item. A text wider than `maxWidth` pans to the left and starts again after a gap.
/// Core Animation moves it at the display's frame rate (60 or 120 fps), so the app does no work per frame.
private final class MarqueeView: NSView {
    private static let maxWidth: CGFloat = 240
    private static let padding: CGFloat = 6
    /// Points per second.
    private static let speed: CGFloat = 30
    /// Between the end of a panning text and its start again.
    private static let gap: CGFloat = 40
    /// Width of the fade at each end of a panning text, from the edge of the item.
    private static let fade: CGFloat = 16

    /// Two copies side by side: when the first has moved out on the left, the second is where the first started.
    private let strip = NSView()
    private let labels = [NSTextField(labelWithString: ""), NSTextField(labelWithString: "")]
    /// Fades the text out at both ends, so it does not end in a hard cut.
    private let fadeMask = CAGradientLayer()
    private var textWidth: CGFloat = 0
    private var period: CGFloat { textWidth + Self.gap }
    private var pans: Bool { textWidth > Self.maxWidth }

    /// The status item length that fits the text.
    var width: CGFloat { min(textWidth, Self.maxWidth) + 2 * Self.padding }

    var text = "" {
        didSet {
            for label in labels { label.stringValue = text }
            textWidth = ceil(labels[0].fittingSize.width)
            labels[1].isHidden = !pans
            needsLayout = true
            updateAnimation(from: 0)
        }
    }

    var isPanning = false {
        // A paused text goes back to its start, so the start of the song name shows.
        didSet { if isPanning != oldValue { updateAnimation(from: isPanning ? nil : 0) } }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        fadeMask.startPoint = CGPoint(x: 0, y: 0.5)
        fadeMask.endPoint = CGPoint(x: 1, y: 0.5)
        fadeMask.colors = [NSColor.clear, .black, .black, .clear].map(\.cgColor)
        strip.wantsLayer = true
        addSubview(strip)
        for label in labels {
            label.font = .menuBarFont(ofSize: 0)
            label.lineBreakMode = .byClipping
            strip.addSubview(label)
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Clicks go to the status item button below, which opens the menu.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        let height = ceil(labels[0].fittingSize.height)
        let y = round((bounds.height - height) / 2)
        labels[0].frame = NSRect(x: 0, y: 0, width: textWidth, height: height)
        labels[1].frame = NSRect(x: period, y: 0, width: textWidth, height: height)
        strip.frame = NSRect(x: Self.padding, y: y, width: period + textWidth, height: height)
        // A text that fits needs no fade.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fadeMask.frame = bounds
        let edge = bounds.width > 0 ? Self.fade / bounds.width : 0
        fadeMask.locations = [0, edge, 1 - edge, 1].map { NSNumber(value: Double($0)) }
        layer?.mask = pans ? fadeMask : nil
        CATransaction.commit()
    }

    /// The status item window can be made again (for example after it is hidden), which drops running animations.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateAnimation()
    }

    /// `start` nil: from where the text is now.
    private func updateAnimation(from start: CGFloat? = nil) {
        guard let layer = strip.layer else { return }
        let shown = (layer.presentation() ?? layer).value(forKeyPath: "transform.translation.x") as? CGFloat ?? 0
        let start = start ?? (pans ? shown.truncatingRemainder(dividingBy: period) : 0)
        layer.removeAnimation(forKey: "pan")
        layer.setValue(start, forKeyPath: "transform.translation.x")
        guard isPanning, pans, window != nil else { return }
        // The text repeats every `period` points, so a loop from `start` to `start - period` has no visible jump.
        let pan = CABasicAnimation(keyPath: "transform.translation.x")
        pan.fromValue = start
        pan.toValue = start - period
        pan.duration = period / Self.speed
        pan.repeatCount = .infinity
        pan.timingFunction = CAMediaTimingFunction(name: .linear)
        pan.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        layer.add(pan, forKey: "pan")
    }
}
