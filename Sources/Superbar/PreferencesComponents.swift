import AppKit
import SwiftUI

enum PreferencesStyle {
    static let page = Color(red: 0.875, green: 0.879, blue: 0.886)
    static let sidebar = Color(red: 0.941, green: 0.942, blue: 0.949)
    static let card = Color(red: 0.925, green: 0.929, blue: 0.933)
    static let selected = Color(red: 0.17, green: 0.48, blue: 0.95)
    static let selectedText = Color(red: 0.10, green: 0.25, blue: 0.55)
    static let secondary = Color.black.opacity(0.52)
    static let red = Color(red: 0.93, green: 0.29, blue: 0.30)
    static let cyan = Color(red: 0.08, green: 0.68, blue: 0.78)
    static let orange = Color(red: 0.94, green: 0.50, blue: 0.18)
    static let pink = Color(red: 0.92, green: 0.35, blue: 0.57)
    static let purple = Color(red: 0.48, green: 0.37, blue: 0.87)
}

struct SuperbarMark: View {
    var size: CGFloat
    var body: some View {
        Image(systemName: "menubar.rectangle")
            .font(.system(size: size * 0.46, weight: .semibold)).foregroundColor(.white)
            .frame(width: size, height: size)
            .background(LinearGradient(colors: [Color(red: 0.10, green: 0.78, blue: 0.92), Color(red: 0.12, green: 0.42, blue: 0.95)], startPoint: .topLeading, endPoint: .bottomTrailing))
            .clipShape(RoundedRectangle(cornerRadius: size * 0.27))
    }
}
struct PageHeader: View {
    let title: String
    let subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 24, weight: .bold, design: .rounded))
            Text(subtitle).font(.system(size: 12)).foregroundColor(PreferencesStyle.secondary)
        }.padding(.bottom, 3)
    }
}
struct SectionTitle: View {
    let title: String
    let symbol: String
    let color: Color
    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: symbol).font(.system(size: 13, weight: .semibold)).foregroundColor(color).frame(width: 18, height: 18)
            Text(title).font(.system(size: 14, weight: .semibold))
        }.frame(height: 20, alignment: .leading)
    }
}
struct PreferenceCard<Content: View>: View {
    let content: Content
    var minHeight: CGFloat = 0
    init(minHeight: CGFloat = 0, @ViewBuilder content: () -> Content) { self.minHeight = minHeight; self.content = content() }
    var body: some View {
        content.padding(.horizontal, 17).padding(.vertical, 14)
            .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .topLeading)
            .background(PreferencesStyle.card).clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
    }
}
struct PreferenceRadio: View {
    let title: String
    let selected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 15)).foregroundColor(selected ? PreferencesStyle.selectedText : PreferencesStyle.secondary)
                Text(title).font(.system(size: 12)).foregroundColor(.primary)
            }
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
    }
}
struct PermissionStatusView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("权限状态").font(.system(size: 11, weight: .medium)).foregroundColor(PreferencesStyle.secondary)
            PermissionLine(title: "辅助功能", granted: model.accessibilityGranted) { model.onRequestAccessibility?() }
            PermissionLine(title: "屏幕录制", granted: model.screenRecordingGranted) { model.onRequestScreenRecording?() }
            if !model.accessibilityGranted || !model.screenRecordingGranted {
                Text("辅助功能用于整理和打开图标；屏幕录制用于图标预览。")
                    .font(.system(size: 10)).foregroundColor(PreferencesStyle.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
private struct PermissionLine: View {
    let title: String
    let granted: Bool
    let action: () -> Void
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill").foregroundColor(granted ? .green : .orange)
            Text(title).font(.system(size: 11)); Spacer(minLength: 0)
            if !granted { Button("去授权", action: action).font(.system(size: 10, weight: .medium)).buttonStyle(.borderless) }
        }
    }
}
struct ModelStatusView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        Text(model.settingsIssue ?? model.statusMessage).font(.system(size: 11))
            .foregroundColor(model.settingsIssue == nil ? PreferencesStyle.secondary : .orange)
            .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel(model.settingsIssue ?? model.statusMessage)
    }
}
