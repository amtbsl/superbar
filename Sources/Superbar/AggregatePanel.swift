import AppKit
import Combine
import CoreGraphics

/// Non-activating presentation only. Passive AppKit monitors dismiss this
/// window; all native menu activation and return behavior belongs to the engine.
final class AggregatePanel: NSObject, NSWindowDelegate {
    let model: AppModel
    var anchorProvider: (() -> NSRect?)?
    /// A native blank-menu view owns its click, including toggling an already
    /// open panel. Outside-click dismissal must not race that same event.
    var revealTargetContains: ((NSPoint) -> Bool)?
    private var panel: AggregateWindow?
    private var barView: AggregateBarView?
    private let backgroundSampler = AggregateBackgroundSampler()
    private var anchor: NSRect?
    private var presentationDisplayID: CGDirectDisplayID?
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var observations = Set<AnyCancellable>()
    private var notificationTokens: [NSObjectProtocol] = []

    init(model: AppModel) {
        self.model = model
        super.init()
        model.$expanded.removeDuplicates().receive(on: RunLoop.main).sink { [weak self] expanded in
            if !expanded { self?.dismiss(notify: false) }
        }.store(in: &observations)
        model.$icons.combineLatest(model.$settings).receive(on: RunLoop.main).sink { [weak self] _, settings in
            guard let self, self.isVisible else { return }
            if settings.mode != .aggregate { self.dismiss(notify: false) }
            else { self.positionWindow() }
        }.store(in: &observations)
        notificationTokens.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            if self?.isVisible == true { self?.positionWindow() }
        })
        notificationTokens.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in self?.dismiss(notify: true) })
    }
    deinit {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        for token in notificationTokens {
            NotificationCenter.default.removeObserver(token)
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }
    }
    var isVisible: Bool { panel?.isVisible == true }
    func show(relativeTo anchor: NSRect? = nil) {
        guard Thread.isMainThread else { DispatchQueue.main.async { [weak self] in self?.show(relativeTo: anchor) }; return }
        guard model.settings.mode == .aggregate else { return }
        self.anchor = anchor ?? anchorProvider?()
        presentationDisplayID = initialScreen()?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        if panel == nil {
            let window = AggregateWindow(contentRect: NSRect(x: 0, y: 0, width: 160, height: AggregateBarMetrics.height),
                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            window.delegate = self; window.title = "Superbar 聚合栏"
            window.setAccessibilityLabel("Superbar 聚合栏")
            window.onCancel = { [weak self] in self?.hide() }
            window.isOpaque = false; window.backgroundColor = .clear; window.hasShadow = true
            window.level = .statusBar; window.hidesOnDeactivate = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            let content = AggregateBarView(onActivate: { [weak self] id, rightClick in
                    guard let self else { return }
                    self.dismiss(notify: true)
                    self.model.onActivateIcon?(id, rightClick)
                }, onSettings: { [weak self] in self?.hide(); self?.model.onShowSettings?() })
            window.contentView = content
            barView = content
            panel = window
        }
        positionWindow()
        model.expanded = true
        panel?.makeKeyAndOrderFront(nil)
        installMonitors()
    }
    func hide() {
        guard Thread.isMainThread else { DispatchQueue.main.async { [weak self] in self?.hide() }; return }
        dismiss(notify: true)
    }
    func windowWillClose(_ notification: Notification) { dismiss(notify: true) }
    private func dismiss(notify: Bool) {
        guard isVisible else { return }
        panel?.orderOut(nil); removeMonitors()
        if model.expanded { model.expanded = false }
        if notify { model.onAggregateDismissed?() }
    }
    private func positionWindow() {
        guard let panel, let screen = chosenScreen() else { return }
        let usable = screen.visibleFrame.insetBy(dx: 8, dy: 8)
        let icons = model.aggregateIcons
        let width = min(AggregateBarMetrics.preferredWidth(icons: icons), usable.width)
        let size = NSSize(width: width, height: AggregateBarMetrics.height)
        barView?.update(icons: icons, background: backgroundSampler.color(on: screen))
        panel.setContentSize(size)
        let origin = AggregatePlacement.origin(size: size, anchor: anchor, usable: usable)
        panel.setFrameOrigin(origin)
    }
    private func chosenScreen() -> NSScreen? {
        if let anchor, let screen = NSScreen.screens.first(where: { $0.frame.contains(NSPoint(x: anchor.midX, y: anchor.midY)) }) { return screen }
        if let presentationDisplayID, let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == presentationDisplayID
        }) { return screen }
        return initialScreen()
    }
    private func initialScreen() -> NSScreen? {
        if let anchor, let screen = NSScreen.screens.first(where: { $0.frame.contains(NSPoint(x: anchor.midX, y: anchor.midY)) }) { return screen }
        return NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main ?? NSScreen.screens.first
    }
    private func installMonitors() {
        removeMonitors()
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]) { [weak self] event in
            guard let self, let panel = self.panel, self.isVisible else { return event }
            if event.type == .keyDown, event.keyCode == 53, panel.isKeyWindow {
                self.hide(); return nil
            }
            if event.type != .keyDown, !panel.frame.contains(NSEvent.mouseLocation),
               self.revealTargetContains?(NSEvent.mouseLocation) != true { self.hide() }
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]) { [weak self] event in
            guard let self, let panel = self.panel, self.isVisible else { return }
            if event.type == .keyDown {
                if event.keyCode == 53 { self.hide() }
            } else if !panel.frame.contains(NSEvent.mouseLocation),
                      self.revealTargetContains?(NSEvent.mouseLocation) != true { self.hide() }
        }
    }
    private func removeMonitors() {
        if let localMonitor { NSEvent.removeMonitor(localMonitor); self.localMonitor = nil }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor); self.globalMonitor = nil }
    }
}

enum AggregatePlacement {
    static func origin(size: NSSize, anchor: NSRect?, usable: NSRect) -> NSPoint {
        let x = anchor.map { $0.midX - size.width / 2 } ?? usable.midX - size.width / 2
        var y = anchor.map { $0.minY - size.height - 8 } ?? usable.maxY - size.height
        if let anchor, y < usable.minY { y = anchor.maxY + 8 }
        return NSPoint(x: min(max(x, usable.minX), max(usable.minX, usable.maxX - size.width)),
            y: min(max(y, usable.minY), max(usable.minY, usable.maxY - size.height)))
    }
}

private final class AggregateWindow: NSPanel {
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

private enum AggregateBarMetrics {
    static let height: CGFloat = 36
    static let inset: CGFloat = 6
    static let toolWidth: CGFloat = 28
    static let emptyWidth: CGFloat = 168

    static func itemWidth(_ icon: MenuBarIcon) -> CGFloat {
        let width = icon.frame.width
        return width.isFinite && width > 0 ? ceil(min(max(width, 20), 160)) : 24
    }
    static func iconsWidth(_ icons: [MenuBarIcon]) -> CGFloat {
        icons.isEmpty ? emptyWidth : icons.reduce(0) { $0 + itemWidth($1) }
    }
    static func preferredWidth(icons: [MenuBarIcon]) -> CGFloat {
        iconsWidth(icons) + inset * 2 + toolWidth
    }
}

/// The document uses the same widths as the native status items. Its viewport
/// and trailing tool are laid out separately, so neither padding nor overflow
/// can reduce the last item's clickable area.
private final class AggregateBarView: NSVisualEffectView {
    private let scrollView = AggregateBarScrollView()
    private let document = NSView()
    private let emptyLabel = NSTextField(labelWithString: "没有隐藏的菜单栏图标")
    private let settingsButton = AggregateBarButton()
    private var buttons: [String: AggregateBarButton] = [:]
    private var icons: [MenuBarIcon] = []
    private var sampledBackground: NSColor?
    private let onActivate: (String, Bool) -> Void

    init(onActivate: @escaping (String, Bool) -> Void, onSettings: @escaping () -> Void) {
        self.onActivate = onActivate
        super.init(frame: .zero)
        material = .menu; blendingMode = .behindWindow; state = .active
        wantsLayer = true; layer?.cornerRadius = 6; layer?.masksToBounds = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasHorizontalScroller = true; scrollView.hasVerticalScroller = false
        scrollView.scrollerStyle = .overlay; scrollView.autohidesScrollers = true
        scrollView.horizontalScrollElasticity = .none; scrollView.verticalScrollElasticity = .none
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.documentView = document
        addSubview(scrollView)
        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        document.addSubview(emptyLabel)
        settingsButton.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "打开 Superbar 设置")?
            .withSymbolConfiguration(.init(pointSize: 17, weight: .regular))
        settingsButton.toolTip = "打开 Superbar 设置"
        settingsButton.setAccessibilityLabel("打开 Superbar 设置")
        settingsButton.onActivate = { _ in onSettings() }
        addSubview(settingsButton)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update(icons: [MenuBarIcon], background: NSColor?) {
        self.icons = icons
        sampledBackground = background
        let activeIDs = Set(icons.map(\.id))
        for id in Array(buttons.keys) where !activeIDs.contains(id) {
            buttons.removeValue(forKey: id)?.removeFromSuperview()
        }
        for icon in icons {
            let button = buttons[icon.id] ?? AggregateBarButton()
            if button.superview == nil { document.addSubview(button); buttons[icon.id] = button }
            button.image = MenuIconAppearance.image(for: icon)
            button.toolTip = icon.title
            button.setAccessibilityLabel(icon.title)
            button.identifier = NSUserInterfaceItemIdentifier(icon.id)
            button.onActivate = { [weak self] rightClick in self?.onActivate(icon.id, rightClick) }
        }
        // Captured glyphs keep their native colors. Match the tool/template
        // appearance to the bar behind those glyphs rather than forcing Aqua.
        if let rgb = background?.usingColorSpace(.deviceRGB) {
            let luminance = rgb.redComponent * 0.2126 + rgb.greenComponent * 0.7152 + rgb.blueComponent * 0.0722
            appearance = NSAppearance(named: luminance < 0.5 ? .darkAqua : .aqua)
        } else {
            appearance = AggregateGlyphContrast.prefersDarkBackground(icons) ? NSAppearance(named: .darkAqua) : nil
        }
        emptyLabel.isHidden = !icons.isEmpty
        needsLayout = true; needsDisplay = true
    }
    override func layout() {
        super.layout()
        let inset = AggregateBarMetrics.inset
        let width = max(0, bounds.width - inset * 2 - AggregateBarMetrics.toolWidth)
        scrollView.frame = NSRect(x: inset, y: 0, width: width, height: bounds.height)
        document.frame = NSRect(x: 0, y: 0,
            width: max(width, AggregateBarMetrics.iconsWidth(icons)), height: bounds.height)
        var x: CGFloat = 0
        for icon in icons {
            let itemWidth = AggregateBarMetrics.itemWidth(icon)
            buttons[icon.id]?.frame = NSRect(x: x, y: 0, width: itemWidth, height: bounds.height)
            x += itemWidth
        }
        emptyLabel.frame = NSRect(x: 0, y: max(0, (bounds.height - 16) / 2), width: document.bounds.width, height: 16)
        settingsButton.frame = NSRect(x: bounds.maxX - inset - AggregateBarMetrics.toolWidth,
                                     y: 0, width: AggregateBarMetrics.toolWidth, height: bounds.height)
        // Keep an existing horizontal offset within the new document extent.
        let maximumX = max(0, document.bounds.width - scrollView.contentView.bounds.width)
        let origin = scrollView.contentView.bounds.origin
        scrollView.contentView.scroll(to: NSPoint(x: min(max(origin.x, 0), maximumX), y: 0))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if let sampledBackground {
            sampledBackground.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        }
    }
}

private final class AggregateBarScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        guard let documentView, documentView.bounds.width > contentView.bounds.width else { return }
        let delta = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) ? event.scrollingDeltaX : event.scrollingDeltaY
        let maximum = max(0, documentView.bounds.width - contentView.bounds.width)
        contentView.scroll(to: NSPoint(x: min(max(contentView.bounds.minX - delta, 0), maximum), y: 0))
        reflectScrolledClipView(contentView)
    }
}

/// Ordinary AppKit button tracking stays inside the panel; no synthetic events
/// or global cursor changes are needed to select a glyph.
private final class AggregateBarButton: NSButton {
    var onActivate: ((Bool) -> Void)?
    private var hovered = false
    private var tracking: NSTrackingArea?
    override init(frame: NSRect) {
        super.init(frame: frame)
        title = ""; imagePosition = .imageOnly; imageScaling = .scaleProportionallyDown
        isBordered = false; bezelStyle = .regularSquare
        setButtonType(.momentaryChange)
        target = self; action = #selector(activate)
    }
    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    @objc private func activate() { onActivate?(NSApp.currentEvent?.modifierFlags.contains(.control) == true) }
    override func rightMouseDown(with event: NSEvent) { onActivate?(true) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        if hovered || isHighlighted {
            NSColor.labelColor.withAlphaComponent(isHighlighted ? 0.14 : 0.08).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 4), xRadius: 4, yRadius: 4).fill()
        }
        super.draw(dirtyRect)
    }
}

private enum AggregateGlyphContrast {
    static func prefersDarkBackground(_ icons: [MenuBarIcon]) -> Bool {
        var luminance: CGFloat = 0, weight: CGFloat = 0
        for icon in icons {
            guard let image = icon.image, !image.isTemplate,
                  let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }
            let bitmap = NSBitmapImageRep(cgImage: cg)
            for y in stride(from: 0, to: bitmap.pixelsHigh, by: max(1, bitmap.pixelsHigh / 8)) {
                for x in stride(from: 0, to: bitmap.pixelsWide, by: max(1, bitmap.pixelsWide / 8)) {
                    guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), color.alphaComponent > 0.4 else { continue }
                    let value = color.redComponent * 0.2126 + color.greenComponent * 0.7152 + color.blueComponent * 0.0722
                    luminance += value * color.alphaComponent; weight += color.alphaComponent
                }
            }
        }
        return weight > 0 && luminance / weight > 0.7
    }
}

/// Match the renderer's backdrop using a tiny crop of the menu background
/// window. This is permission-aware and cached, and never captures the desktop
/// or prompts for access. The native menu material is the fallback.
private final class AggregateBackgroundSampler {
    private struct Sample { let color: NSColor?; let date: Date }
    private var samples: [CGDirectDisplayID: Sample] = [:]
    func color(on screen: NSScreen) -> NSColor? {
        guard CGPreflightScreenCaptureAccess(),
              let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return nil }
        if let sample = samples[displayID], Date().timeIntervalSince(sample.date) < 5 { return sample.color }
        let color = sample(on: displayID)
        samples[displayID] = Sample(color: color, date: Date())
        return color
    }
    private func sample(on displayID: CGDirectDisplayID) -> NSColor? {
        let display = CGDisplayBounds(displayID)
        let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
        for window in windows {
            guard (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 24,
                  window[kCGWindowName as String] as? String == "Menubar",
                  let owner = window[kCGWindowOwnerName as String] as? String,
                  owner == "Window Server" || owner == "WindowServer",
                  let dictionary = window[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: dictionary as CFDictionary),
                  abs(frame.minY - display.minY) <= 4, frame.width > display.width * 0.8,
                  frame.intersects(display),
                  let number = window[kCGWindowNumber as String] as? NSNumber,
                  let id = CGWindowID(exactly: number.uint64Value) else { continue }
            let region = CGRect(x: frame.maxX - 52, y: frame.midY - 2, width: 4, height: 4).intersection(frame)
            var pointer: UnsafeRawPointer? = UnsafeRawPointer(bitPattern: UInt(id))
            guard let ids = CFArrayCreate(kCFAllocatorDefault, &pointer, 1, nil),
                  let image = CGImage(windowListFromArrayScreenBounds: region, windowArray: ids,
                                      imageOption: [.boundsIgnoreFraming, .bestResolution]) else { continue }
            let bitmap = NSBitmapImageRep(cgImage: image)
            if let color = bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.deviceRGB),
               color.alphaComponent > 0.1 { return color }
        }
        return nil
    }
}
