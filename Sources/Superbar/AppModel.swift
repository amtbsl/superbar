import AppKit
import Combine

/// User commands are transactions: validate and save before publishing a value.
/// Engine observations are independent and cannot accidentally request layout.
final class AppModel: ObservableObject {
    @Published var settings: BarSettings
    @Published var icons: [MenuBarIcon] = [] { didSet { rememberObservedOrder() } }
    @Published var accessibilityGranted = false
    @Published var screenRecordingGranted = false
    @Published var statusMessage = "准备就绪"
    @Published var expanded = false
    @Published var busy = false
    @Published var settingsIssue: String?
    @Published var loginItemState: LoginItemState = .unknown
    @Published var shortcutRegistrationIssues: [String: String] = [:]
    var onSettingsChanged: (() -> Void)?
    var onSettingsCommit: ((SettingsChange) -> Void)?
    var onRefresh: (() -> Void)?
    var onActivateIcon: ((String, Bool) -> Void)?
    var onApplyLayout: (() -> Void)?
    var onPlaceIcon: ((String, Bool) -> Void)?
    var onToggle: (() -> Void)?
    var onAggregateDismissed: (() -> Void)?
    var onRequestAccessibility: (() -> Void)?
    var onRequestScreenRecording: (() -> Void)?
    var onShowSettings: (() -> Void)?
    let settingsURL: URL
    private let store: SettingsStore
    private(set) var newlyDiscoveredIDs = Set<String>()

    init(settingsURL: URL? = nil) {
        let url = settingsURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Superbar/settings.json")
        self.settingsURL = url; store = SettingsStore(settingsURL: url)
        let loaded = store.load()
        settings = loaded.settings
        if let notice = loaded.notice { statusMessage = notice; settingsIssue = notice }
    }
    func rule(for id: String) -> IconRule { settings.rules[id] ?? IconRule(order: nextOrder) }
    private var nextOrder: Int {
        guard let last = settings.rules.values.map(\.order).max() else { return 0 }
        return last == Int.max ? Int.max : last + 1
    }
    var sortedIcons: [MenuBarIcon] {
        var seen = Set<String>()
        return icons.filter { seen.insert($0.id).inserted }.sorted { a, b in
            let x = rule(for: a.id).order, y = rule(for: b.id).order
            if x != y { return x < y }
            if a.frame.minX != b.frame.minX { return a.frame.minX < b.frame.minX }
            return a.id < b.id
        }
    }
    var aggregateIcons: [MenuBarIcon] { sortedIcons.filter { $0.movable && rule(for: $0.id).visibility == .hidden } }
    var disconnectedRuleIDs: [String] {
        let live = Set(icons.map(\.id))
        return settings.rules.keys.filter { !live.contains($0) }.sorted {
            let a = settings.rules[$0]!.order, b = settings.rules[$1]!.order
            return a == b ? $0 < $1 : a < b
        }
    }
    @discardableResult func updateSettings(_ mutation: (inout BarSettings) -> Void) -> Bool {
        var candidate = settings; mutation(&candidate)
        guard candidate.autoHideDelay.isFinite else { return reject(SettingsValidationError.invalidDelay) }
        candidate.autoHideDelay = max(1, min(60, candidate.autoHideDelay))
        do { return try commit(candidate) } catch { return reject(error) }
    }
    @discardableResult func setMode(_ value: BarMode) -> Bool { updateSettings { $0.mode = value } }
    @discardableResult func setTrigger(_ value: RevealTrigger) -> Bool { updateSettings { $0.trigger = value } }
    @discardableResult func setSpacing(_ value: IconSpacing) -> Bool { updateSettings { $0.spacing = value } }
    @discardableResult func setStatusSymbol(_ value: String) -> Bool { updateSettings { $0.statusSymbol = value } }
    @discardableResult func setLaunchAtLogin(_ value: Bool) -> Bool { updateSettings { $0.launchAtLogin = value } }
    @discardableResult func setAutoHideDelay(_ value: Double) -> Bool { updateSettings { $0.autoHideDelay = value } }
    @discardableResult func setDiagnosticsEnabled(_ value: Bool) -> Bool { updateSettings { $0.diagnosticsEnabled = value } }
    @discardableResult func setVisibility(_ id: String, _ value: IconVisibility) -> Bool {
        guard rule(for: id).visibility != value else { return false }
        var r = rule(for: id); r.visibility = value
        let saved = updateSettings { $0.rules[id] = r }
        if saved, icons.first(where: { $0.id == id })?.movable == true { onPlaceIcon?(id, false) }
        return saved
    }
    @discardableResult func setShortcut(_ id: String, _ value: Shortcut?) -> Bool {
        guard rule(for: id).shortcut != value else { return false }
        if let value, let conflict = shortcutConflict(value, excluding: id) { statusMessage = conflict; settingsIssue = conflict; return false }
        var r = rule(for: id); r.shortcut = value
        let result = updateSettings { $0.rules[id] = r }
        if result { statusMessage = value == nil ? "已清除图标快捷键" : "图标快捷键已保存" }
        return result
    }
    @discardableResult func setToggleShortcut(_ value: Shortcut?) -> Bool {
        if let value, let conflict = shortcutConflict(value, excluding: "$toggle") { statusMessage = conflict; settingsIssue = conflict; return false }
        let result = updateSettings { $0.toggleShortcut = value }
        if result { statusMessage = value == nil ? "已清除全局快捷键" : "全局快捷键已保存" }
        return result
    }
    func shortcutConflict(_ shortcut: Shortcut, excluding id: String) -> String? {
        guard shortcut.isValid else { return SettingsValidationError.invalidShortcut.errorDescription }
        if id != "$toggle", settings.toggleShortcut?.matches(shortcut) == true { return "快捷键与全局快捷键冲突" }
        if let key = settings.rules.keys.sorted().first(where: { $0 != id && settings.rules[$0]?.shortcut?.matches(shortcut) == true }) {
            let title = icons.first(where: { $0.id == key })?.title ?? "已保存的图标"
            return "快捷键已被“\(title)”占用"
        }
        return nil
    }
    @discardableResult func reorder(_ source: String, before target: String) -> Bool { move(source, relativeTo: target, after: false) }
    @discardableResult func reorder(_ source: String, after target: String) -> Bool { move(source, relativeTo: target, after: true) }
    private func move(_ source: String, relativeTo target: String, after: Bool) -> Bool {
        let original = sortedIcons.map(\.id)
        var ids = original
        guard source != target, let from = ids.firstIndex(of: source), ids.contains(target),
              icons.first(where: { $0.id == source })?.movable == true else { return false }
        ids.remove(at: from)
        guard let to = ids.firstIndex(of: target) else { return false }
        ids.insert(source, at: to + (after ? 1 : 0))
        guard ids != original else { return false }
        ids.append(contentsOf: disconnectedRuleIDs)
        let saved = updateSettings { s in
            for (i, id) in ids.enumerated() { var r = s.rules[id] ?? IconRule(); r.order = i; s.rules[id] = r }
        }
        if saved { onPlaceIcon?(source, true) }
        return saved
    }
    @discardableResult func removeSavedRule(_ id: String) -> Bool {
        guard !icons.contains(where: { $0.id == id }), settings.rules[id] != nil else { return false }
        return updateSettings { $0.rules.removeValue(forKey: id) }
    }
    @discardableResult func importSettings(from data: Data) throws -> Bool {
        let imported = try store.decodeImport(data)
        let changed = try commit(imported)
        statusMessage = changed ? "设置已导入" : "导入设置与当前设置相同"
        return changed
    }
    func exportSettings(to url: URL) throws { try SettingsStore(settingsURL: url).save(settings); statusMessage = "设置已导出" }
    func persist() { do { try store.save(settings) } catch { _ = reject(error) } }
    /// Discovery may resolve an old identity to its current stable identity.
    /// This is a storage migration and never asks the native engine to relayout.
    @discardableResult func adoptDiscoveredRules(_ rules: [String: IconRule]) -> Bool {
        var candidate = settings; candidate.rules = rules
        guard candidate != settings else { return false }
        do {
            try candidate.validate(); try store.save(candidate)
            settings = candidate
            return true
        } catch { return reject(error) }
    }
    private func rememberObservedOrder() {
        var candidate = settings
        let discovered = icons.filter { candidate.rules[$0.id] == nil }.sorted {
            $0.frame.minX == $1.frame.minX ? $0.id < $1.id : $0.frame.minX < $1.frame.minX
        }
        newlyDiscoveredIDs = Set(discovered.map(\.id))
        guard !discovered.isEmpty else { return }
        var position = nextOrder
        for icon in discovered where candidate.rules[icon.id] == nil {
            candidate.rules[icon.id] = IconRule(order: position)
            if position < Int.max { position += 1 }
        }
        _ = adoptDiscoveredRules(candidate.rules)
    }
    private func commit(_ candidate: BarSettings) throws -> Bool {
        try candidate.validate()
        guard candidate != settings else { return false }
        let change = SettingsChange(from: settings, to: candidate)
        try store.save(candidate)
        settings = candidate; settingsIssue = nil
        onSettingsCommit?(change); onSettingsChanged?()
        return true
    }
    private func reject(_ error: Error) -> Bool {
        let message = (error as? SettingsValidationError)?.errorDescription ?? "无法保存设置：\(error.localizedDescription)"
        statusMessage = message; settingsIssue = message; return false
    }
}
