import AppKit
import ApplicationServices

/// Native transparent menu-bar hit regions. Each panel covers only verified
/// blank space, so application menus and native extras remain ordinary system
/// windows. No global mouse event decides whether an empty area was clicked.
@MainActor final class MenuBlankRegionController {
    var onHover: ((CGPoint) -> Void)?
    var onExit: (() -> Void)?
    var onClick: ((CGPoint) -> Void)?
    private var panels: [BlankPanel] = []
    private(set) var regions: [CGRect] = []
    private var clickEnabled = false
    private var hoverEnabled = false
    private var clickEvents = 0
    private var lastClick: [String: Any] = [:]
    private var menuOwner = ""
    private var menuFrames: [CGRect] = []

    var diagnostics: [String: Any] {
        ["windows": panels.count, "regions": regions.map(MenuWindowDiscovery.components),
         "clickEnabled": clickEnabled, "hoverEnabled": hoverEnabled,
         "clickEvents": clickEvents, "lastClick": lastClick,
         "menuOwner": menuOwner, "menuFrames": menuFrames.map(MenuWindowDiscovery.components)]
    }

    func stop() {
        for panel in panels { panel.orderOut(nil); panel.contentView = nil; panel.close() }
        panels.removeAll(); regions.removeAll()
        clickEnabled = false; hoverEnabled = false
    }

    func contains(_ point: CGPoint) -> Bool {
        zip(panels, regions).contains { $0.0.isVisible && $0.1.contains(point) }
    }

    func update(control: CGRect?, nativeFrames: [CGRect], mode: BarMode,
                hover: Bool, click: Bool, enabled: Bool, accessibility: Bool) {
        hoverEnabled = enabled && hover
        clickEnabled = enabled && click
        guard hoverEnabled || clickEnabled, accessibility, let control,
              let screen = NSScreen.screens.first(where: { $0.frame.intersects(control) }),
              let menus = applicationMenuFrames(on: screen), !menus.isEmpty else {
            setRegions([]); return
        }
        let height = control.height + 0.5
        let bar = CGRect(x: screen.frame.minX, y: screen.frame.maxY - height + 0.5,
                         width: screen.frame.width, height: height)
        let left = menus.map(\.maxX).max()! - screen.frame.minX
        let extras = nativeFrames.filter {
            MenuLayoutPlanner.usable($0) && $0.intersects(bar) && $0.minX >= screen.frame.minX
                && $0.minX < screen.frame.maxX && $0.width < screen.frame.width
        }
        guard let firstExtra = extras.map(\.minX).min() else { setRegions([]); return }
        let right = screen.frame.maxX - firstExtra
        guard left > 0, right > 0 else { setRegions([]); return }
        // The original derives its left edge from menu-bar pixels. AX menu
        // bounds provide the actual application-menu edge without taking a
        // desktop image; retain its four-point space margin on the right.
        let blank = CGRect(x: bar.minX + left, y: bar.minY,
                           width: max(0, bar.width - left - right - 4), height: bar.height)
        var next = blank.width > 1 ? [blank] : []
        if mode == .aggregate, hoverEnabled, screen.safeAreaInsets.top > 0 {
            let notch = CGRect(x: bar.midX - 90, y: bar.minY, width: 180, height: bar.height)
            if !blank.contains(notch) {
                // Use native panel fragments instead of relying on wholly
                // transparent pixels in one full-width window to pass through.
                var pieces = [notch]
                for occupied in menus + extras + next {
                    pieces = pieces.flatMap { subtract(occupied, from: $0) }
                }
                next += pieces.filter { $0.width > 1 }
            }
        }
        setRegions(next)
    }

    private func applicationMenuFrames(on screen: NSScreen) -> [CGRect]? {
        // An accessory app can receive keys while another application still
        // owns the displayed menu bar. Its extras are not application menus.
        guard let app = NSWorkspace.shared.menuBarOwningApplication else { return nil }
        menuOwner = app.bundleIdentifier ?? app.localizedName ?? ""
        let application = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.04)
        guard let menu = MenuAccessibility.attribute(application, kAXMenuBarAttribute) else { return nil }
        let frames = MenuAccessibility.menuItems(menu).compactMap { item -> CGRect? in
            guard let frame = MenuAccessibility.frame(item), MenuLayoutPlanner.usable(frame),
                  frame.intersects(screen.frame), frame.maxY >= screen.frame.maxY - 64 else { return nil }
            return frame
        }
        menuFrames = frames
        return frames
    }

    private func subtract(_ occupied: CGRect, from region: CGRect) -> [CGRect] {
        guard region.intersects(occupied) else { return [region] }
        var result: [CGRect] = []
        if occupied.minX > region.minX {
            result.append(CGRect(x: region.minX, y: region.minY,
                                 width: occupied.minX - region.minX, height: region.height))
        }
        if occupied.maxX < region.maxX {
            result.append(CGRect(x: occupied.maxX, y: region.minY,
                                 width: region.maxX - occupied.maxX, height: region.height))
        }
        return result
    }

    private func setRegions(_ next: [CGRect]) {
        guard next != regions else { return }
        for panel in panels { panel.orderOut(nil); panel.contentView = nil; panel.close() }
        panels.removeAll(); regions = next
        for (index, frame) in next.enumerated() {
            let panel = BlankPanel(contentRect: frame, styleMask: [.nonactivatingPanel, .fullSizeContentView],
                                   backing: .buffered, defer: false)
            panel.identifier = NSUserInterfaceItemIdentifier("Superbar.BlankMenuRegion.\(index)")
            panel.title = "Superbar.BlankMenuRegion.\(index)"
            // The reference leaves the NSPanel's default opaque hit surface
            // enabled. Our restricted bounds preserve native click routing
            // even though the painted pixels have only 0.005 alpha.
            panel.isMovable = false; panel.isOpaque = true
            panel.backgroundColor = .clear; panel.hasShadow = false
            panel.level = NSWindow.Level(rawValue: 101)
            panel.hidesOnDeactivate = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            panel.isReleasedWhenClosed = false
            panel.acceptsMouseMovedEvents = true
            let view = BlankView(frame: CGRect(origin: .zero, size: frame.size))
            view.onHover = { [weak self] event in
                guard let self, self.hoverEnabled, !MenuPointerMonitor.synthetic(event.cgEvent),
                      event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty else { return }
                self.onHover?(NSEvent.mouseLocation)
            }
            view.onExit = { [weak self] in
                guard let self, !self.contains(NSEvent.mouseLocation) else { return }
                self.onExit?()
            }
            view.onClick = { [weak self] event in
                guard let self else { return }
                let point = event.window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
                self.clickEvents += 1
                self.lastClick = ["point": [Double(point.x), Double(point.y)],
                                  "flags": event.modifierFlags.rawValue,
                                  "synthetic": MenuPointerMonitor.synthetic(event.cgEvent)]
                guard self.clickEnabled, !MenuPointerMonitor.synthetic(event.cgEvent),
                      event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty else { return }
                self.onClick?(point)
            }
            panel.contentView = view
            panels.append(panel)
            panel.orderFrontRegardless()
        }
    }
}

private final class BlankPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor private final class BlankView: NSView {
    var onHover: ((NSEvent) -> Void)?
    var onExit: (() -> Void)?
    var onClick: ((NSEvent) -> Void)?
    private var area: NSTrackingArea?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func updateTrackingAreas() {
        if let area { removeTrackingArea(area) }
        area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways],
                              owner: self, userInfo: nil)
        if let area { addTrackingArea(area) }
        super.updateTrackingAreas()
    }
    override func draw(_ dirtyRect: NSRect) {
        // This very small alpha is the original native blank-region hit
        // surface; it is independent of the menu icons and their capture.
        NSColor.red.withAlphaComponent(0.005).setFill()
        dirtyRect.fill()
    }
    override func mouseEntered(with event: NSEvent) { onHover?(event) }
    override func mouseMoved(with event: NSEvent) { onHover?(event) }
    override func mouseExited(with event: NSEvent) { onExit?() }
    override func mouseDown(with event: NSEvent) { onClick?(event) }
}
