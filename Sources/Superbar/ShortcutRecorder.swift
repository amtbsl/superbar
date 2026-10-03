import AppKit
import SwiftUI

struct ShortcutRecorder: NSViewRepresentable {
    let shortcut: Shortcut?
    let placeholder: String
    let onCommit: (Shortcut?) -> Void
    func makeNSView(context: Context) -> ShortcutRecorderControl {
        let view = ShortcutRecorderControl()
        updateNSView(view, context: context)
        return view
    }
    func updateNSView(_ control: ShortcutRecorderControl, context: Context) {
        control.shortcut = shortcut; control.placeholder = placeholder; control.onCommit = onCommit
        control.refreshTitle()
    }
    static func dismantleNSView(_ control: ShortcutRecorderControl, coordinator: ()) { control.cancelRecording() }
}

/// Keyboard capture is confined to this first responder. It cancels on focus
/// loss, window dismissal or Escape; Delete clears without saving a bogus key.
final class ShortcutRecorderControl: NSButton {
    var shortcut: Shortcut?
    var placeholder = "设置"
    var onCommit: ((Shortcut?) -> Void)?
    private var recording = false
    private let token = UUID().uuidString
    private weak var previousResponder: NSResponder?
    private var resignObserver: NSObjectProtocol?

    override init(frame: NSRect) {
        super.init(frame: frame)
        title = placeholder; font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        isBordered = false; alignment = .center; bezelStyle = .regularSquare
        focusRingType = .exterior; wantsLayer = true; layer?.cornerRadius = 7
        cell?.lineBreakMode = .byTruncatingTail
        setAccessibilityRole(.button)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    deinit { if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) } }
    override var acceptsFirstResponder: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: max(88, super.intrinsicContentSize.width + 12), height: 27) }
    override func mouseDown(with event: NSEvent) {
        if recording { cancelRecording() } else { beginRecording() }
    }
    override func accessibilityPerformPress() -> Bool { beginRecording(); return true }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        cancelRecording()
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver); self.resignObserver = nil }
        super.viewWillMove(toWindow: newWindow)
        if let newWindow {
            resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: newWindow, queue: .main) { [weak self] _ in self?.cancelRecording() }
        }
    }
    override func resignFirstResponder() -> Bool {
        if recording { finish(nil, cancelled: true, restoreFocus: false) }
        return super.resignFirstResponder()
    }
    override func keyDown(with event: NSEvent) {
        if recording { capture(event) }
        else if event.keyCode == 49 || event.keyCode == 36 { beginRecording() }
        else { super.keyDown(with: event) }
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard recording, window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
        capture(event); return true
    }
    override func flagsChanged(with event: NSEvent) {
        guard recording else { super.flagsChanged(with: event); return }
        let prefix = Self.modifierDisplay(event.modifierFlags)
        title = prefix.isEmpty ? "按下组合键…" : prefix + "…"
    }
    func refreshTitle() {
        guard !recording else { return }
        title = shortcut?.display.isEmpty == false ? shortcut!.display : placeholder
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.36).cgColor
        layer?.borderColor = NSColor.black.withAlphaComponent(0.08).cgColor; layer?.borderWidth = 0.5
        toolTip = "点击后按下组合键；Escape 取消，Delete 清除"
        setAccessibilityLabel("快捷键：\(title)")
    }
    func cancelRecording() { if recording { finish(nil, cancelled: true) } }
    private func beginRecording() {
        guard !recording, let window else { return }
        previousResponder = window.firstResponder
        guard window.makeFirstResponder(self) else { return }
        recording = true; title = "按下组合键…"
        layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.2).cgColor
        setAccessibilityLabel("按下快捷键组合，Escape 取消，Delete 清除")
        notifyRecording(true)
    }
    private func capture(_ event: NSEvent) {
        let modifiers = Self.carbonModifiers(event.modifierFlags)
        if event.keyCode == 53 && modifiers == 0 { finish(nil, cancelled: true); return }
        if (event.keyCode == 51 || event.keyCode == 117) && modifiers == 0 { finish(nil, cancelled: false); return }
        let candidate = Shortcut(keyCode: UInt32(event.keyCode), modifiers: modifiers,
            display: Self.modifierDisplay(event.modifierFlags) + Self.keyDisplay(event))
        guard candidate.isValid else { title = "需要修饰键"; NSSound.beep(); return }
        finish(candidate, cancelled: false)
    }
    private func finish(_ value: Shortcut?, cancelled: Bool, restoreFocus: Bool = true) {
        guard recording else { return }
        recording = false
        if !cancelled { onCommit?(value) }
        notifyRecording(false)
        refreshTitle()
        if restoreFocus, window?.firstResponder === self { window?.makeFirstResponder(previousResponder) }
        previousResponder = nil
    }
    private func notifyRecording(_ active: Bool) {
        NotificationCenter.default.post(name: .superbarShortcutRecordingDidChange, object: self, userInfo: ["token": token, "active": active])
    }
    private static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var result: UInt32 = 0
        if flags.contains(.command) { result |= 256 }; if flags.contains(.shift) { result |= 512 }
        if flags.contains(.option) { result |= 2048 }; if flags.contains(.control) { result |= 4096 }
        return result
    }
    private static func modifierDisplay(_ flags: NSEvent.ModifierFlags) -> String {
        (flags.contains(.control) ? "⌃" : "") + (flags.contains(.option) ? "⌥" : "")
            + (flags.contains(.shift) ? "⇧" : "") + (flags.contains(.command) ? "⌘" : "")
    }
    private static func keyDisplay(_ event: NSEvent) -> String {
        let keys: [UInt16: String] = [36: "↩", 48: "⇥", 49: "空格", 51: "⌫", 53: "⎋", 76: "⌤", 117: "⌦",
            123: "←", 124: "→", 125: "↓", 126: "↑", 115: "↖", 119: "↘", 116: "⇞", 121: "⇟",
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12"]
        return keys[event.keyCode] ?? (event.charactersIgnoringModifiers?.uppercased().isEmpty == false ? event.charactersIgnoringModifiers!.uppercased() : "键 \(event.keyCode)")
    }
}
