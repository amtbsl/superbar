import AppKit

/// Owns only Superbar's three NSStatusItems. Routine presentation changes
/// resize these items; this class has no event delivery or layout requester.
@MainActor final class MenuSeparatorController: NSObject {
    struct PositionCheckpoint { let values: [String: Double] }
    var onToggle: (() -> Void)?
    var onSettings: (() -> Void)?
    var rendererProvider: ((NSStatusItem) -> MenuWindowDiscovery.Window?)?
    private(set) var main: NSStatusItem?
    private(set) var hidden: NSStatusItem?
    private(set) var alwaysHidden: NSStatusItem?
    private let bar = NSStatusBar.system
    private var editing = false
    private let checkpointKey = "Superbar.NativeDividerPositions.v2"
    private var savedPositions: [String: Double] = [:]

    func start(symbol: String) {
        guard main == nil else { return }
        savedPositions = UserDefaults.standard.dictionary(forKey: checkpointKey)?.compactMapValues { ($0 as? NSNumber)?.doubleValue } ?? [:]
        let control = bar.statusItem(withLength: NSStatusItem.variableLength)
        control.autosaveName = "com.superbar.main-status-item"
        control.behavior = []
        control.isVisible = true
        control.button?.target = self
        control.button?.action = #selector(pressed(_:))
        control.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        control.button?.toolTip = "Superbar · 右键打开设置"
        main = control
        hidden = makeSeparator(name: "com.superbar.hidden-separator")
        alwaysHidden = makeSeparator(name: "com.superbar.always-hidden-separator")
        updateSymbol(symbol)
    }

    func stop() {
        // Release the wide spacers synchronously before removing them.
        setLengths(.init(hidden: 0, alwaysHidden: 0))
        let positions = positionCheckpoint()
        for item in [main, hidden, alwaysHidden].compactMap({ $0 }) { bar.removeStatusItem(item) }
        for (name, position) in positions.values { writePosition(position, name: name) }
        main = nil; hidden = nil; alwaysHidden = nil
        editing = false
    }

    func updateSymbol(_ symbol: String) {
        guard let main, let button = main.button else { return }
        button.title = ""
        if symbol.isEmpty {
            button.image = nil
            main.length = 18
        } else {
            let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Superbar")
                ?? NSImage(systemSymbolName: "menubar.rectangle", accessibilityDescription: "Superbar")
            image?.isTemplate = true
            button.image = image
            button.imagePosition = .imageOnly
            main.length = NSStatusItem.variableLength
        }
    }

    func present(_ state: MenuSeparatorPolicy.State) {
        if editing != state.editing {
            editing = state.editing
            for item in [hidden, alwaysHidden].compactMap({ $0 }) {
                item.button?.isEnabled = editing
                item.button?.isTransparent = !editing
                item.button?.alphaValue = editing ? 1 : 0
                item.button?.title = editing ? "│" : ""
            }
        }
        if state.editing || !state.layoutReady {
            // Small temporary boundaries make startup verification and an
            // explicit layout possible. No native item is pushed offscreen.
            setLengths(MenuSeparatorPolicy.lengths(for: state))
            setVisible(hidden, true); setVisible(alwaysHidden, true)
        } else {
            let lengths = MenuSeparatorPolicy.lengths(for: state)
            hidden?.length = MenuSeparatorPolicy.concealed
            alwaysHidden?.length = MenuSeparatorPolicy.concealed
            // iBar's macOS 26 native mechanism: fixed wide NSStatusItems are
            // removed/reinserted without synthesizing pointer input.
            setVisible(hidden, lengths.hidden == MenuSeparatorPolicy.concealed)
            setVisible(alwaysHidden, lengths.alwaysHidden == MenuSeparatorPolicy.concealed)
        }
    }

    var frameSnapshot: [String: [Double]] {
        var result: [String: [Double]] = [:]
        for (name, item) in [("main", main), ("hidden", hidden), ("alwaysHidden", alwaysHidden)] {
            if let item, item.isVisible, let frame = frame(for: item) {
                result[name] = MenuWindowDiscovery.components(frame)
            }
        }
        return result
    }
    var positionSnapshot: [String: Any] {
        var result: [String: Any] = [:]
        for (label, item) in [("main", main), ("hidden", hidden), ("alwaysHidden", alwaysHidden)] {
            guard let item, let name = item.autosaveName else { continue }
            var value: [String: Any] = ["autosaveName": name, "visible": item.isVisible, "length": item.length]
            if let current = UserDefaults.standard.object(forKey: positionKey(name)) as? NSNumber {
                value["currentPreferredPosition"] = current.doubleValue
            }
            if let saved = savedPositions[name] { value["savedPreferredPosition"] = saved }
            if let renderer = rendererProvider?(item) {
                value["rendererWindowID"] = renderer.id
                value["rendererPID"] = renderer.pid
                value["rendererFrame"] = MenuWindowDiscovery.components(renderer.frame)
            }
            result[label] = value
        }
        return result
    }
    var frames: [MenuLayoutPlanner.Token: CGRect] {
        var result: [MenuLayoutPlanner.Token: CGRect] = [:]
        for (token, item) in [(MenuLayoutPlanner.Token.control, main), (.hiddenSeparator, hidden), (.alwaysHiddenSeparator, alwaysHidden)] {
            if let item, item.isVisible, let frame = frame(for: item) { result[token] = frame }
        }
        return result
    }
    func item(for token: MenuLayoutPlanner.Token) -> NSStatusItem? {
        switch token {
        case .control: return main
        case .hiddenSeparator: return hidden
        case .alwaysHiddenSeparator: return alwaysHidden
        case .icon: return nil
        }
    }
    private func frame(for item: NSStatusItem) -> CGRect? {
        rendererProvider?(item)?.frame ?? MenuWindowDiscovery.statusFrame(item)
    }
    private func makeSeparator(name: String) -> NSStatusItem {
        if let position = savedPositions[name] { writePosition(position, name: name) }
        let item = bar.statusItem(withLength: MenuSeparatorPolicy.concealed)
        item.autosaveName = name
        item.length = MenuSeparatorPolicy.collapsed
        item.behavior = []
        item.isVisible = true
        item.button?.isEnabled = false
        item.button?.isTransparent = true
        item.button?.alphaValue = 0
        return item
    }
    func positionCheckpoint() -> PositionCheckpoint {
        var values = savedPositions
        for item in [main, hidden, alwaysHidden].compactMap({ $0 }) {
            guard let name = item.autosaveName else { continue }
            if let value = UserDefaults.standard.object(forKey: positionKey(name)) as? NSNumber {
                values[name] = value.doubleValue
            }
        }
        return PositionCheckpoint(values: values)
    }
    func rememberPositions() {
        savedPositions = positionCheckpoint().values
        UserDefaults.standard.set(savedPositions, forKey: checkpointKey)
    }
    /// Automatic return reenters the system layout at a saved native position.
    /// There is no synthetic restore of the previously activated icon.
    func restorePositions(_ checkpoint: PositionCheckpoint, section: IconVisibility) {
        let item = section == .alwaysHidden ? alwaysHidden : hidden
        guard let item, let name = item.autosaveName else { return }
        let position: Double?
        if section == .hidden, let mainName = main?.autosaveName {
            // The original PositionItem-0 follows the MAIN status item's
            // preferred position, rather than the wide divider's position.
            position = checkpoint.values[mainName] ?? preferredPosition(mainName) ?? savedPositions[mainName]
        } else { position = checkpoint.values[name] ?? savedPositions[name] }
        item.isVisible = false
        if let position { writePosition(position, name: name); savedPositions[name] = position }
        item.isVisible = true
    }
    private func setVisible(_ item: NSStatusItem?, _ visible: Bool) {
        guard let item, item.isVisible != visible, let name = item.autosaveName else { return }
        let position: Double?
        if item === hidden, !editing, let mainName = main?.autosaveName {
            position = preferredPosition(mainName) ?? savedPositions[mainName]
        } else { position = preferredPosition(name) ?? savedPositions[name] }
        // Removing a status item can clear its autosaved position. Preserve
        // it while removed, and write BEFORE reinsertion: the native system
        // reads preferred position when isVisible changes back to true.
        if !visible { item.isVisible = false }
        if let position { writePosition(position, name: name); savedPositions[name] = position }
        if visible { item.isVisible = true }
    }
    private func positionKey(_ name: String) -> String { "NSStatusItem Preferred Position \(name)" }
    private func preferredPosition(_ name: String) -> Double? {
        (UserDefaults.standard.object(forKey: positionKey(name)) as? NSNumber)?.doubleValue
    }
    private func writePosition(_ value: Double, name: String) { UserDefaults.standard.set(value, forKey: positionKey(name)) }
    private func setLengths(_ lengths: MenuSeparatorPolicy.Lengths) {
        if hidden?.length != lengths.hidden { hidden?.length = lengths.hidden }
        if alwaysHidden?.length != lengths.alwaysHidden { alwaysHidden?.length = lengths.alwaysHidden }
    }
    @objc private func pressed(_ sender: Any?) {
        if NSApp.currentEvent?.type == .rightMouseUp || NSApp.currentEvent?.modifierFlags.contains(.control) == true {
            onSettings?()
        } else { onToggle?() }
    }
}
