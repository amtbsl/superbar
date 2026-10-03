import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let superbarIcon = UTType(exportedAs: "io.github.amtbsl.superbar.icon-id", conformingTo: .plainText)
}

/// A native button preserves secondary-click behavior and keyboard activation.
/// The engine receives the icon identity, never a screenshot-derived coordinate.
struct IconActivationControl: NSViewRepresentable {
    let icon: MenuBarIcon
    var rounded: Bool = false
    let onActivate: (Bool) -> Void
    func makeNSView(context: Context) -> IconActivationButton {
        let button = IconActivationButton()
        updateNSView(button, context: context)
        return button
    }
    func updateNSView(_ button: IconActivationButton, context: Context) {
        button.image = icon.displayImage ?? NSImage(systemSymbolName: "menubar.rectangle", accessibilityDescription: icon.title)
        button.toolTip = icon.title
        button.setAccessibilityLabel(icon.title)
        button.onActivate = onActivate
        button.rounded = rounded
    }
}

final class IconActivationButton: NSButton {
    var onActivate: ((Bool) -> Void)?
    var rounded = false { didSet { updateBackground() } }
    private var tracking: NSTrackingArea?
    private var hovered = false
    override init(frame: NSRect) {
        super.init(frame: frame)
        imagePosition = .imageOnly; imageScaling = .scaleProportionallyDown
        isBordered = false; title = ""; bezelStyle = .regularSquare
        target = self; action = #selector(activate)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    @objc private func activate() {
        onActivate?(NSApp.currentEvent?.modifierFlags.contains(.control) == true)
    }
    override func rightMouseDown(with event: NSEvent) { onActivate?(true) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let tracking = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(tracking); self.tracking = tracking
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; updateBackground() }
    override func mouseExited(with event: NSEvent) { hovered = false; updateBackground() }
    private func updateBackground() {
        layer?.cornerRadius = 8
        layer?.backgroundColor = (rounded ? NSColor.controlAccentColor.withAlphaComponent(hovered ? 0.24 : 0.12) : .clear).cgColor
    }
}

struct IconDragHandle: NSViewRepresentable {
    let iconID: String
    let onBegin: () -> Void
    let onEnd: () -> Void
    func makeNSView(context: Context) -> IconDragSourceView {
        let view = IconDragSourceView(); updateNSView(view, context: context); return view
    }
    func updateNSView(_ view: IconDragSourceView, context: Context) {
        view.iconID = iconID; view.onBegin = onBegin; view.onEnd = onEnd
        view.toolTip = "拖动以调整顺序"; view.setAccessibilityLabel("拖动以调整图标顺序")
    }
}

/// Native dragging callbacks include cancellation, unlike SwiftUI's onDrag
/// start callback. No custom tracking loop or global mouse capture is needed.
final class IconDragSourceView: NSView, NSDraggingSource {
    var iconID = ""
    var onBegin: (() -> Void)?
    var onEnd: (() -> Void)?
    private var mouseDownPoint: NSPoint?
    private var dragging = false
    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.withAlphaComponent(0.65).setStroke()
        let path = NSBezierPath(); path.lineWidth = 1.2
        for offset in [-3.0, 0, 3.0] {
            path.move(to: NSPoint(x: bounds.midX - 4, y: bounds.midY + offset))
            path.line(to: NSPoint(x: bounds.midX + 4, y: bounds.midY + offset))
        }
        path.stroke()
    }
    override func mouseDown(with event: NSEvent) { mouseDownPoint = convert(event.locationInWindow, from: nil) }
    override func mouseUp(with event: NSEvent) { mouseDownPoint = nil }
    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard !dragging, let initial = mouseDownPoint, hypot(point.x - initial.x, point.y - initial.y) >= 3 else { return }
        let pasteboard = NSPasteboardItem()
        pasteboard.setString(iconID, forType: NSPasteboard.PasteboardType(UTType.superbarIcon.identifier))
        let item = NSDraggingItem(pasteboardWriter: pasteboard)
        item.setDraggingFrame(bounds, contents: NSImage(systemSymbolName: "line.3.horizontal", accessibilityDescription: nil))
        dragging = true; onBegin?()
        beginDraggingSession(with: [item], event: event, source: self)
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .move }
    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        dragging = false; mouseDownPoint = nil; onEnd?()
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
}
