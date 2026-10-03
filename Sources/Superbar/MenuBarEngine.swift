import AppKit
import ApplicationServices

/// Coordinates services, not native implementation details. Presentation,
/// observations and explicit movement have distinct entry points. There is
/// one serialized native operation and no automatic layout repair loop.
@MainActor public final class MenuBarEngine: NSObject {
    public typealias WindowMappingSnapshot = MenuWindowMappingSnapshot
    public var onShowAggregate: (() -> Void)?
    public var onHideAggregate: (() -> Void)?
    public var onShowSettings: (() -> Void)?
    public private(set) var aggregateRevealAnchor: CGRect?
    public func handlesBlankClick(at point: CGPoint) -> Bool {
        started && !editing && model.settings.mode == .aggregate && model.settings.trigger == .click
            && blankRegions.contains(point)
    }
    public var statusItemFramesSnapshot: [String: [Double]] { separators.frameSnapshot }
    public private(set) var windowMappingSnapshot: [WindowMappingSnapshot] = []
    public private(set) var layoutPassCount = 0
    public var commandDragAttempts: Int { mover.attempts }
    public private(set) var activationCount = 0
    public private(set) var lastLayoutReason = ""
    public var lastLayoutGestureResult: String { mover.lastResult }
    public var lastPointerDisplacementDuringDrag: Double? { mover.lastPointerDisplacement }
    public var resourceSnapshot: [String: Any] {
        ["started": started, "nativeOperation": operationTask != nil, "startupTask": startupTask != nil,
         "hoverTask": hoverTask != nil, "autoReturnTask": autoReturnTask != nil,
         "blankClickTask": blankClickTask != nil, "blankRegionTask": blankRegionTask != nil,
         "pollTimer": pollTimer != nil, "workspaceObservers": observers.count,
         "pendingCaptures": capture.pendingCount, "heldSyntheticButton": mover.hasHeldButton,
         "gestureCursorHidden": mover.cursorIsHidden,
         "capturePaused": capture.isPaused, "captureMode": "quartz-window-composite",
         "capture": capture.diagnostics,
         "rendererHandshakes": mover.rendererHandshakeCount,
         "lastRendererHandshakes": mover.lastRendererHandshakeCount,
         "lastNativeMovement": mover.lastMovement,
         "temporaryNativeIcons": temporaryShows.count, "layoutReady": layoutReady,
         "blankRegions": blankRegions.diagnostics,
         "hoverAwaitingExit": hoverAwaitingExit,
         "separatorPositions": separators.positionSnapshot]
    }

    private struct TemporaryShow {
        let id: String
        let windowID: CGWindowID
        let visibility: IconVisibility
        let checkpoint: MenuSeparatorController.PositionCheckpoint
    }
    let model: AppModel
    private let discovery = MenuWindowDiscovery()
    private let separators = MenuSeparatorController()
    private let pointer = MenuPointerMonitor()
    private let blankRegions = MenuBlankRegionController()
    private let capture = MenuIconCapture()
    private let preferences = MenuSystemPreferences()
    private lazy var mover = MenuNativeMover(discovery: discovery, pointer: pointer)
    private lazy var interface = MenuInterfaceMonitor(discovery: discovery)
    private var hotkeys: HotkeyManager?
    private var records: [String: MenuWindowDiscovery.Record] = [:]
    private var temporaryShows: [String: TemporaryShow] = [:]
    private var started = false
    private var layoutReady = false
    private var editing = false
    private var hoverAwaitingExit = false
    private var startupAttempted = false
    private var savedLayoutAtLaunch = false
    private var lastMode: BarMode?
    private var lastHotkeySignature = ""
    private var lifecycle = MenuOperationGeneration()
    private var operationGeneration = MenuOperationGeneration()
    private var hoverGeneration = MenuOperationGeneration()
    private var blankClickGeneration = MenuOperationGeneration()
    private var operationTask: Task<Void, Never>?
    private var startupTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var hoverTask: Task<Void, Never>?
    private var blankClickTask: Task<Void, Never>?
    private var blankRegionTask: Task<Void, Never>?
    private var autoReturnTask: Task<Void, Never>?
    private var pollTimer: Timer?
    private var observers: [NSObjectProtocol] = []

    private var previousSettings: (() -> Void)?
    private var previousCommit: ((SettingsChange) -> Void)?
    private var previousRefresh: (() -> Void)?
    private var previousActivate: ((String, Bool) -> Void)?
    private var previousApply: (() -> Void)?
    private var previousPlace: ((String, Bool) -> Void)?
    private var previousToggle: (() -> Void)?
    private var previousDismiss: (() -> Void)?
    private var previousAccessibility: (() -> Void)?
    private var previousRecording: (() -> Void)?

    init(model: AppModel) { self.model = model; super.init() }

    public func start() {
        guard !started else { return }
        started = true
        let lease = lifecycle.advance()
        startupAttempted = false
        savedLayoutAtLaunch = model.settings.rules.values.contains { $0.visibility != .visible || $0.order != 0 }
        lastMode = model.settings.mode
        wireCallbacks()
        separators.onToggle = { [weak self] in self?.toggle() }
        separators.onSettings = { [weak self] in self?.onShowSettings?() }
        separators.rendererProvider = { [weak self] item in self?.discovery.statusRenderer(item) }
        separators.start(symbol: model.settings.statusSymbol)
        pointer.onInput = { [weak self] input in self?.handleInput(input) }
        pointer.start()
        blankRegions.onHover = { [weak self] point in self?.hoverBlankRegion(at: point) }
        blankRegions.onExit = { [weak self] in
            self?.hoverTask?.cancel(); self?.hoverTask = nil; self?.hoverAwaitingExit = false
        }
        blankRegions.onClick = { [weak self] point in self?.clickBlankRegion(at: point) }
        preferences.report = { [weak self] text in self?.model.statusMessage = text }
        preferences.onLoginState = { [weak self] state in self?.model.loginItemState = state }
        preferences.start(settings: model.settings)
        capture.start()
        capture.onUpdate = { [weak self] in self?.updateCapturedImages() }
        hotkeys = HotkeyManager(report: { [weak self] text in self?.model.statusMessage = text },
                               onIssue: { [weak self] id, issue in self?.model.shortcutRegistrationIssues[id] = issue })
        hotkeys?.start()
        installObservers()
        refresh()
        updateHotkeys()
        synchronizePresentation()
        let timer = Timer(timeInterval: 7, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        pollTimer = timer
        RunLoop.main.add(timer, forMode: .common)

        // Native autosave positions restore the dividers. Launching never
        // synthesizes Command drags or repairs the whole bar under the user.
        startupTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard let self, self.started, self.lifecycle.accepts(lease), !Task.isCancelled else { return }
            self.startupTask = nil
            self.refresh()
            self.startupAttempted = true
            self.layoutReady = true
            self.synchronizePresentation()
        }
    }

    public func stop() {
        guard started else { return }
        started = false
        lifecycle.advance(); operationGeneration.advance()
        for task in [startupTask, operationTask, refreshTask, hoverTask, autoReturnTask, blankClickTask, blankRegionTask] { task?.cancel() }
        startupTask = nil; operationTask = nil; refreshTask = nil; hoverTask = nil; autoReturnTask = nil
        blankClickTask = nil; blankRegionTask = nil
        mover.cancelAndRelease()
        MenuEventDelivery.cancelAll()
        pollTimer?.invalidate(); pollTimer = nil
        pointer.stop(); pointer.onInput = nil
        blankRegions.stop(); blankRegions.onHover = nil; blankRegions.onExit = nil; blankRegions.onClick = nil
        aggregateRevealAnchor = nil
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer); NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        hotkeys?.stop(); hotkeys = nil
        capture.stop(); capture.onUpdate = nil
        separators.stop()
        separators.onToggle = nil; separators.onSettings = nil; separators.rendererProvider = nil
        temporaryShows.removeAll(); records.removeAll(); windowMappingSnapshot.removeAll()
        layoutReady = false; editing = false
        model.busy = false; model.expanded = false
        onHideAggregate?()
        unwireCallbacks()
    }

    public func toggle() {
        guard started, !editing else { return }
        blankClickTask?.cancel(); blankClickTask = nil
        aggregateRevealAnchor = nil
        setExpanded(!model.expanded)
    }

    /// Observation only: no layout request, no input synthesis and no cursor
    /// manipulation, including when captures or permissions change.
    public func refresh() {
        guard started else { return }
        model.accessibilityGranted = AXIsProcessTrusted()
        model.screenRecordingGranted = CGPreflightScreenCaptureAccess()
        preferences.observeLoginState()
        // AX and CG enumerate independently. During a native reflow their
        // geometry can describe different instants and temporarily replace
        // semantic identities with renderer-only records. Keep the operation's
        // identity snapshot until its selected gestures have finished.
        guard !model.busy, operationTask == nil else { return }
        refreshSnapshot()
    }

    private func refreshSnapshot() {
        let snapshot = discovery.snapshot(accessibility: model.accessibilityGranted,
                                          excluding: Array(separators.frames.values), previous: model.icons)
        records = Dictionary(uniqueKeysWithValues: snapshot.records.map { ($0.icon.id, $0) })
        let old = Dictionary(uniqueKeysWithValues: model.icons.map { ($0.id, $0) })
        capture.retain(windowIDs: Set(snapshot.records.compactMap { $0.icon.windowID }))
        model.icons = snapshot.records.map { record in
            var icon = record.icon
            if model.screenRecordingGranted, let window = record.renderer {
                icon.image = capture.image(windowID: window.id, frame: window.frame) ?? old[icon.id]?.image
            }
            return icon
        }
        windowMappingSnapshot = snapshot.mappings
        migrateLegacyRules()
        updateHotkeys()
        synchronizePresentation()
    }

    public func applyLayout(reason: String = "应用菜单栏布局") {
        requestLayout(trigger: .explicitApply, reason: reason)
    }
    public func activateIcon(id: String, rightClick: Bool = false) {
        guard started else { return }
        enqueueOperation { [weak self] ticket in
            await self?.executeActivation(id: id, rightClick: rightClick, ticket: ticket)
        }
    }

    private func requestLayout(trigger: MenuLayoutRequestPolicy.Trigger, reason: String) {
        guard started, MenuLayoutRequestPolicy.permits(trigger) else { return }
        if trigger == .startupRestore && !startupAttempted { return }
        startupTask?.cancel(); startupTask = nil
        enqueueOperation { [weak self] ticket in await self?.executeLayout(reason: reason, ticket: ticket) }
    }
    private func enqueueOperation(_ body: @escaping (UInt64) async -> Void) {
        startupTask?.cancel(); startupTask = nil
        let previous = operationTask
        previous?.cancel()
        mover.cancelAndRelease()
        let ticket = operationGeneration.advance()
        let lease = lifecycle.value
        operationTask = Task { [weak self] in
            if let previous { await previous.value }
            guard let self, self.started, self.lifecycle.accepts(lease), self.operationGeneration.accepts(ticket), !Task.isCancelled else { return }
            await body(ticket)
            guard self.operationGeneration.accepts(ticket) else { return }
            self.operationTask = nil
            self.model.busy = false
            self.scheduleRefresh()
        }
    }

    private func executeLayout(reason: String, ticket: UInt64) async {
        guard model.accessibilityGranted else { fail("整理布局需要辅助功能权限"); return }
        capture.pause()
        defer { capture.resume(); updateCapturedImages() }
        guard await mover.waitForQuiet(), operationGeneration.accepts(ticket), !Task.isCancelled else {
            fail("布局未执行：鼠标或快捷键正在使用中，请再次应用布局"); return
        }
        let inputGeneration = pointer.generation
        layoutPassCount += 1; lastLayoutReason = reason
        model.busy = true
        layoutReady = false; editing = true
        synchronizePresentation()
        defer {
            editing = false
            model.busy = false
            synchronizePresentation()
        }
        guard await waitForSeparatorRenderers(ticket: ticket, inputGeneration: inputGeneration) else {
            fail(Task.isCancelled || pointer.generation != inputGeneration
                 ? "布局已被用户输入中断" : "布局未执行：原生分隔项窗口尚未稳定，请再次应用布局")
            return
        }
        refreshSnapshot()
        let plan = layoutPlan()
        let initial = layoutFrames()
        let missing = MenuLayoutPlanner.verify(plan, frames: initial).missing
        guard missing.isEmpty else { fail("布局未执行：部分原生图标的窗口暂不可用，请刷新后重试"); return }
        var completedMoves = 0
        var verified = false
        // Explicit Apply is bounded to three complete passes. A renderer may
        // insert before a pending token rather than immediately next to its
        // anchor; subsequent placements resolve the whole native order.
        for _ in 0..<3 {
            let frames = layoutFrames()
            if MenuLayoutPlanner.verify(plan, frames: frames).valid { verified = true; break }
            let moves = MenuLayoutPlanner.moves(for: plan, current: MenuLayoutPlanner.currentOrder(frames: frames))
            guard !moves.isEmpty else { break }
            for move in moves {
                guard started, operationGeneration.accepts(ticket), !Task.isCancelled, pointer.generation == inputGeneration else {
                    fail("布局已被用户输入中断；图标保持可见，可再次应用布局"); return
                }
                let windows = discovery.allWindows()
                guard let source = renderer(for: move.item, windows: windows), let anchor = renderer(for: move.before, windows: windows) else {
                    fail("布局停止：原生窗口已改变，请刷新后重试"); return
                }
                let outcome = await mover.move(windowID: source.id, before: anchor.id)
                updateLiveFrames()
                guard outcome.moved else {
                    fail("无法验证“\(title(move.item))”的移动（\(outcome.stage)）；图标保持可见"); return
                }
                completedMoves += 1
            }
        }
        updateLiveFrames()
        verified = verified || MenuLayoutPlanner.verify(plan, frames: layoutFrames()).valid
        guard verified else { fail("原生窗口位置与保存布局不一致；请再次应用布局"); return }
        layoutReady = true
        separators.rememberPositions()
        temporaryShows.removeAll()
        model.statusMessage = completedMoves == 0 ? "当前原生布局已符合设置" : "菜单栏布局已应用并验证"
    }

    /// A checkbox or row drag places just that selected item. Folding,
    /// launch, imports and passive observations never enter this path.
    private func executePlacement(id: String, ordered: Bool, ticket: UInt64) async {
        guard model.accessibilityGranted else { fail("移动图标需要辅助功能权限"); return }
        guard await mover.waitForQuiet(), operationGeneration.accepts(ticket), !Task.isCancelled else {
            fail("用户正在使用鼠标；图标设置已保存，可稍后应用布局"); return
        }
        capture.pause()
        model.busy = true; editing = true
        synchronizePresentation()
        defer {
            editing = false; model.busy = false
            synchronizePresentation(); capture.resume(); updateCapturedImages()
        }
        let inputGeneration = pointer.generation
        guard await waitForSeparatorRenderers(ticket: ticket, inputGeneration: inputGeneration) else {
            fail("图标设置已保存；原生分隔项尚未稳定，可稍后应用布局"); return
        }
        refreshSnapshot()
        let token = MenuLayoutPlanner.Token.icon(id)
        let plan = layoutPlan()
        let target: MenuLayoutPlanner.Token
        if ordered, let index = plan.desired.firstIndex(of: token), index + 1 < plan.desired.count {
            target = plan.desired[index + 1]
        } else {
            switch model.rule(for: id).visibility {
            case .alwaysHidden: target = .alwaysHiddenSeparator
            case .hidden: target = .hiddenSeparator
            case .visible:
                guard let mainIndex = plan.desired.firstIndex(of: .control),
                      let next = plan.desired.dropFirst(mainIndex + 1).first(where: { $0 != token }) else {
                    fail("图标设置已保存；可见组锚点暂不可用"); return
                }
                target = next
            }
        }
        guard let source = renderer(for: token), let anchor = renderer(for: target) else {
            fail("图标设置已保存；原生窗口暂不可用"); return
        }
        layoutPassCount += 1; lastLayoutReason = "移动所选图标"
        let outcome = await mover.move(windowID: source.id, before: anchor.id)
        updateLiveFrames()
        guard outcome.moved else { fail("所选图标移动未完成（\(outcome.stage)）；可稍后应用布局"); return }
        layoutReady = true
        separators.rememberPositions()
        model.statusMessage = "所选图标已移动"
    }

    /// One selected icon may be temporarily inserted into the native bar.
    /// The always-hidden boundary stays widened; no unrelated icon moves.
    private func executeActivation(id: String, rightClick: Bool, ticket: UInt64) async {
        capture.pause()
        defer { capture.resume(); updateCapturedImages() }
        refreshSnapshot()
        guard model.accessibilityGranted, let record = records[id], let windowID = record.icon.windowID else {
            fail("无法激活：图标窗口不可用或缺少辅助功能权限"); return
        }
        guard await mover.waitForQuiet(), operationGeneration.accepts(ticket), !Task.isCancelled else {
            fail("激活已取消：用户正在操作鼠标或快捷键"); return
        }
        activationCount += 1
        model.busy = true
        if !nativeIconIsVisible(record.icon), temporaryShows[id] == nil {
            let plan = layoutPlan()
            let token = MenuLayoutPlanner.Token.icon(id)
            guard record.icon.movable, let index = plan.desired.firstIndex(of: token), index + 1 < plan.desired.count,
                  let anchor = renderer(for: .control) else { fail("无法临时显示该原生图标"); return }
            let context = TemporaryShow(id: id, windowID: windowID, visibility: model.rule(for: id).visibility,
                                        checkpoint: separators.positionCheckpoint())
            guard let temporaryX = temporaryRevealTarget(for: record.icon, main: anchor.frame) else {
                fail("菜单栏空白区域尚未稳定；请稍后重试"); return
            }
            let outcome = await mover.move(windowID: windowID, before: anchor.id, style: .temporaryReveal,
                                           temporaryTargetX: temporaryX)
            updateLiveFrames()
            guard outcome.moved, let icon = model.icons.first(where: { $0.id == id }), nativeIconIsVisible(icon) else {
                fail("临时显示未完成（\(outcome.stage)）；请在原生菜单栏检查该图标"); return
            }
            temporaryShows[id] = context
        }
        guard operationGeneration.accepts(ticket), !Task.isCancelled,
              let icon = model.icons.first(where: { $0.id == id }) else { return }
        let baseline = interface.baseline()
        var observed = false
        if !rightClick, let element = records[id]?.element,
           AXUIElementPerformAction(element, kAXPressAction as CFString) == .success {
            observed = await waitForInterface(icon, baseline: baseline, milliseconds: 200)
        }
        if !observed, !Task.isCancelled {
            let clicked = await mover.click(windowID: windowID, right: rightClick)
            if clicked { observed = await waitForInterface(icon, baseline: baseline, milliseconds: 500) }
        }
        model.busy = false
        if !observed { fail("已请求原生图标操作；尚未观察到菜单或界面，请检查菜单栏") }
        guard let context = temporaryShows[id], !Task.isCancelled else { return }
        // Native preferred-position reentry restores the separator. Returning
        // from a real menu posts no mouse/key event and never warps the cursor.
        let delay = max(1, min(60, model.settings.autoHideDelay))
        let notBefore = ProcessInfo.processInfo.systemUptime + delay
        let deadline = notBefore + 120
        while started, operationGeneration.accepts(ticket), !Task.isCancelled {
            let now = ProcessInfo.processInfo.systemUptime
            if now >= notBefore && !interface.hasInterface(for: icon, rendererPID: records[id]?.renderer?.pid, since: baseline)
                && !interface.menuIsOpen { break }
            if now >= deadline { fail("原生界面仍打开；临时图标保持可见，可应用布局归位"); return }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        guard started, operationGeneration.accepts(ticket), !Task.isCancelled else { return }
        separators.restorePositions(context.checkpoint, section: context.visibility)
        synchronizePresentation()
        try? await Task.sleep(nanoseconds: 180_000_000)
        guard started, operationGeneration.accepts(ticket), !Task.isCancelled else { return }
        updateLiveFrames()
        if let returned = model.icons.first(where: { $0.id == id }),
           !nativeIconIsVisible(returned) || (model.settings.mode == .normal && model.expanded && context.visibility == .hidden) {
            temporaryShows.removeValue(forKey: id)
        } else { fail("系统尚未归还临时图标；可应用布局归位") }
    }

    private func waitForInterface(_ icon: MenuBarIcon, baseline: MenuInterfaceMonitor.Baseline, milliseconds: Int) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + Double(milliseconds) / 1_000
        while started, !Task.isCancelled, ProcessInfo.processInfo.systemUptime < deadline {
            if interface.hasInterface(for: icon, rendererPID: records[icon.id]?.renderer?.pid, since: baseline) { return true }
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
        return false
    }
    private func nativeIconIsVisible(_ icon: MenuBarIcon) -> Bool {
        NSScreen.screens.contains { screen in
            screen.frame.contains(icon.frame) && icon.frame.maxY >= screen.frame.maxY - NSStatusBar.system.thickness - 8
        }
    }
    private func temporaryRevealTarget(for icon: MenuBarIcon, main: CGRect) -> CGFloat? {
        guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(main) }) else { return nil }
        let frame = screen.frame
        let left = blankRegions.regions.filter { $0.intersects(frame) }.map(\.minX).min()
        let divider = separators.frames[.hiddenSeparator]
        guard let left, let divider else { return nil }
        // The macOS 26 reference's adjacent-renderer global is initially
        // zero; its located population code is in the legacy branch.
        let blank = CGRect(x: left - frame.minX, y: 0,
                           width: max(0, divider.maxX - left - 4), height: main.height)
        let first = discovery.allWindows().filter {
            $0.layer == 25 && !$0.title.isEmpty && $0.frame.minX >= divider.maxX
                && abs($0.frame.midY - divider.midY) <= 1 && abs($0.frame.height - divider.height) <= 1
        }.min(by: { $0.frame.minX < $1.frame.minX })?.frame ?? main
        return MenuTemporaryRevealGeometry.targetX(width: icon.frame.width, screen: frame, main: main,
            blank: blank, notchRight: screen.safeAreaInsets.top > 0 ? frame.width / 2 + 90 : nil,
            firstVisible: first)
    }
    private func layoutPlan() -> MenuLayoutPlanner.Plan {
        MenuLayoutPlanner.plan(items: model.icons.map {
            let rule = model.rule(for: $0.id)
            return MenuLayoutPlanner.Item(id: $0.id, visibility: rule.visibility, order: rule.order,
                                          x: $0.frame.minX, movable: $0.movable)
        })
    }
    private func layoutFrames() -> [MenuLayoutPlanner.Token: CGRect] {
        let windows = discovery.allWindows()
        var result: [MenuLayoutPlanner.Token: CGRect] = [:]
        for token in [MenuLayoutPlanner.Token.control, .hiddenSeparator, .alwaysHiddenSeparator] {
            if let item = separators.item(for: token), item.isVisible,
               let window = discovery.statusRenderer(item, windows: windows) { result[token] = window.frame }
        }
        for icon in model.icons {
            if let id = icon.windowID, let window = windows.first(where: { $0.id == id }),
               MenuLayoutPlanner.usable(window.frame) { result[.icon(icon.id)] = window.frame }
        }
        return result
    }
    private func waitForSeparatorRenderers(ticket: UInt64, inputGeneration: UInt64) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + 0.9
        var previous: [MenuLayoutPlanner.Token: CGRect] = [:]
        var previousIDs: [MenuLayoutPlanner.Token: CGWindowID] = [:]
        var stable = 0
        while ProcessInfo.processInfo.systemUptime < deadline {
            guard started, operationGeneration.accepts(ticket), !Task.isCancelled,
                  pointer.generation == inputGeneration else { return false }
            let windows = discovery.allWindows()
            var frames: [MenuLayoutPlanner.Token: CGRect] = [:]
            var ids: [MenuLayoutPlanner.Token: CGWindowID] = [:]
            for token in [MenuLayoutPlanner.Token.control, .hiddenSeparator, .alwaysHiddenSeparator] {
                guard let item = separators.item(for: token), item.isVisible,
                      let window = discovery.statusRenderer(item, windows: windows),
                      window.frame.width <= 100 else { continue }
                frames[token] = window.frame; ids[token] = window.id
            }
            if frames.count == 3 {
                stable = frames == previous && ids == previousIDs ? stable + 1 : 1
                if stable >= 3 { return true }
            } else { stable = 0 }
            previous = frames; previousIDs = ids
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
        return false
    }
    private func renderer(for token: MenuLayoutPlanner.Token, windows: [MenuWindowDiscovery.Window]? = nil) -> MenuWindowDiscovery.Window? {
        let windows = windows ?? discovery.allWindows()
        if let item = separators.item(for: token) { return discovery.statusRenderer(item, windows: windows) }
        guard case .icon(let id) = token, let windowID = records[id]?.icon.windowID else { return nil }
        return windows.first { $0.id == windowID }
    }
    private func updateLiveFrames() {
        let windows = discovery.allWindows()
        var icons = model.icons
        for index in icons.indices {
            guard let id = icons[index].windowID, let window = windows.first(where: { $0.id == id }) else { continue }
            icons[index].frame = window.frame
            records[icons[index].id]?.icon.frame = window.frame
            records[icons[index].id]?.renderer = window
        }
        model.icons = icons
    }
    private func title(_ token: MenuLayoutPlanner.Token) -> String {
        if case .icon(let id) = token { return records[id]?.icon.title ?? id }
        return token == .control ? "Superbar" : "分隔项"
    }

    // MARK: Presentation and passive observations

    private func synchronizePresentation() {
        // Preserve unchanged native hit surfaces across polling and capture.
        // A small read-only debounce updates geometry after divider changes;
        // editing removes surfaces while an explicit operation owns the bar.
        blankRegionTask?.cancel(); blankRegionTask = nil
        if editing || !started { blankRegions.stop() }
        let hasHidden = model.icons.contains { $0.movable && model.rule(for: $0.id).visibility == .hidden }
        let hasAlways = model.icons.contains { $0.movable && model.rule(for: $0.id).visibility == .alwaysHidden }
        separators.present(.init(mode: model.settings.mode, expanded: model.expanded, layoutReady: layoutReady,
                                 editing: editing, hasHidden: hasHidden, hasAlwaysHidden: hasAlways))
        guard started, !editing else { return }
        let lease = lifecycle.value
        blankRegionTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 100_000_000)
            guard let self, self.started, self.lifecycle.accepts(lease), !Task.isCancelled, !self.editing else { return }
            self.blankRegionTask = nil
            self.updateBlankRegions()
        }
    }
    private func updateBlankRegions() {
        let windows = discovery.allWindows()
        let control = separators.main.flatMap { discovery.statusRenderer($0, windows: windows)?.frame }
        let coordinates = MenuCoordinates.current
        let frames = windows.filter {
            ($0.layer == 24 || $0.layer == 25) && coordinates.isMenuExtraFrame($0.quartzFrame)
                && !$0.owner.lowercased().contains("windowserver")
        }.map(\.frame)
        blankRegions.update(control: control, nativeFrames: frames, mode: model.settings.mode,
                            hover: model.settings.hoverRevealDelay != nil,
                            click: model.settings.mode == .aggregate && model.settings.trigger == .click,
                            enabled: started && !editing, accessibility: model.accessibilityGranted)
    }
    private func setExpanded(_ expanded: Bool) {
        guard started else { return }
        hoverTask?.cancel(); hoverTask = nil
        autoReturnTask?.cancel(); autoReturnTask = nil
        if !expanded, model.expanded, blankRegions.contains(NSEvent.mouseLocation) { hoverAwaitingExit = true }
        model.expanded = expanded
        synchronizePresentation()
        if model.settings.mode == .aggregate {
            if expanded { onShowAggregate?() } else { onHideAggregate?() }
        }
        if expanded { scheduleAutomaticReturn() }
    }
    private func aggregateDismissed() {
        autoReturnTask?.cancel(); autoReturnTask = nil
        model.expanded = false
        synchronizePresentation()
    }
    private func scheduleAutomaticReturn() {
        autoReturnTask?.cancel()
        let lease = lifecycle.value
        let delay = max(1, min(60, model.settings.autoHideDelay))
        autoReturnTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self else { return }
            while self.started, self.lifecycle.accepts(lease), self.model.expanded, !Task.isCancelled {
                if !self.interface.menuIsOpen && !self.model.busy { self.setExpanded(false); return }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
    }
    private func handleInput(_ input: MenuPointerMonitor.Input) {
        guard started else { return }
        if mover.running {
            operationTask?.cancel()
            mover.cancelAndRelease()
            return
        }
        if input.type == .flagsChanged { hoverTask?.cancel(); hoverTask = nil }
    }
    private func hoverBlankRegion(at point: CGPoint) {
        guard started, !editing, !model.expanded, !hoverAwaitingExit, blankRegions.contains(point),
              let delay = model.settings.hoverRevealDelay, hoverTask == nil else { return }
        let lease = lifecycle.value
        let ticket = hoverGeneration.advance()
        hoverTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self else { return }
            defer { if self.hoverGeneration.accepts(ticket) { self.hoverTask = nil } }
            guard self.started, self.lifecycle.accepts(lease), !Task.isCancelled,
                  self.hoverGeneration.accepts(ticket),
                  self.model.settings.hoverRevealDelay == delay, self.blankRegions.contains(NSEvent.mouseLocation) else { return }
            if self.model.settings.mode == .aggregate { self.aggregateRevealAnchor = self.pointerAnchor(at: NSEvent.mouseLocation) }
            self.setExpanded(true)
        }
    }
    private func clickBlankRegion(at point: CGPoint) {
        guard handlesBlankClick(at: point) else { return }
        blankClickTask?.cancel(); blankClickTask = nil
        hoverTask?.cancel(); hoverTask = nil
        if model.expanded { setExpanded(false); return }
        let lease = lifecycle.value
        let ticket = blankClickGeneration.advance()
        blankClickTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 50_000_000)
            guard let self else { return }
            defer { if self.blankClickGeneration.accepts(ticket) { self.blankClickTask = nil } }
            guard self.started, self.lifecycle.accepts(lease), self.blankClickGeneration.accepts(ticket),
                  !Task.isCancelled, self.handlesBlankClick(at: point) else { return }
            self.aggregateRevealAnchor = self.pointerAnchor(at: point)
            self.setExpanded(true)
        }
    }
    private func pointerAnchor(at point: CGPoint) -> CGRect? {
        let frame = separators.frames[.hiddenSeparator] ?? separators.frames[.control]
        guard let frame else { return nil }
        return CGRect(x: point.x - 5, y: frame.minY, width: 10, height: frame.height)
    }
    private func updateCapturedImages() {
        guard started, model.screenRecordingGranted else { return }
        var icons = model.icons
        for index in icons.indices {
            if let windowID = icons[index].windowID,
               let image = capture.image(windowID: windowID, frame: icons[index].frame) { icons[index].image = image }
        }
        model.icons = icons
    }
    private func settingsChanged() {
        blankClickTask?.cancel(); blankClickTask = nil
        if lastMode != model.settings.mode {
            lastMode = model.settings.mode
            setExpanded(false)
            onHideAggregate?()
        }
        hoverTask?.cancel(); hoverTask = nil
        separators.updateSymbol(model.settings.statusSymbol)
        preferences.update(settings: model.settings)
        updateHotkeys()
        synchronizePresentation()
        if model.expanded { scheduleAutomaticReturn() }
    }
    private func updateHotkeys() {
        let shortcuts = model.settings.rules.keys.sorted().compactMap { id -> (id: String, shortcut: Shortcut)? in
            guard !MenuDiscoveryPolicy.excludesPersistedID(id), let shortcut = model.settings.rules[id]?.shortcut else { return nil }
            return (id, shortcut)
        }
        let signature = "\(model.settings.toggleShortcut?.combinationID ?? "")|" + shortcuts.map { "\($0.id):\($0.shortcut.combinationID)" }.joined(separator: "|")
        guard signature != lastHotkeySignature else { return }
        lastHotkeySignature = signature
        hotkeys?.update(toggle: model.settings.toggleShortcut, iconShortcuts: shortcuts,
                        onToggle: { [weak self] in self?.toggle() }, onIcon: { [weak self] id in self?.activateIcon(id: id) })
    }
    private func migrateLegacyRules() {
        var rules = model.settings.rules
        var changed = false
        let privacyID = "com.apple.controlcenter|com.apple.menuextra.audiovideo"
        if let generated = rules[privacyID], generated.visibility == .visible, generated.shortcut == nil {
            rules.removeValue(forKey: privacyID)
            changed = true
        }
        for bundle in Set(model.icons.map(\.bundleID)) {
            let items = model.icons.filter { $0.bundleID == bundle && $0.id.hasPrefix("\(bundle)|status-item") }
            let legacy = rules.keys.filter { $0.hasPrefix("\(bundle)|title:") || $0.hasPrefix("\(bundle)|cg:") }
            guard items.count == 1, legacy.count == 1, let icon = items.first, let key = legacy.first, let rule = rules[key] else { continue }
            // A newly observed default rule must not overwrite an old choice.
            if model.newlyDiscoveredIDs.contains(icon.id), rules[icon.id]?.visibility == .visible && rules[icon.id]?.shortcut == nil {
                rules[icon.id] = rule; rules.removeValue(forKey: key); changed = true
            }
        }
        if changed { _ = model.adoptDiscoveredRules(rules) }
    }
    private func installObservers() {
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.didActivateApplicationNotification,
                     NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didWakeNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.scheduleRefresh() }
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.scheduleRefresh() }
        })
    }
    private func scheduleRefresh() {
        refreshTask?.cancel()
        let lease = lifecycle.value
        refreshTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard let self, self.started, self.lifecycle.accepts(lease), !Task.isCancelled else { return }
            self.refreshTask = nil
            self.refresh()
        }
    }
    private func fail(_ text: String) { model.statusMessage = text }

    // MARK: Model command wiring

    private func wireCallbacks() {
        previousSettings = model.onSettingsChanged
        previousCommit = model.onSettingsCommit
        previousRefresh = model.onRefresh
        previousActivate = model.onActivateIcon
        previousApply = model.onApplyLayout
        previousPlace = model.onPlaceIcon
        previousToggle = model.onToggle
        previousDismiss = model.onAggregateDismissed
        previousAccessibility = model.onRequestAccessibility
        previousRecording = model.onRequestScreenRecording
        model.onSettingsChanged = { [weak self] in self?.settingsChanged(); self?.previousSettings?() }
        model.onSettingsCommit = { [weak self] change in
            guard let self else { return }
            if change.requiresLayout { self.model.statusMessage = "图标设置已保存" }
            self.previousCommit?(change)
        }
        model.onRefresh = { [weak self] in self?.refresh(); self?.previousRefresh?() }
        model.onActivateIcon = { [weak self] id, right in self?.activateIcon(id: id, rightClick: right); self?.previousActivate?(id, right) }
        model.onApplyLayout = { [weak self] in self?.requestLayout(trigger: .explicitApply, reason: "应用菜单栏布局"); self?.previousApply?() }
        model.onPlaceIcon = { [weak self] id, ordered in
            self?.enqueueOperation { [weak self] ticket in await self?.executePlacement(id: id, ordered: ordered, ticket: ticket) }
            self?.previousPlace?(id, ordered)
        }
        model.onToggle = { [weak self] in self?.toggle(); self?.previousToggle?() }
        model.onAggregateDismissed = { [weak self] in self?.aggregateDismissed(); self?.previousDismiss?() }
        model.onRequestAccessibility = { [weak self] in
            if let previous = self?.previousAccessibility { previous() } else { MenuSystemPreferences.requestAccessibility() }
        }
        model.onRequestScreenRecording = { [weak self] in
            if let previous = self?.previousRecording { previous() } else { MenuSystemPreferences.requestScreenRecording() }
        }
    }
    private func unwireCallbacks() {
        model.onSettingsChanged = previousSettings; model.onSettingsCommit = previousCommit
        model.onRefresh = previousRefresh; model.onActivateIcon = previousActivate; model.onApplyLayout = previousApply
        model.onPlaceIcon = previousPlace
        model.onToggle = previousToggle; model.onAggregateDismissed = previousDismiss
        model.onRequestAccessibility = previousAccessibility; model.onRequestScreenRecording = previousRecording
        previousSettings = nil; previousCommit = nil; previousRefresh = nil; previousActivate = nil; previousApply = nil
        previousPlace = nil; previousToggle = nil; previousDismiss = nil; previousAccessibility = nil; previousRecording = nil
        lastHotkeySignature = ""
    }
}
