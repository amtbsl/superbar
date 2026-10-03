import AppKit
import ApplicationServices
import ServiceManagement

/// Explicit settings integration, independent of discovery and native
/// movement. Global spacing changes take effect as menu extras are relaunched.
@MainActor final class MenuSystemPreferences {
    var report: ((String) -> Void)?
    var onLoginState: ((LoginItemState) -> Void)?
    private var spacing: IconSpacing?
    private var login: Bool?
    private let keys = ["NSStatusItemSpacing", "NSStatusItemSelectionPadding"]
    private let baselineKey = "Superbar.NativeSpacingBaseline.v2"
    private let absentKey = "Superbar.NativeSpacingAbsent.v2"

    func start(settings: BarSettings) {
        login = settings.launchAtLogin
        observeLoginState()
        applySpacing(settings.spacing)
    }
    func update(settings: BarSettings) {
        applySpacing(settings.spacing)
        guard login != settings.launchAtLogin else { observeLoginState(); return }
        login = settings.launchAtLogin
        do {
            if settings.launchAtLogin {
                if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
            } else if SMAppService.mainApp.status != .notRegistered { try SMAppService.mainApp.unregister() }
            if SMAppService.mainApp.status == .requiresApproval {
                report?("登录时启动等待系统设置确认")
            } else { report?(settings.launchAtLogin ? "已启用登录时启动" : "已关闭登录时启动") }
            observeLoginState()
        } catch {
            onLoginState?(.unavailable(error.localizedDescription))
            report?("登录项更新失败：\(error.localizedDescription)")
        }
    }
    func observeLoginState() {
        switch SMAppService.mainApp.status {
        case .enabled: onLoginState?(.enabled)
        case .notRegistered: onLoginState?(.disabled)
        case .requiresApproval: onLoginState?(.requiresApproval)
        case .notFound: onLoginState?(.disabled)
        @unknown default: onLoginState?(.unknown)
        }
    }
    private func applySpacing(_ requested: IconSpacing) {
        guard spacing != requested else { return }
        spacing = requested
        let defaults = UserDefaults.standard
        if requested == .standard {
            guard let baseline = defaults.dictionary(forKey: baselineKey) else { return }
            let absent = Set(defaults.stringArray(forKey: absentKey) ?? [])
            for key in keys {
                if let value = baseline[key] { write(key, value: value) }
                else if absent.contains(key) { write(key, value: nil) }
            }
            synchronize()
            defaults.removeObject(forKey: baselineKey)
            defaults.removeObject(forKey: absentKey)
            report?("间距已恢复；重新登录后对所有图标生效")
            return
        }
        if defaults.dictionary(forKey: baselineKey) == nil {
            var baseline: [String: Any] = [:]
            var absent: [String] = []
            for key in keys {
                if let value = CFPreferencesCopyValue(key as CFString, kCFPreferencesAnyApplication,
                                                     kCFPreferencesCurrentUser, kCFPreferencesAnyHost) {
                    baseline[key] = value
                } else { absent.append(key) }
            }
            defaults.set(baseline, forKey: baselineKey)
            defaults.set(absent, forKey: absentKey)
        }
        let values: (Int, Int)
        switch requested {
        case .standard: values = (0, 0)
        case .compact: values = (4, 2)
        case .small: values = (2, 1)
        case .none: values = (0, 0)
        }
        write(keys[0], value: values.0)
        write(keys[1], value: values.1)
        synchronize()
        report?("间距已更新；重新登录后对所有图标生效")
    }
    private func write(_ key: String, value: Any?) {
        CFPreferencesSetValue(key as CFString, value as? CFPropertyList, kCFPreferencesAnyApplication,
                              kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    }
    private func synchronize() {
        CFPreferencesSynchronize(kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    }
    static func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(options), let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
    static func requestScreenRecording() {
        if !CGRequestScreenCaptureAccess(), let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}
