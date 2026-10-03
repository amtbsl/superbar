import AppKit
import Foundation

enum ModelTests {
    static func run(root: URL) throws {
        try mutationAndObservationBoundary(root: root)
        try stableOrdering(root: root)
        try shortcutValidation(root: root)
        try persistenceAndMigration(root: root)
        try startupRecovery(root: root)
        try importsAndSaveFailures(root: root)
        try discoveredIdentityMigration(root: root)
        try atomicReaders(root: root)
        print("PASS settings transactions, no-op/routine movement boundary, stable order, physical shortcut conflicts, persistence, migrations, recovery, atomic readers and failed writes")
    }

    private static func icon(_ id: String, x: CGFloat, movable: Bool = true) -> MenuBarIcon {
        MenuBarIcon(id: id, title: id, bundleID: "test.\(id)", pid: 1,
                    frame: CGRect(x: x, y: 0, width: 24, height: 24), image: nil, windowID: nil, movable: movable)
    }

    private static func mutationAndObservationBoundary(root: URL) throws {
        let url = root.appendingPathComponent("mutations/settings.json")
        let model = AppModel(settingsURL: url)
        var layouts = 0, legacyCommits = 0
        var commits: [SettingsChange] = []
        model.onPlaceIcon = { _, _ in layouts += 1 }
        model.onSettingsChanged = { legacyCommits += 1 }
        model.onSettingsCommit = { commits.append($0) }
        model.icons = [icon("c", x: 90), icon("a", x: 10), icon("b", x: 50), icon("fixed", x: 120, movable: false)]
        try expect(layouts == 0 && commits.isEmpty && legacyCommits == 0, "Native discovery records order without scheduling physical layout or a user commit")
        try expect(model.sortedIcons.map(\.id) == ["a", "b", "c", "fixed"], "First discovery adopts native left-to-right order")
        try expect(model.setVisibility("a", .hidden), "A changed hidden rule must commit")
        try expect(layouts == 1 && commits.last?.visibilityIDs == ["a"], "Only the selected icon requests one native placement, without a whole-bar layout")
        let fileAfterHide = try Data(contentsOf: url)
        let countAfterHide = commits.count
        try expect(!model.setVisibility("a", .hidden), "Assigning the same visibility must be a no-op")
        try expect(!model.updateSettings { _ in }, "An unchanged general mutation must also be a no-op")
        try expect(layouts == 1 && commits.count == countAfterHide, "Unchanged mutations must not emit callbacks")
        try expect(try Data(contentsOf: url) == fileAfterHide, "A no-op must not replace persisted settings")
        try expect(model.setVisibility("b", .alwaysHidden), "Always-hidden transition must commit")
        try expect(model.aggregateIcons.map(\.id) == ["a"], "Always-hidden items must stay out of the aggregate panel")
        try expect(model.setVisibility("fixed", .hidden), "A saved fixed-item rule may be retained")
        try expect(model.aggregateIcons.map(\.id) == ["a"], "Fixed native items must never enter the hidden aggregate")

        let layoutsBeforeSettings = layouts
        try expect(model.setMode(.normal), "Normal mode selection must persist")
        try expect(model.setTrigger(.hover), "Hover trigger selection must persist")
        try expect(model.setAutoHideDelay(999) && model.settings.autoHideDelay == 60, "Finite upper delays clamp to the supported bound")
        try expect(model.setAutoHideDelay(-99) && model.settings.autoHideDelay == 1, "Finite lower delays clamp to the supported bound")
        try expect(model.setSpacing(.compact), "Spacing preference must persist")
        try expect(model.setStatusSymbol(""), "Transparent status symbol must be a valid preference")
        try expect(model.setLaunchAtLogin(true), "Requested login setting must persist")
        try expect(model.setDiagnosticsEnabled(true), "Diagnostic preference must persist")
        let beforeShortcut = model.settings.rules
        let sortedBeforeShortcut = model.sortedIcons.map(\.id)
        try expect(model.setShortcut("c", Shortcut(keyCode: 0, modifiers: 6144, display: "⌃⌥A")), "A unique icon shortcut must commit")
        try expect(model.rule(for: "c").order == beforeShortcut["c"]?.order && model.sortedIcons.map(\.id) == sortedBeforeShortcut, "Shortcut edits preserve physical layout order")
        try expect(model.rule(for: "a") == beforeShortcut["a"] && model.rule(for: "b") == beforeShortcut["b"], "Shortcut edits must not change another icon's visibility or order")
        try expect(layouts == layoutsBeforeSettings, "Mode, reveal policy, appearance, spacing, login, diagnostics, and shortcuts schedule no physical relayout")
        try expect(commits.suffix(9).allSatisfy { !$0.requiresLayout }, "Typed ordinary-setting commits must carry no movement requirement")
        try expect(commits.last?.categories == .shortcuts && commits.last?.shortcutIDs == ["c"], "The runtime receives only the changed shortcut category")

        let callbackCount = commits.count
        let persisted = try Data(contentsOf: url)
        model.expanded = true; model.expanded = false; model.busy = true; model.busy = false
        model.accessibilityGranted = true; model.screenRecordingGranted = true
        model.icons = [icon("a", x: -10_000), icon("b", x: -12_000), icon("c", x: 60), icon("fixed", x: 140, movable: false)]
        try expect(layouts == layoutsBeforeSettings && commits.count == callbackCount, "Routine show/hide and geometry/permission observations cannot request movement")
        try expect(try Data(contentsOf: url) == persisted, "Runtime observations of known IDs do not persist user settings")
        try expect(model.sortedIcons.map(\.id) == sortedBeforeShortcut, "Hidden offscreen frames must not reorder already remembered icons")
        try expect(AppModel(settingsURL: url).settings == model.settings, "All committed user settings survive a fresh load")
    }

    private static func stableOrdering(root: URL) throws {
        let url = root.appendingPathComponent("ordering/settings.json")
        let model = AppModel(settingsURL: url)
        model.icons = [icon("a", x: 0), icon("b", x: 30), icon("c", x: 60)]
        try expect(model.updateSettings { $0.rules["offline"] = IconRule(visibility: .alwaysHidden, order: 10) }, "A disconnected saved rule must survive")
        var layouts = 0
        model.onPlaceIcon = { _, _ in layouts += 1 }
        try expect(model.reorder("c", before: "a"), "A changed drag order must commit")
        try expect(model.sortedIcons.map(\.id) == ["c", "a", "b"] && layouts == 1, "One explicit reorder must request one plan and expose the new order")
        try expect(model.disconnectedRuleIDs == ["offline"] && model.rule(for: "offline").visibility == .alwaysHidden, "Reordering live icons preserves disconnected visibility rules")
        let saved = try Data(contentsOf: url)
        try expect(!model.reorder("c", before: "a") && !model.reorder("c", before: "c"), "Adjacent and self drags must be no-ops")
        try expect(!model.reorder("absent", before: "a") && !model.reorder("c", before: "absent"), "Invalid drag endpoints must leave order untouched")
        try expect(layouts == 1 && (try Data(contentsOf: url)) == saved, "No-op reorders cannot emit moves or rewrite storage")
        try expect(model.reorder("c", after: "b"), "After-target dragging must also support actual reorder")
        try expect(model.sortedIcons.map(\.id) == ["a", "b", "c"] && layouts == 2, "After-target reorder must persist exact sequence")
        model.icons.append(icon("fixed", x: 100, movable: false))
        try expect(layouts == 2, "A newly discovered native anchor does not automatically relayout")
        try expect(!model.reorder("fixed", before: "a"), "A fixed native item cannot be a drag source")
        try expect(!model.removeSavedRule("a"), "Connected rules cannot be deleted while their icons exist")
        try expect(model.removeSavedRule("offline") && model.disconnectedRuleIDs.isEmpty, "Explicit removal of a disconnected rule must work")

        var tied = BarSettings()
        tied.rules = ["b": IconRule(order: 3), "a": IconRule(order: 3), "c": IconRule(order: 3)]
        let tiesURL = root.appendingPathComponent("ties/settings.json")
        try SettingsStore(settingsURL: tiesURL).save(tied)
        let ties = AppModel(settingsURL: tiesURL)
        ties.icons = [icon("b", x: 40), icon("c", x: 10), icon("a", x: 40), icon("b", x: 120)]
        try expect(ties.sortedIcons.map(\.id) == ["c", "a", "b"], "Legacy tied orders use measured x, then stable ID; duplicate discovery does not duplicate a row")
    }

    private static func shortcutValidation(root: URL) throws {
        let physical = Shortcut(keyCode: 0, modifiers: 6144, display: "⌃⌥A")
        let otherLabel = Shortcut(keyCode: 0, modifiers: 6144, display: "arbitrary label")
        try expect(physical.isValid && physical.matches(otherLabel) && physical.combinationID == otherLabel.combinationID, "Conflict identity must use physical key and Carbon modifiers, ignoring displayed text")
        for key in [UInt32(54), 55, 56, 57, 58, 59, 60, 61, 62, 63, 128, UInt32.max] {
            try expect(!Shortcut(keyCode: key, modifiers: 256, display: "invalid").isValid, "Modifier-only and out-of-range key codes must be rejected")
        }
        for modifiers in [UInt32(0), 1, 1024, 8192, UInt32.max] {
            try expect(!Shortcut(keyCode: 0, modifiers: modifiers, display: "invalid").isValid, "Unsupported Carbon modifier bits must be rejected")
        }
        for modifiers in [UInt32(256), 512, 2048, 4096, Shortcut.allowedModifiers] {
            try expect(Shortcut(keyCode: 0, modifiers: modifiers, display: "valid").isValid, "Supported physical modifier combinations must remain usable")
        }
        let url = root.appendingPathComponent("shortcuts/settings.json")
        let model = AppModel(settingsURL: url)
        model.icons = [icon("a", x: 0), icon("b", x: 30)]
        var layouts = 0
        model.onApplyLayout = { layouts += 1 }
        try expect(model.setShortcut("a", physical), "A unique per-icon shortcut must be saved")
        let current = model.settings
        let bytes = try Data(contentsOf: url)
        try expect(!model.setShortcut("b", otherLabel), "Identical physical combination with another label must conflict")
        try expect(!model.setToggleShortcut(otherLabel), "Global and per-icon registrations share one physical namespace")
        try expect(!model.setShortcut("b", Shortcut(keyCode: 11, modifiers: 6144, display: "different global label")), "Default global shortcut must also conflict by physical combination")
        try expect(model.settings == current && (try Data(contentsOf: url)) == bytes && layouts == 0, "Conflicting shortcuts cannot alter live state, storage, or layout")
        try expect(model.setShortcut("offline", Shortcut(keyCode: 8, modifiers: 6144, display: "⌃⌥C")), "Disconnected icons may keep their saved hotkeys")
        try expect(!model.setShortcut("b", Shortcut(keyCode: 8, modifiers: 6144, display: "C")), "Disconnected rules still reserve their physical combinations")
        try expect(model.setShortcut("a", nil) && model.setToggleShortcut(physical), "Clearing the former owner must free that combination")
        try expect(layouts == 0, "Shortcut creation/clear/reassignment must not trigger physical ordering")
        for value in [Double.nan, Double.infinity, -Double.infinity] {
            let settings = model.settings
            try expect(!model.setAutoHideDelay(value) && model.settings == settings, "Nonfinite delay edits must fail without mutating the prior configuration")
        }
    }

    private static func persistenceAndMigration(root: URL) throws {
        let url = root.appendingPathComponent("persistence/deep/settings.json")
        let store = SettingsStore(settingsURL: url)
        let missing = store.load()
        try expect(missing.settings == BarSettings() && missing.notice == nil && missing.recoveryURL == nil, "An absent settings file must have clean defaults")
        var settings = BarSettings()
        settings.mode = .normal; settings.autoHideDelay = 17; settings.toggleShortcut = nil
        settings.rules["kept"] = IconRule(visibility: .alwaysHidden, order: 7)
        try store.save(settings)
        try expect(store.load().settings == settings, "Nested storage must create its directory and round-trip all fields")
        let bytes = try Data(contentsOf: url)
        var invalid = settings; invalid.rules["kept"]?.order = -1
        try expectError("Invalid save must throw") { try store.save(invalid) }
        try expect(try Data(contentsOf: url) == bytes, "Rejected persistence must preserve the previous file bytes")
        let legacy = try store.decodeImport(Data("{}".utf8))
        try expect(legacy == BarSettings() && legacy.schemaVersion == BarSettings.currentSchemaVersion, "Sparse legacy JSON receives current safe defaults")
        let partial = try store.decodeImport(Data(#"{"toggleShortcut":null,"rules":{"kept":{"visibility":"hidden"}}}"#.utf8))
        try expect(partial.toggleShortcut == nil && partial.rules["kept"] == IconRule(visibility: .hidden), "Explicit null shortcuts and sparse legacy icon rules preserve their intent")
        try expectError("Future schemas must not be silently imported") { _ = try store.decodeImport(Data(#"{"schemaVersion":999}"#.utf8)) }
        try expectError("Invalid status symbols must not enter runtime") { _ = try store.decodeImport(Data(#"{"statusSymbol":"not-a-symbol"}"#.utf8)) }
        try expectError("Oversized imports must be rejected before decoding") { _ = try store.decodeImport(Data(repeating: 32, count: SettingsStore.maximumImportBytes + 1)) }
        var reveal = BarSettings(); reveal.mode = .normal
        for trigger in RevealTrigger.allCases { reveal.trigger = trigger; try expect(reveal.hoverRevealDelay == 0.2, "Normal mode hover is independent of aggregate trigger preference") }
        reveal.mode = .aggregate
        for trigger in [RevealTrigger.icon, .click] { reveal.trigger = trigger; try expect(reveal.hoverRevealDelay == nil, "Aggregate icon/click mode must not silently become hover mode") }
        reveal.trigger = .hover
        try expect(reveal.hoverRevealDelay == 0.5, "Aggregate hover has its own delay")
    }

    private static func startupRecovery(root: URL) throws {
        let url = root.appendingPathComponent("recovery/settings.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let store = SettingsStore(settingsURL: url)
        var broken = BarSettings(); broken.autoHideDelay = 999; broken.statusSymbol = "unknown"
        broken.toggleShortcut = Shortcut(keyCode: 54, modifiers: 256, display: "modifier")
        broken.rules["alpha"] = IconRule(visibility: .hidden, order: 10, shortcut: Shortcut(keyCode: 0, modifiers: 6144, display: "A"))
        broken.rules["beta"] = IconRule(visibility: .alwaysHidden, order: 20, shortcut: Shortcut(keyCode: 0, modifiers: 6144, display: "duplicate"))
        broken.rules["gamma"] = IconRule(visibility: .hidden, order: 30, shortcut: Shortcut(keyCode: 0, modifiers: 1, display: "invalid"))
        let original = try JSONEncoder().encode(broken)
        try original.write(to: url)
        let recovered = store.load()
        try recovered.settings.validate()
        try expect(recovered.notice != nil && recovered.recoveryURL != nil, "Repaired startup must expose its recovery state")
        try expect(recovered.settings.rules["alpha"]?.visibility == .hidden && recovered.settings.rules["beta"]?.visibility == .alwaysHidden && recovered.settings.rules["gamma"]?.order == 30, "Startup shortcut repair must retain hidden, always-hidden and disconnected ordering rules")
        try expect(recovered.settings.toggleShortcut == nil && recovered.settings.rules["alpha"]?.shortcut != nil && recovered.settings.rules["beta"]?.shortcut == nil && recovered.settings.rules["gamma"]?.shortcut == nil, "Invalid shortcuts and physical duplicates are repaired independently of visibility")
        try expect(recovered.settings.autoHideDelay == 60 && recovered.settings.statusSymbol == "menubar.rectangle", "Independent invalid scalar preferences receive safe values")
        try expect(try Data(contentsOf: url) == original, "Loading repaired settings must not overwrite the original file")
        if let backup = recovered.recoveryURL { try expect(try Data(contentsOf: backup) == original, "Recovery copy must preserve exact original bytes") }

        let corrupt = Data("not valid JSON".utf8); try corrupt.write(to: url)
        let corruptResult = store.load()
        try expect(corruptResult.settings == BarSettings() && corruptResult.recoveryURL != nil, "Unreadable JSON must fall back safely and keep evidence for recovery")
        try expect(try Data(contentsOf: url) == corrupt, "Corrupt startup file must remain intact")
        let salvage = Data(#"{"mode":"future","rules":{"kept":{"visibility":"alwaysHidden","order":7},"bad-shortcut":{"visibility":"hidden","order":2,"shortcut":"broken"}}}"#.utf8)
        try salvage.write(to: url)
        let salvaged = store.load()
        try expect(salvaged.settings.rules["kept"] == IconRule(visibility: .alwaysHidden, order: 7), "An invalid unrelated field must not erase salvageable always-hidden rules")
        try expect(salvaged.settings.rules["bad-shortcut"] == IconRule(visibility: .hidden, order: 2), "Malformed shortcut payload must not erase its icon's hidden/order settings")
    }

    private static func importsAndSaveFailures(root: URL) throws {
        let url = root.appendingPathComponent("import/settings.json")
        let model = AppModel(settingsURL: url)
        model.icons = [icon("a", x: 0)]
        try expect(model.setVisibility("a", .hidden), "Initial accepted settings must exist before testing rejection")
        var commits = 0, layouts = 0
        model.onSettingsChanged = { commits += 1 }; model.onApplyLayout = { layouts += 1 }
        let before = model.settings, file = try Data(contentsOf: url)
        let invalidImports = [Data("[]".utf8), Data(#"{"autoHideDelay":61}"#.utf8), Data(#"{"rules":{"x":{"shortcut":{"keyCode":11,"modifiers":6144,"display":"different"}}}}"#.utf8)]
        for invalid in invalidImports {
            try expectError("Invalid import must throw") { _ = try model.importSettings(from: invalid) }
            try expect(model.settings == before && (try Data(contentsOf: url)) == file && commits == 0 && layouts == 0, "A rejected import must be an atomic no-change transaction")
        }
        try expect(!(try model.importSettings(from: file)) && commits == 0 && layouts == 0, "Importing identical settings must not replay physical layout")
        let exported = root.appendingPathComponent("export/settings.json")
        try model.exportSettings(to: exported)
        try expect(try SettingsStore(settingsURL: exported).decodeImport(Data(contentsOf: exported)) == before, "Export must produce a complete independently readable settings document")
        try expect(commits == 0 && layouts == 0, "Export itself cannot request movement")
        var next = before; next.rules["a"]?.visibility = .alwaysHidden; next.mode = .normal
        try expect(try model.importSettings(from: JSONEncoder().encode(next)), "A validated changed import must commit")
        try expect(model.settings == next && commits == 1 && layouts == 0, "Multi-field import saves one settings change without taking over the mouse or replaying a layout")

        let blocked = root.appendingPathComponent("blocked-parent")
        let blocker = Data("keep this file".utf8); try blocker.write(to: blocked)
        let failed = AppModel(settingsURL: blocked.appendingPathComponent("settings.json"))
        var failedCallbacks = 0
        failed.onSettingsChanged = { failedCallbacks += 1 }; failed.onApplyLayout = { failedCallbacks += 1 }
        let old = failed.settings
        try expect(!failed.setVisibility("a", .hidden) && failed.settings == old, "Filesystem failure must retain prior live rules")
        try expect(failedCallbacks == 0 && failed.settingsIssue != nil, "Failed save must expose an issue and emit no runtime callbacks")
        try expectError("Valid import into unwritable storage must throw") { _ = try failed.importSettings(from: JSONEncoder().encode(next)) }
        try expect(failed.settings == old && failedCallbacks == 0 && (try Data(contentsOf: blocked)) == blocker, "Import write failure must retain both live state and the obstructing file")
    }

    private static func atomicReaders(root: URL) throws {
        let url = root.appendingPathComponent("atomic/settings.json")
        let store = SettingsStore(settingsURL: url)
        var initial = BarSettings(); initial.autoHideDelay = 1; initial.rules["counter"] = IconRule(order: 0)
        try store.save(initial)
        let observations = AtomicReadObservations()
        let readers = DispatchGroup()
        readers.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            defer { readers.leave() }
            for _ in 0..<1_000 {
                do {
                    let decoded = try store.decodeImport(Data(contentsOf: url))
                    if decoded.rules["counter"]?.order != Int(decoded.autoHideDelay) - 1 { observations.record("Reader observed fields from different commits") }
                } catch { observations.record("Reader observed missing or partial JSON: \(error)") }
            }
        }
        for counter in 1...40 {
            var next = initial; next.autoHideDelay = Double(counter + 1); next.rules["counter"]?.order = counter
            try store.save(next)
        }
        try expect(readers.wait(timeout: .now() + 10) == .success, "Atomic reader verification must complete promptly")
        try expect(observations.firstIssue == nil, "Concurrent independent readers must see complete settings documents: \(observations.firstIssue ?? "")")
        try expect(store.load().settings.rules["counter"]?.order == 40, "The final atomic commit must remain available")
    }

    private static func discoveredIdentityMigration(root: URL) throws {
        let url = root.appendingPathComponent("identity/settings.json")
        var saved = BarSettings()
        let originalRule = IconRule(visibility: .hidden, order: 20,
                                    shortcut: Shortcut(keyCode: 0, modifiers: 6144, display: "⌃⌥A"))
        saved.rules["legacy-id"] = originalRule
        try SettingsStore(settingsURL: url).save(saved)
        let model = AppModel(settingsURL: url)
        var callbacks = 0
        model.onSettingsChanged = { callbacks += 1 }
        model.onSettingsCommit = { _ in callbacks += 1 }
        model.onApplyLayout = { callbacks += 1 }
        model.icons = [icon("stable-id", x: 30)]
        try expect(model.newlyDiscoveredIDs == ["stable-id"] && callbacks == 0, "Identity discovery reports new IDs without scheduling native movement")
        var migrated = model.settings.rules
        migrated["stable-id"] = migrated.removeValue(forKey: "legacy-id")
        try expect(model.adoptDiscoveredRules(migrated), "An observed legacy-to-stable identity migration must save successfully")
        try expect(model.rule(for: "stable-id") == originalRule && model.settings.rules["legacy-id"] == nil, "Migration preserves hidden visibility, order and physical shortcut for the real new ID")
        try expect(model.aggregateIcons.map(\.id) == ["stable-id"] && callbacks == 0, "A migrated hidden item enters aggregate membership without synthesizing layout work")
        let bytes = try Data(contentsOf: url)
        try expect(AppModel(settingsURL: url).settings == model.settings, "Accepted identity migration must survive restart")
        try expect(!model.adoptDiscoveredRules(migrated) && (try Data(contentsOf: url)) == bytes, "An unchanged identity mapping must not rewrite its file")
        var invalid = migrated; invalid["stable-id"]?.order = -1
        try expect(!model.adoptDiscoveredRules(invalid) && model.settings.rules == migrated && callbacks == 0, "Invalid discovered migrations cannot publish state or callbacks")
        try expect(try Data(contentsOf: url) == bytes, "Invalid discovered migration cannot replace persisted rules")
        model.icons = [icon("stable-id", x: -10_000)]
        try expect(model.newlyDiscoveredIDs.isEmpty && callbacks == 0, "Subsequent refresh of a stable ID creates no repeated migration or movement")

        let blocked = root.appendingPathComponent("migration-blocked")
        try Data("obstruct directory".utf8).write(to: blocked)
        let failure = AppModel(settingsURL: blocked.appendingPathComponent("settings.json"))
        let old = failure.settings
        failure.onApplyLayout = { callbacks += 1 }; failure.onSettingsChanged = { callbacks += 1 }
        try expect(!failure.adoptDiscoveredRules(migrated) && failure.settings == old && callbacks == 0,
                   "Storage failure during discovery migration retains the live configuration and schedules no movement")
    }
}

private final class AtomicReadObservations {
    private let lock = NSLock()
    private var issue: String?
    func record(_ value: String) { lock.lock(); defer { lock.unlock() }; if issue == nil { issue = value } }
    var firstIssue: String? { lock.lock(); defer { lock.unlock() }; return issue }
}
