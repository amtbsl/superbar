import AppKit
import ApplicationServices

/// Read-only native interface observation. An AX success code or event ACK
/// alone never establishes that the requested menu opened.
@MainActor final class MenuInterfaceMonitor {
    struct Baseline { let windowIDs: Set<CGWindowID> }
    private let discovery: MenuWindowDiscovery
    init(discovery: MenuWindowDiscovery) { self.discovery = discovery }
    func baseline() -> Baseline {
        Baseline(windowIDs: Set(discovery.allWindows().filter(\.isOnScreen).map(\.id)))
    }
    func hasInterface(for icon: MenuBarIcon, rendererPID: pid_t?, since baseline: Baseline) -> Bool {
        let pids = Set([icon.pid, rendererPID].compactMap { $0 })
        if focusedMenu(in: pids) { return true }
        return discovery.allWindows().contains { window in
            guard window.isOnScreen, window.alpha > 0, window.pid != ProcessInfo.processInfo.processIdentifier,
                  !baseline.windowIDs.contains(window.id), window.frame.height > 40 else { return false }
            if pids.contains(window.pid) { return true }
            return window.layer == Int(CGWindowLevelForKey(.popUpMenuWindow))
                && abs(window.frame.midX - icon.frame.midX) < max(350, window.frame.width)
        }
    }
    var menuIsOpen: Bool {
        if NSApp.windows.contains(where: { $0.isVisible && $0.level == .popUpMenu }) { return true }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.05)
        if let value = MenuAccessibility.attribute(system, kAXFocusedUIElementAttribute),
           let item = MenuAccessibility.elements(value).first,
           isMenuRole(MenuAccessibility.string(item, kAXRoleAttribute)) { return true }
        return discovery.allWindows().contains {
            $0.isOnScreen && $0.alpha > 0 && $0.pid != ProcessInfo.processInfo.processIdentifier
                && $0.layer == Int(CGWindowLevelForKey(.popUpMenuWindow)) && $0.frame.height > 20
        }
    }
    private func focusedMenu(in pids: Set<pid_t>) -> Bool {
        pids.contains { pid in
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.05)
            guard let value = MenuAccessibility.attribute(app, kAXFocusedUIElementAttribute),
                  let item = MenuAccessibility.elements(value).first else { return false }
            return isMenuRole(MenuAccessibility.string(item, kAXRoleAttribute))
        }
    }
    private func isMenuRole(_ value: String?) -> Bool {
        guard let value else { return false }
        return value == kAXMenuRole || value == kAXMenuItemRole
    }
}
