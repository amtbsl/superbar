import AppKit

enum BarMode: String, Codable, CaseIterable { case aggregate, normal }
enum RevealTrigger: String, Codable, CaseIterable { case icon, click, hover }
enum IconVisibility: String, Codable, CaseIterable { case visible, hidden, alwaysHidden }
enum IconSpacing: String, Codable, CaseIterable { case standard, compact, small, none }

struct Shortcut: Codable, Equatable, Hashable {
    static let allowedModifiers: UInt32 = 256 | 512 | 2048 | 4096
    private static let modifierKeyCodes: Set<UInt32> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]
    var keyCode: UInt32
    var modifiers: UInt32
    var display: String
    var isValid: Bool {
        keyCode <= 127 && !Self.modifierKeyCodes.contains(keyCode)
            && modifiers != 0 && modifiers & ~Self.allowedModifiers == 0
    }
    func matches(_ other: Shortcut) -> Bool { keyCode == other.keyCode && modifiers == other.modifiers }
    var combinationID: String { "\(keyCode):\(modifiers)" }
}

enum SettingsValidationError: Error, Equatable, LocalizedError {
    case invalidShortcut, duplicateShortcut, invalidDelay, invalidRule, unsupportedVersion, invalidSymbol
    var errorDescription: String? {
        switch self {
        case .invalidShortcut: return "快捷键需要一个有效按键和至少一个修饰键。"
        case .duplicateShortcut: return "设置中有重复的快捷键组合。"
        case .invalidDelay: return "自动隐藏时间必须在 1 到 60 秒之间。"
        case .invalidRule: return "菜单栏图标规则格式无效。"
        case .unsupportedVersion: return "此设置文件来自更新的 Superbar 版本。"
        case .invalidSymbol: return "菜单栏图标样式无效。"
        }
    }
}

struct IconRule: Codable, Equatable {
    var visibility: IconVisibility = .visible
    var order: Int = 0
    var shortcut: Shortcut? = nil
    init(visibility: IconVisibility = .visible, order: Int = 0, shortcut: Shortcut? = nil) {
        self.visibility = visibility; self.order = order; self.shortcut = shortcut
    }
    private enum CodingKeys: String, CodingKey { case visibility, order, shortcut }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        visibility = try c.decodeIfPresent(IconVisibility.self, forKey: .visibility) ?? .visible
        order = try c.decodeIfPresent(Int.self, forKey: .order) ?? 0
        shortcut = try c.decodeIfPresent(Shortcut.self, forKey: .shortcut)
    }
}

/// Flat, versioned wire format. Runtime observations never enter this value.
struct BarSettings: Codable, Equatable {
    static let currentSchemaVersion = 1
    static let statusSymbols = ["", "menubar.rectangle", "square.grid.2x2.fill", "circle.grid.3x3.fill", "line.3.horizontal", "sparkles"]
    var schemaVersion = currentSchemaVersion
    var mode: BarMode = .aggregate
    var trigger: RevealTrigger = .icon
    var autoHideDelay: Double = 15
    var statusSymbol: String = "menubar.rectangle"
    var spacing: IconSpacing = .standard
    var launchAtLogin = false
    var diagnosticsEnabled = false
    var toggleShortcut: Shortcut? = Shortcut(keyCode: 11, modifiers: 6144, display: "⌃⌥B")
    var rules: [String: IconRule] = [:]
    var hoverRevealDelay: TimeInterval? { mode == .normal ? 0.2 : (trigger == .hover ? 0.5 : nil) }
    init() {}
    private enum CodingKeys: String, CodingKey {
        case schemaVersion, mode, trigger, autoHideDelay, statusSymbol, spacing, launchAtLogin, diagnosticsEnabled, toggleShortcut, rules
    }
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? Self.currentSchemaVersion
        mode = try c.decodeIfPresent(BarMode.self, forKey: .mode) ?? mode
        trigger = try c.decodeIfPresent(RevealTrigger.self, forKey: .trigger) ?? trigger
        autoHideDelay = try c.decodeIfPresent(Double.self, forKey: .autoHideDelay) ?? autoHideDelay
        statusSymbol = try c.decodeIfPresent(String.self, forKey: .statusSymbol) ?? statusSymbol
        spacing = try c.decodeIfPresent(IconSpacing.self, forKey: .spacing) ?? spacing
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? launchAtLogin
        diagnosticsEnabled = try c.decodeIfPresent(Bool.self, forKey: .diagnosticsEnabled) ?? false
        if c.contains(.toggleShortcut) { toggleShortcut = try c.decodeIfPresent(Shortcut.self, forKey: .toggleShortcut) }
        rules = try c.decodeIfPresent([String: IconRule].self, forKey: .rules) ?? [:]
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encode(mode, forKey: .mode); try c.encode(trigger, forKey: .trigger)
        try c.encode(autoHideDelay, forKey: .autoHideDelay); try c.encode(statusSymbol, forKey: .statusSymbol)
        try c.encode(spacing, forKey: .spacing); try c.encode(launchAtLogin, forKey: .launchAtLogin)
        try c.encode(diagnosticsEnabled, forKey: .diagnosticsEnabled)
        // Missing means legacy default; null deliberately disables the shortcut.
        try c.encode(toggleShortcut, forKey: .toggleShortcut)
        try c.encode(rules, forKey: .rules)
    }
    func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion else { throw SettingsValidationError.unsupportedVersion }
        guard autoHideDelay.isFinite, (1...60).contains(autoHideDelay) else { throw SettingsValidationError.invalidDelay }
        guard Self.statusSymbols.contains(statusSymbol) else { throw SettingsValidationError.invalidSymbol }
        guard rules.count <= 10_000, rules.allSatisfy({ id, rule in
            !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && id.utf8.count <= 1_024
                && !id.contains("\n") && rule.order >= 0
        }) else { throw SettingsValidationError.invalidRule }
        var seen = Set<String>()
        for s in ([toggleShortcut] + rules.keys.sorted().map { rules[$0]?.shortcut }).compactMap({ $0 }) {
            guard s.isValid else { throw SettingsValidationError.invalidShortcut }
            guard seen.insert(s.combinationID).inserted else { throw SettingsValidationError.duplicateShortcut }
        }
    }
}

struct SettingsChange: Equatable {
    struct Categories: OptionSet, Equatable {
        let rawValue: UInt16
        static let mode = Self(rawValue: 1 << 0)
        static let revealPolicy = Self(rawValue: 1 << 1)
        static let appearance = Self(rawValue: 1 << 2)
        static let spacing = Self(rawValue: 1 << 3)
        static let login = Self(rawValue: 1 << 4)
        static let diagnostics = Self(rawValue: 1 << 5)
        static let shortcuts = Self(rawValue: 1 << 6)
        static let visibility = Self(rawValue: 1 << 7)
        static let ordering = Self(rawValue: 1 << 8)
    }
    let categories: Categories
    let visibilityIDs: Set<String>
    let orderIDs: Set<String>
    let shortcutIDs: Set<String>
    var requiresLayout: Bool { !visibilityIDs.isEmpty || !orderIDs.isEmpty }
    var isEmpty: Bool { categories.isEmpty }
    init(from old: BarSettings, to new: BarSettings) {
        var categories: Categories = []
        if old.mode != new.mode { categories.insert(.mode) }
        if old.trigger != new.trigger || old.autoHideDelay != new.autoHideDelay { categories.insert(.revealPolicy) }
        if old.statusSymbol != new.statusSymbol { categories.insert(.appearance) }
        if old.spacing != new.spacing { categories.insert(.spacing) }
        if old.launchAtLogin != new.launchAtLogin { categories.insert(.login) }
        if old.diagnosticsEnabled != new.diagnosticsEnabled { categories.insert(.diagnostics) }
        if old.toggleShortcut != new.toggleShortcut { categories.insert(.shortcuts) }
        var visibilityIDs = Set<String>(), orderIDs = Set<String>(), shortcutIDs = Set<String>()
        func defaultOrder(_ s: BarSettings) -> Int {
            guard let maximum = s.rules.values.map(\.order).max() else { return 0 }
            return maximum == Int.max ? Int.max : maximum + 1
        }
        for id in Set(old.rules.keys).union(new.rules.keys) {
            let a = old.rules[id] ?? IconRule(order: defaultOrder(old)), b = new.rules[id] ?? IconRule(order: defaultOrder(new))
            if a.visibility != b.visibility { visibilityIDs.insert(id) }
            if a.order != b.order { orderIDs.insert(id) }
            if a.shortcut != b.shortcut { shortcutIDs.insert(id) }
        }
        if !visibilityIDs.isEmpty { categories.insert(.visibility) }
        if !orderIDs.isEmpty { categories.insert(.ordering) }
        if !shortcutIDs.isEmpty { categories.insert(.shortcuts) }
        self.categories = categories; self.visibilityIDs = visibilityIDs
        self.orderIDs = orderIDs; self.shortcutIDs = shortcutIDs
    }
}

struct MenuBarIcon: Identifiable {
    var id: String
    var title: String
    var bundleID: String
    var pid: pid_t
    var frame: CGRect
    var image: NSImage?
    var windowID: CGWindowID?
    var movable: Bool = true
    var displayImage: NSImage? { MenuIconAppearance.image(for: self) }
}

/// A missing capture must not turn all distinct system menu items into the
/// Control Center application icon. Semantic fallbacks remain placeholders;
/// a captured native glyph always takes precedence.
enum MenuIconAppearance {
    static func image(for icon: MenuBarIcon) -> NSImage? {
        if let image = icon.image { return image }
        let symbol: String?
        if icon.bundleID == "com.apple.controlcenter" {
            switch icon.id.components(separatedBy: "|").last {
            case "com.apple.menuextra.sound": symbol = "speaker.wave.2"
            case "com.apple.menuextra.display": symbol = "display"
            case "com.apple.menuextra.wifi": symbol = "wifi"
            case "com.apple.menuextra.battery": symbol = "battery.100"
            case "com.apple.menuextra.focusmode": symbol = "moon"
            case "com.apple.menuextra.now-playing": symbol = "play.circle"
            case "com.apple.menuextra.controlcenter": symbol = "switch.2"
            case "com.apple.menuextra.clock": symbol = "clock"
            default: symbol = "menubar.rectangle"
            }
        } else if icon.bundleID == "com.apple.Spotlight" {
            symbol = "magnifyingglass"
        } else if icon.bundleID == "com.apple.TextInputMenuAgent" {
            symbol = "character"
        } else { symbol = nil }
        if let symbol {
            let image = NSImage(systemSymbolName: symbol, accessibilityDescription: icon.title)
            image?.isTemplate = true
            return image
        }
        return NSRunningApplication(processIdentifier: icon.pid)?.icon
    }
}

enum LoginItemState: Equatable { case unknown, enabled, disabled, requiresApproval, unavailable(String) }
