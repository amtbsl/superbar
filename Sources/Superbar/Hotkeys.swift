import AppKit
import Carbon.HIToolbox

extension Notification.Name {
    static let superbarShortcutRecordingDidChange = Notification.Name("SuperbarShortcutRecordingDidChange")
}

/// Registers only changed bindings. A refresh cannot briefly unregister an
/// unrelated shortcut, and recording suspends Carbon while a local control owns
/// keyboard focus. Carbon receives key combinations, not a global event tap.
@MainActor final class HotkeyManager {
    typealias Reporter = (String) -> Void
    private struct Key: Hashable { let keyCode: UInt32; let modifiers: UInt32 }
    private struct Binding { let key: Key; let action: () -> Void }
    private struct Registration { let id: UInt32; let key: Key; let ref: EventHotKeyRef }
    private static let signature: OSType = 0x5350_484B
    private let report: Reporter
    private let onIssue: ((String, String?) -> Void)?
    private var eventHandler: EventHandlerRef?
    private var recordingObserver: NSObjectProtocol?
    private var recordingTokens = Set<String>()
    private var registrations: [String: Registration] = [:]
    private var desired: [String: Binding] = [:]
    private var actions: [UInt32: () -> Void] = [:]
    private var nextID: UInt32 = 1
    private var started = false

    init(report: @escaping Reporter, onIssue: ((String, String?) -> Void)? = nil) {
        self.report = report; self.onIssue = onIssue
    }
    deinit {
        for registration in registrations.values { _ = UnregisterEventHotKey(registration.ref) }
        if let eventHandler { _ = RemoveEventHandler(eventHandler) }
        if let recordingObserver { NotificationCenter.default.removeObserver(recordingObserver) }
    }
    func start() {
        guard !started else { return }
        var eventSpec = EventTypeSpec(eventClass: UInt32(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), superbarCarbonHotkeyHandler, 1, &eventSpec,
            Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
        guard status == noErr else { report("全局快捷键监听安装失败（\(status)）"); return }
        started = true
        recordingObserver = NotificationCenter.default.addObserver(forName: .superbarShortcutRecordingDidChange, object: nil, queue: .main) { [weak self] notification in
            guard let token = notification.userInfo?["token"] as? String, let active = notification.userInfo?["active"] as? Bool else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                if active { self.recordingTokens.insert(token) } else { self.recordingTokens.remove(token) }
                self.reconcile()
            }
        }
        reconcile()
    }
    func stop() {
        unregisterAll(); desired.removeAll(); recordingTokens.removeAll()
        if let eventHandler { _ = RemoveEventHandler(eventHandler); self.eventHandler = nil }
        if let recordingObserver { NotificationCenter.default.removeObserver(recordingObserver); self.recordingObserver = nil }
        started = false
    }
    func update(toggle: Shortcut?, iconShortcuts: [(id: String, shortcut: Shortcut)], onToggle: @escaping () -> Void, onIcon: @escaping (String) -> Void) {
        var next: [String: Binding] = [:], used = Set<Key>(), rejected = Set<String>()
        func add(_ name: String, _ shortcut: Shortcut, _ action: @escaping () -> Void) {
            let key = Key(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers)
            guard shortcut.isValid else { rejected.insert(name); issue(name, "快捷键组合无效"); return }
            guard used.insert(key).inserted else { rejected.insert(name); issue(name, "快捷键组合重复"); return }
            next[name] = Binding(key: key, action: action)
        }
        if let toggle { add("$toggle", toggle, onToggle) }
        for item in iconShortcuts.sorted(by: { $0.id < $1.id }) { add(item.id, item.shortcut, { onIcon(item.id) }) }
        for name in desired.keys where next[name] == nil && !rejected.contains(name) { onIssue?(name, nil) }
        desired = next
        if !started { start() } else { reconcile() }
    }
    private func reconcile() {
        guard started else { return }
        if !recordingTokens.isEmpty { unregisterAll(); return }
        for name in Array(registrations.keys) {
            guard let registration = registrations[name] else { continue }
            if desired[name]?.key != registration.key { unregister(name) }
        }
        for name in desired.keys.sorted() {
            guard let binding = desired[name] else { continue }
            if let registration = registrations[name] { actions[registration.id] = binding.action; continue }
            let id = nextID; nextID &+= 1
            if nextID == 0 { nextID = 1 }
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(binding.key.keyCode, binding.key.modifiers,
                EventHotKeyID(signature: Self.signature, id: id), GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &ref)
            guard status == noErr, let ref else {
                issue(name, status == OSStatus(eventHotKeyExistsErr) ? "快捷键已被其它应用占用" : "快捷键注册失败（\(status)）")
                continue
            }
            registrations[name] = Registration(id: id, key: binding.key, ref: ref)
            actions[id] = binding.action; onIssue?(name, nil)
        }
    }
    private func issue(_ name: String, _ message: String) {
        onIssue?(name, message)
        report(name == "$toggle" ? "全局快捷键：\(message)" : "图标快捷键：\(message)")
    }
    private func unregister(_ name: String) {
        guard let registration = registrations.removeValue(forKey: name) else { return }
        _ = UnregisterEventHotKey(registration.ref); actions.removeValue(forKey: registration.id)
    }
    private func unregisterAll() { for name in Array(registrations.keys) { unregister(name) } }
    fileprivate func invoke(signature: OSType, id: UInt32) {
        guard started, recordingTokens.isEmpty, signature == Self.signature else { return }
        actions[id]?()
    }
}

private func superbarCarbonHotkeyHandler(_ nextHandler: EventHandlerCallRef?, _ event: EventRef?, _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event, let userData else { return noErr }
    var id = EventHotKeyID(signature: 0, id: 0)
    let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
        MemoryLayout<EventHotKeyID>.size, nil, &id)
    guard status == noErr else { return status }
    let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
    let signature = id.signature, value = id.id
    Task { @MainActor in manager.invoke(signature: signature, id: value) }
    return noErr
}
