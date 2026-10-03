import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

enum PreferencesPage: String, CaseIterable, Identifiable {
    case general, layout, tutorial, about
    var id: String { rawValue }
    var title: String {
        switch self { case .general: return "菜单栏"; case .layout: return "菜单栏布局"; case .tutorial: return "学习教程"; case .about: return "关于 Superbar" }
    }
    var symbol: String {
        switch self { case .general: return "gearshape.fill"; case .layout: return "rectangle.3.group"; case .tutorial: return "play.rectangle.fill"; case .about: return "person.2.fill" }
    }
    var color: Color {
        switch self { case .general: return PreferencesStyle.cyan; case .layout: return PreferencesStyle.orange; case .tutorial: return PreferencesStyle.pink; case .about: return PreferencesStyle.purple }
    }
}

/// Window state and native file dialogs live here; pages only present commands.
final class PreferencesSession: ObservableObject {
    @Published var page: PreferencesPage = .general
    @Published var tutorial: TutorialArticle?
    @Published var transferError: String?
    weak var window: NSWindow?
    let model: AppModel
    init(model: AppModel) { self.model = model }

    func exportSettings() {
        let panel = NSSavePanel()
        panel.title = "导出 Superbar 设置"
        panel.nameFieldStringValue = "superbar-settings.json"
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        respond(to: panel) { [weak self] url in
            guard let self else { return }
            do { try self.model.exportSettings(to: url) }
            catch { self.transferError = "导出失败：\(error.localizedDescription)" }
        }
    }
    func importSettings() {
        let panel = NSOpenPanel()
        panel.title = "导入 Superbar 设置"
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        respond(to: panel) { [weak self] url in
            guard let self else { return }
            do { _ = try self.model.importSettings(from: Data(contentsOf: url)) }
            catch { self.transferError = "导入失败：\(error.localizedDescription)" }
        }
    }
    private func respond(to panel: NSSavePanel, action: @escaping (URL) -> Void) {
        let completion: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            action(url)
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: completion) }
        else { panel.begin(completionHandler: completion) }
    }
}

final class PreferencesController: NSObject, NSWindowDelegate {
    let model: AppModel
    let session: PreferencesSession
    private(set) var window: NSWindow?
    init(model: AppModel) {
        self.model = model; session = PreferencesSession(model: model)
        super.init()
    }
    var isVisible: Bool { window?.isVisible == true }
    func show() {
        guard Thread.isMainThread else { DispatchQueue.main.async { [weak self] in self?.show() }; return }
        if window == nil {
            let preferences = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 660),
                styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            preferences.title = "Superbar 偏好设置"
            preferences.appearance = NSAppearance(named: .aqua)
            preferences.contentMinSize = NSSize(width: 800, height: 620)
            preferences.contentViewController = NSHostingController(rootView: PreferencesRootView(model: model, session: session))
            preferences.isReleasedWhenClosed = false
            preferences.delegate = self
            preferences.setFrameAutosaveName("SuperbarPreferences")
            if !preferences.setFrameUsingName("SuperbarPreferences") { preferences.center() }
            window = preferences; session.window = preferences
        }
        if let window, let screen = window.screen ?? NSScreen.main {
            let usable = screen.visibleFrame
            let frame = window.frame
            window.setFrameOrigin(NSPoint(
                x: min(max(frame.minX, usable.minX), max(usable.minX, usable.maxX - frame.width)),
                y: min(max(frame.minY, usable.minY), max(usable.minY, usable.maxY - frame.height))))
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
    func hide() {
        guard Thread.isMainThread else { DispatchQueue.main.async { [weak self] in self?.hide() }; return }
        window?.orderOut(nil)
    }
}

struct PreferencesRootView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var session: PreferencesSession
    var body: some View {
        HStack(spacing: 0) {
            PreferencesSidebar(model: model, session: session)
            Divider().opacity(0.28)
            Group {
                switch session.page {
                case .general: GeneralPreferencesView(model: model)
                case .layout: LayoutPreferencesView(model: model)
                case .tutorial: TutorialPreferencesView(session: session)
                case .about: AboutPreferencesView(model: model, session: session)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 800, minHeight: 620)
        .background(PreferencesStyle.page)
        .sheet(item: $session.tutorial) { TutorialArticleView(article: $0) }
        .alert("设置文件", isPresented: Binding(get: { session.transferError != nil }, set: { if !$0 { session.transferError = nil } })) {
            Button("好", role: .cancel) { session.transferError = nil }
        } message: { Text(session.transferError ?? "") }
    }
}

private struct PreferencesSidebar: View {
    @ObservedObject var model: AppModel
    @ObservedObject var session: PreferencesSession
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(spacing: 7) {
                SuperbarMark(size: 58)
                Text("Superbar").font(.system(size: 19, weight: .semibold, design: .rounded))
                Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0")
                    .font(.system(size: 12, weight: .medium)).foregroundColor(PreferencesStyle.secondary)
                Text("让菜单栏井然有序")
                    .font(.system(size: 10)).foregroundColor(PreferencesStyle.secondary)
            }
            .frame(maxWidth: .infinity).padding(.top, 58).padding(.bottom, 34)
            VStack(spacing: 6) {
                ForEach(PreferencesPage.allCases) { page in
                    Button { session.page = page } label: {
                        HStack(spacing: 10) {
                            Image(systemName: page.symbol).font(.system(size: 12, weight: .semibold))
                                .foregroundColor(.white).frame(width: 24, height: 24)
                                .background(LinearGradient(colors: [page.color.opacity(0.72), page.color], startPoint: .topLeading, endPoint: .bottomTrailing))
                                .clipShape(RoundedRectangle(cornerRadius: 7))
                            Text(page.title).font(.system(size: 13, weight: session.page == page ? .semibold : .regular))
                                .foregroundColor(session.page == page ? .white : .primary)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 12).frame(height: 38)
                        .background(session.page == page ? PreferencesStyle.selected : .clear)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    }.buttonStyle(.plain)
                }
            }.padding(.horizontal, 12)
            Spacer(minLength: 12)
            VStack(alignment: .leading, spacing: 8) {
                PermissionStatusView(model: model)
                Divider().opacity(0.45)
                Text("全局快捷键").font(.system(size: 11, weight: .medium)).foregroundColor(PreferencesStyle.secondary)
                ShortcutRecorder(shortcut: model.settings.toggleShortcut, placeholder: "设置快捷键") { _ = model.setToggleShortcut($0) }
                    .frame(height: 27)
                if let issue = model.shortcutRegistrationIssues["$toggle"] { Text(issue).font(.system(size: 10)).foregroundColor(.orange) }
            }.padding(.horizontal, 18).padding(.bottom, 18)
        }
        .frame(width: 205).background(PreferencesStyle.sidebar)
    }
}
