import AppKit
import Combine

/// Owns application lifetime and connects independent UI and menu services.
/// Opening preferences never requests a native layout operation.
@MainActor final class ApplicationCoordinator: NSObject, NSApplicationDelegate {
    private let model = AppModel()
    private var engine: MenuBarEngine?
    private var preferences: PreferencesController?
    private var aggregate: AggregatePanel?
    private var diagnostics: LocalDiagnostics?
    private var diagnosticPreference: AnyCancellable?
    private let diagnosticOverride = CommandLine.arguments.contains("--diagnostics")

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard engine == nil else { return }
        NSApp.setActivationPolicy(.accessory)
        installApplicationMenu()

        let preferences = PreferencesController(model: model)
        let aggregate = AggregatePanel(model: model)
        let engine = MenuBarEngine(model: model)
        self.preferences = preferences
        self.aggregate = aggregate
        self.engine = engine
        aggregate.anchorProvider = { [weak engine] in
            if let anchor = engine?.aggregateRevealAnchor { return anchor }
            guard let frame = engine?.statusItemFramesSnapshot["main"], frame.count == 4,
                  frame[2] > 0, frame[3] > 0 else { return nil }
            return NSRect(x: frame[0], y: frame[1], width: frame[2], height: frame[3])
        }
        aggregate.revealTargetContains = { [weak engine] point in
            engine?.handlesBlankClick(at: point) ?? false
        }
        engine.onShowSettings = { [weak self] in self?.showPreferences() }
        engine.onShowAggregate = { [weak self] in
            self?.preferences?.hide()
            self?.aggregate?.show()
        }
        engine.onHideAggregate = { [weak self] in self?.aggregate?.hide() }
        model.onShowSettings = { [weak self] in self?.showPreferences() }
        engine.start()

        diagnostics = LocalDiagnostics(model: model, engine: engine,
                                       aggregateVisible: { [weak aggregate] in aggregate?.isVisible ?? false })
        diagnosticPreference = model.$settings.map(\.diagnosticsEnabled).removeDuplicates().sink { [weak self] enabled in
            guard let self else { return }
            self.diagnostics?.setEnabled(enabled || self.diagnosticOverride)
        }
        if CommandLine.arguments.contains("--settings") || !model.accessibilityGranted { showPreferences() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Remote status windows can make this flag true with settings closed.
        if aggregate?.isVisible != true { showPreferences() }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        diagnosticPreference?.cancel()
        diagnosticPreference = nil
        diagnostics?.setEnabled(false)
        diagnostics = nil
        engine?.stop()
        aggregate?.hide()
        model.onShowSettings = nil
        engine = nil
        aggregate = nil
        preferences = nil
    }

    @objc private func showPreferences() { preferences?.show() }
    @objc private func toggleMenuBar() { engine?.toggle() }

    private func installApplicationMenu() {
        let menu = NSMenu()
        let root = NSMenuItem(title: "Superbar", action: nil, keyEquivalent: "")
        let applicationMenu = NSMenu(title: "Superbar")
        root.submenu = applicationMenu
        menu.addItem(root)
        for (title, action, key) in [
            ("显示/隐藏菜单栏", #selector(toggleMenuBar), ""),
            ("Superbar 偏好设置…", #selector(showPreferences), ",")
        ] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.target = self
            applicationMenu.addItem(item)
        }
        applicationMenu.addItem(.separator())
        let quit = NSMenuItem(title: "退出 Superbar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        applicationMenu.addItem(quit)
        NSApp.mainMenu = menu
    }
}
