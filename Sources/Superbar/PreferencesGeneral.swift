import AppKit
import SwiftUI

struct GeneralPreferencesView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 11) {
                SectionTitle(title: "通用设置", symbol: "paperplane.fill", color: PreferencesStyle.red)
                PreferenceCard(minHeight: 196) {
                    VStack(alignment: .leading, spacing: 13) {
                        HStack(spacing: 8) {
                            Toggle("开机自启动", isOn: Binding(get: { model.settings.launchAtLogin }, set: { _ = model.setLaunchAtLogin($0) }))
                                .toggleStyle(.checkbox).font(.system(size: 12, weight: .medium))
                            Text(loginDescription).font(.system(size: 10)).foregroundColor(PreferencesStyle.secondary)
                            Spacer(minLength: 0)
                        }
                        Divider().opacity(0.32)
                        HStack(alignment: .top, spacing: 24) {
                            rowLabel("模式选择:")
                            VStack(alignment: .leading, spacing: 5) {
                                PreferenceRadio(title: "聚合模式", selected: model.settings.mode == .aggregate) { _ = model.setMode(.aggregate) }
                                description("将选中的菜单栏图标收进 Superbar")
                                PreferenceRadio(title: "普通模式", selected: model.settings.mode == .normal) { _ = model.setMode(.normal) }
                                description("悬停菜单栏空白处 0.2 秒显示图标")
                            }
                            Spacer(minLength: 0)
                        }
                        Divider().opacity(0.32)
                        HStack(spacing: 24) {
                            rowLabel("菜单栏图标间隙:")
                            Picker("菜单栏图标间隙", selection: Binding(get: { model.settings.spacing }, set: { _ = model.setSpacing($0) })) {
                                Text("默认").tag(IconSpacing.standard); Text("紧凑").tag(IconSpacing.compact)
                                Text("小").tag(IconSpacing.small); Text("无").tag(IconSpacing.none)
                            }.labelsHidden().pickerStyle(.menu).frame(width: 150, alignment: .leading)
                                .help("部分图标的间隙需要重新登录 macOS 后生效")
                            Spacer(minLength: 0)
                        }
                    }
                }
                SectionTitle(title: "聚合模式专用功能", symbol: "square.grid.2x2.fill", color: PreferencesStyle.cyan)
                PreferenceCard(minHeight: 224) {
                    VStack(alignment: .leading, spacing: 13) {
                        HStack(alignment: .top, spacing: 24) {
                            rowLabel("显示 Superbar 菜单栏方式:", width: 148)
                            VStack(alignment: .leading, spacing: 5) {
                                PreferenceRadio(title: "点击聚合图标", selected: model.settings.trigger == .icon) { _ = model.setTrigger(.icon) }
                                PreferenceRadio(title: "点击空白菜单栏", selected: model.settings.trigger == .click) { _ = model.setTrigger(.click) }
                                PreferenceRadio(title: "悬停空白处 0.5 秒", selected: model.settings.trigger == .hover) { _ = model.setTrigger(.hover) }
                            }
                            Spacer(minLength: 0)
                        }
                        .disabled(model.settings.mode == .normal).opacity(model.settings.mode == .normal ? 0.55 : 1)
                        Divider().opacity(0.30)
                        HStack(spacing: 24) {
                            rowLabel("自动隐藏延迟时间:", width: 148)
                            Slider(value: Binding(get: { model.settings.autoHideDelay }, set: { _ = model.setAutoHideDelay($0) }), in: 1...60, step: 1)
                                .frame(width: 200).accessibilityLabel("自动隐藏延迟时间")
                            Text("\(Int(model.settings.autoHideDelay)) 秒").font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundColor(PreferencesStyle.selectedText).frame(width: 50, alignment: .leading)
                            Spacer(minLength: 0)
                        }
                        Divider().opacity(0.30)
                        HStack(spacing: 24) {
                            rowLabel("Superbar 菜单栏图标:", width: 148)
                            StatusSymbolPicker(model: model)
                            Spacer(minLength: 0)
                        }
                    }
                }
                ModelStatusView(model: model).padding(.horizontal, 3)
            }.padding(.horizontal, 28).padding(.top, 30).padding(.bottom, 18)
        }
    }
    private func rowLabel(_ text: String, width: CGFloat = 112) -> some View {
        Text(text).font(.system(size: 12, weight: .medium)).frame(width: width, alignment: .leading)
    }
    private func description(_ text: String) -> some View {
        Text(text).font(.system(size: 10)).foregroundColor(PreferencesStyle.secondary).padding(.leading, 23)
    }
    private var loginDescription: String {
        switch model.loginItemState {
        case .requiresApproval: return "请在系统设置的“登录项”中允许 Superbar"
        case .unavailable(let reason): return reason
        default: return "登录 macOS 后自动运行 Superbar"
        }
    }
}

struct StatusSymbolPicker: View {
    @ObservedObject var model: AppModel
    private let choices = [("", "透明"), ("menubar.rectangle", "菜单栏"), ("square.grid.2x2.fill", "方格"),
        ("circle.grid.3x3.fill", "圆点"), ("line.3.horizontal", "横线"), ("sparkles", "闪光")]
    var body: some View {
        Picker("Superbar 菜单栏图标", selection: Binding(get: { model.settings.statusSymbol }, set: { _ = model.setStatusSymbol($0) })) {
            ForEach(choices, id: \.0) { symbol, title in
                if symbol.isEmpty { Text(title).tag(symbol) }
                else { Label(title, systemImage: symbol).tag(symbol) }
            }
        }.labelsHidden().pickerStyle(.menu).frame(width: 150, alignment: .leading)
            .help("透明图标仍可点击；全局快捷键也可打开 Superbar")
    }
}
