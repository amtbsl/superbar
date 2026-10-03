import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct LayoutPreferencesView: View {
    @ObservedObject var model: AppModel
    @State private var draggingID: String?
    @State private var search = ""
    @State private var showSavedRules = false
    private var icons: [MenuBarIcon] {
        model.sortedIcons.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) || $0.bundleID.localizedCaseInsensitiveContains(search) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    Text("始终隐藏").frame(width: 72, alignment: .leading)
                    Text("隐藏").frame(width: 49, alignment: .leading)
                    Text("图标与名称").frame(maxWidth: .infinity, alignment: .leading)
                    Text("快捷键").frame(width: 128, alignment: .leading)
                }.font(.system(size: 11, weight: .medium)).foregroundColor(PreferencesStyle.secondary)
                    .padding(.horizontal, 14).padding(.vertical, 11)
                Divider().opacity(0.34)
                if icons.isEmpty { emptyState }
                else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(icons) { icon in
                                LayoutIconRow(model: model, icon: icon, draggingID: $draggingID)
                                    .onDrop(of: [.superbarIcon], delegate: IconRowDropDelegate(model: model, target: icon.id, source: $draggingID))
                                Divider().opacity(0.24).padding(.leading, 14)
                            }
                        }
                    }
                }
            }.frame(maxHeight: .infinity).background(PreferencesStyle.card).clipShape(RoundedRectangle(cornerRadius: 14))
            HStack(spacing: 10) {
                Button { model.onRefresh?() } label: { Label("刷新图标", systemImage: "arrow.clockwise") }.buttonStyle(.bordered)
                Button { model.onApplyLayout?() } label: { Label("应用布局", systemImage: "checkmark.circle.fill") }.buttonStyle(.borderedProminent)
                    .disabled(model.busy || !model.accessibilityGranted)
                HStack(spacing: 5) {
                    Image(systemName: "magnifyingglass").foregroundColor(PreferencesStyle.secondary)
                    TextField("搜索图标", text: $search).textFieldStyle(.plain).font(.system(size: 11))
                }.padding(6).frame(maxWidth: 125).background(Color.white.opacity(0.3)).clipShape(RoundedRectangle(cornerRadius: 7))
                Spacer(minLength: 0)
                if model.busy { ProgressView().controlSize(.small) }
                if !model.disconnectedRuleIDs.isEmpty {
                    Button("已保存的图标 (\(model.disconnectedRuleIDs.count))") { showSavedRules = true }.buttonStyle(.link).font(.system(size: 11))
                }
            }
            Text("隐藏和始终隐藏互斥。点击图标打开菜单，拖动横线调整顺序。")
                .font(.system(size: 10)).foregroundColor(PreferencesStyle.secondary)
            ModelStatusView(model: model)
        }.padding(28)
        .sheet(isPresented: $showSavedRules) { SavedIconRulesView(model: model) }
    }
    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "menubar.rectangle").font(.system(size: 26, weight: .light)).foregroundColor(PreferencesStyle.secondary)
            Text(search.isEmpty ? "暂时没有发现菜单栏图标" : "没有匹配的图标").font(.system(size: 13, weight: .medium))
            if !model.accessibilityGranted {
                Button("请求辅助功能权限") { model.onRequestAccessibility?() }.buttonStyle(.borderedProminent)
            } else {
                Text("点击“刷新图标”重新读取菜单栏").font(.system(size: 11)).foregroundColor(PreferencesStyle.secondary)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(.vertical, 42)
    }
}

private struct LayoutIconRow: View {
    @ObservedObject var model: AppModel
    let icon: MenuBarIcon
    @Binding var draggingID: String?
    var body: some View {
        let rule = model.rule(for: icon.id)
        HStack(spacing: 0) {
            visibilityCheckbox(rule.visibility == .alwaysHidden, label: "始终隐藏 \(icon.title)") {
                _ = model.setVisibility(icon.id, rule.visibility == .alwaysHidden ? .visible : .alwaysHidden)
            }.frame(width: 72, alignment: .leading)
            visibilityCheckbox(rule.visibility == .hidden, label: "隐藏 \(icon.title)") {
                _ = model.setVisibility(icon.id, rule.visibility == .hidden ? .visible : .hidden)
            }.frame(width: 49, alignment: .leading)
            HStack(spacing: 7) {
                if icon.movable {
                    IconDragHandle(iconID: icon.id, onBegin: { draggingID = icon.id }, onEnd: { draggingID = nil })
                        .frame(width: 15, height: 24)
                }
                IconActivationControl(icon: icon) { model.onActivateIcon?(icon.id, $0) }.frame(width: 23, height: 22)
                Text(icon.title).font(.system(size: 11)).lineLimit(1).truncationMode(.middle).foregroundColor(.white)
                Spacer(minLength: 0)
                if !icon.movable { Image(systemName: "lock.fill").font(.system(size: 9)).foregroundColor(.white.opacity(0.6)).help("由 macOS 固定的位置") }
            }.padding(.horizontal, 8).frame(maxWidth: .infinity, minHeight: 24)
                .background(Color(red: 0.40, green: 0.58, blue: 0.75)).clipShape(RoundedRectangle(cornerRadius: 6)).padding(.trailing, 10)
            VStack(alignment: .leading, spacing: 2) {
                ShortcutRecorder(shortcut: rule.shortcut, placeholder: "设置") { _ = model.setShortcut(icon.id, $0) }
                    .frame(height: 27)
                if let issue = model.shortcutRegistrationIssues[icon.id] { Text(issue).font(.system(size: 9)).foregroundColor(.orange).lineLimit(1).help(issue) }
            }.frame(width: 128, alignment: .leading)
        }.padding(.horizontal, 14).frame(height: 30).contentShape(Rectangle()).opacity(draggingID == icon.id ? 0.45 : 1)
            .contextMenu {
                Button("打开图标菜单") { model.onActivateIcon?(icon.id, false) }
                Button("打开右键菜单") { model.onActivateIcon?(icon.id, true) }
                if icon.movable {
                    Divider()
                    Button("显示") { _ = model.setVisibility(icon.id, .visible) }
                    Button("隐藏") { _ = model.setVisibility(icon.id, .hidden) }
                    Button("始终隐藏") { _ = model.setVisibility(icon.id, .alwaysHidden) }
                }
            }
    }
    private func visibilityCheckbox(_ checked: Bool, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: checked ? "checkmark.square.fill" : "square").font(.system(size: 16))
                .foregroundColor(checked ? PreferencesStyle.selectedText : PreferencesStyle.secondary).frame(width: 26, height: 26)
        }.buttonStyle(.plain).disabled(!icon.movable).accessibilityLabel(label).accessibilityValue(checked ? "已选中" : "未选中")
    }
}

private struct IconRowDropDelegate: DropDelegate {
    let model: AppModel
    let target: String
    @Binding var source: String?
    func validateDrop(info: DropInfo) -> Bool { source != nil && source != target && info.hasItemsConforming(to: [.superbarIcon]) }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func performDrop(info: DropInfo) -> Bool {
        guard let source, source != target else { self.source = nil; return false }
        if info.location.y > 15 { _ = model.reorder(source, after: target) }
        else { _ = model.reorder(source, before: target) }
        self.source = nil
        return true
    }
}

private struct SavedIconRulesView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PageHeader(title: "已保存的图标", subtitle: "应用再次出现时会恢复这些规则")
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(model.disconnectedRuleIDs, id: \.self) { id in
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(id).font(.system(size: 11)).lineLimit(1).truncationMode(.middle).help(id)
                                Text(visibilityTitle(model.rule(for: id).visibility)).font(.system(size: 10)).foregroundColor(PreferencesStyle.secondary)
                            }
                            Spacer()
                            Button("移除规则") { _ = model.removeSavedRule(id) }.font(.system(size: 11))
                        }.padding(10).background(PreferencesStyle.card).clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
            HStack { Spacer(); Button("好") { dismiss() }.keyboardShortcut(.defaultAction) }
        }.padding(26).frame(width: 540, height: 430).background(PreferencesStyle.page)
    }
    private func visibilityTitle(_ value: IconVisibility) -> String {
        switch value { case .visible: return "显示"; case .hidden: return "隐藏"; case .alwaysHidden: return "始终隐藏" }
    }
}
