import Foundation

struct SettingsLoadResult {
    let settings: BarSettings
    let notice: String?
    let recoveryURL: URL?
}

/// One storage boundary for startup, import, export and live commits.
final class SettingsStore {
    let settingsURL: URL
    static let maximumImportBytes = 2 * 1_024 * 1_024
    init(settingsURL: URL) { self.settingsURL = settingsURL }

    func load() -> SettingsLoadResult {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else {
            return SettingsLoadResult(settings: BarSettings(), notice: nil, recoveryURL: nil)
        }
        do {
            let data = try Data(contentsOf: settingsURL)
            do { return SettingsLoadResult(settings: try decodeImport(data), notice: nil, recoveryURL: nil) }
            catch {
                let decoded = (try? JSONDecoder().decode(BarSettings.self, from: data)) ?? salvage(data)
                let repaired = repair(decoded ?? BarSettings())
                let backup = preserveOriginal(data)
                let message = decoded == nil ? "设置文件无法读取，已保留原文件并使用默认设置" : "已修复无效设置，原文件已保留，菜单栏隐藏规则仍会恢复"
                return SettingsLoadResult(settings: repaired, notice: message, recoveryURL: backup)
            }
        } catch {
            return SettingsLoadResult(settings: BarSettings(), notice: "无法读取设置：\(error.localizedDescription)", recoveryURL: nil)
        }
    }
    func decodeImport(_ data: Data) throws -> BarSettings {
        guard data.count <= Self.maximumImportBytes else { throw SettingsValidationError.invalidRule }
        let settings = try JSONDecoder().decode(BarSettings.self, from: data)
        try settings.validate(); return settings
    }
    func save(_ settings: BarSettings) throws {
        try settings.validate()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(settings)
        guard data.count <= Self.maximumImportBytes else { throw SettingsValidationError.invalidRule }
        try FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: settingsURL, options: .atomic)
    }
    private func preserveOriginal(_ data: Data) -> URL? {
        let timestamp = Int(Date().timeIntervalSince1970 * 1_000)
        let url = settingsURL.deletingLastPathComponent().appendingPathComponent("settings-recovery-\(timestamp)-\(UUID().uuidString).json")
        guard !FileManager.default.fileExists(atPath: url.path) else { return nil }
        do { try data.write(to: url, options: .atomic); return url } catch { return nil }
    }
    private func repair(_ input: BarSettings) -> BarSettings {
        var settings = input
        settings.schemaVersion = BarSettings.currentSchemaVersion
        settings.autoHideDelay = settings.autoHideDelay.isFinite ? max(1, min(60, settings.autoHideDelay)) : 15
        if !BarSettings.statusSymbols.contains(settings.statusSymbol) { settings.statusSymbol = "menubar.rectangle" }
        var seen = Set<String>()
        if let shortcut = settings.toggleShortcut {
            if shortcut.isValid { seen.insert(shortcut.combinationID) } else { settings.toggleShortcut = nil }
        }
        var rules: [String: IconRule] = [:]
        for id in settings.rules.keys.sorted().prefix(10_000) {
            guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, id.utf8.count <= 1_024, !id.contains("\n") else { continue }
            var rule = settings.rules[id]!
            rule.order = max(0, rule.order)
            if let shortcut = rule.shortcut, !shortcut.isValid || !seen.insert(shortcut.combinationID).inserted { rule.shortcut = nil }
            rules[id] = rule
        }
        settings.rules = rules; return settings
    }
    private func salvage(_ data: Data) -> BarSettings? {
        guard data.count <= Self.maximumImportBytes,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        func field<T: Decodable>(_ name: String, as type: T.Type) -> T? {
            guard let raw = json[name], let bytes = try? JSONSerialization.data(withJSONObject: raw, options: .fragmentsAllowed) else { return nil }
            return try? JSONDecoder().decode(T.self, from: bytes)
        }
        var result = BarSettings()
        result.mode = field("mode", as: BarMode.self) ?? result.mode
        result.trigger = field("trigger", as: RevealTrigger.self) ?? result.trigger
        result.autoHideDelay = field("autoHideDelay", as: Double.self) ?? result.autoHideDelay
        result.statusSymbol = field("statusSymbol", as: String.self) ?? result.statusSymbol
        result.spacing = field("spacing", as: IconSpacing.self) ?? result.spacing
        result.launchAtLogin = field("launchAtLogin", as: Bool.self) ?? false
        result.diagnosticsEnabled = field("diagnosticsEnabled", as: Bool.self) ?? false
        if json["toggleShortcut"] != nil { result.toggleShortcut = field("toggleShortcut", as: Shortcut.self) }
        if let rawRules = json["rules"] as? [String: Any] {
            for (id, raw) in rawRules {
                guard let rawRule = raw as? [String: Any] else { continue }
                let visibility = (rawRule["visibility"] as? String).flatMap(IconVisibility.init(rawValue:)) ?? .visible
                let order = rawRule["order"] as? Int ?? 0
                let shortcut = rawRule["shortcut"].flatMap { try? JSONSerialization.data(withJSONObject: $0, options: .fragmentsAllowed) }
                    .flatMap { try? JSONDecoder().decode(Shortcut.self, from: $0) }
                result.rules[id] = IconRule(visibility: visibility, order: order, shortcut: shortcut)
            }
        }
        return result
    }
}
