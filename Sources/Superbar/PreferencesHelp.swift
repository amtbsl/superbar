import AppKit
import SwiftUI

enum TutorialArticle: String, Identifiable {
    case guide, faq
    var id: String { rawValue }
    var title: String { self == .guide ? "教学指导" : "常见问题" }
    var symbol: String { self == .guide ? "book.fill" : "questionmark.circle.fill" }
    var sections: [(String, String)] {
        switch self {
        case .guide: return [
            ("1. 允许 Superbar 访问菜单栏", "在左侧查看权限状态。辅助功能用于调整图标位置并打开图标的真实菜单；屏幕录制用于显示菜单栏图标预览。授权后点击“刷新图标”。"),
            ("2. 选择显示方式", "在“菜单栏布局”中勾选“隐藏”或“始终隐藏”。两种选择互斥；取消勾选即恢复显示。“隐藏”的图标可通过聚合栏或普通模式再次打开，“始终隐藏”的图标不会出现在聚合栏。"),
            ("3. 调整顺序和打开菜单", "拖动图标名称旁的三条横线，将这一行放到目标行的上半部或下半部。点击图标会打开对应菜单，右键点击可打开右键菜单。布局会自动保存并应用；“应用布局”可重新应用已保存的选择。"),
            ("4. 选择模式", "聚合模式把隐藏的图标放入浮动栏，可通过聚合图标、菜单栏空白处点击或悬停打开。普通模式在菜单栏空白处悬停 0.2 秒后展开原生图标，与聚合模式的触发设置独立。"),
            ("5. 设置快捷键和自动返回", "点击快捷键区域并按下组合键。全局快捷键显示或收起隐藏图标；图标快捷键直接打开对应图标。Escape 取消录入，单独按 Delete 清除。展开后会按设定时间自动返回；聚合栏还可通过 Escape 或点击外部关闭。")]
        case .faq: return [
            ("为什么有些图标看不到？", "先检查辅助功能和屏幕录制权限，再点击“刷新图标”。应用退出后，它的规则仍会保留，并在它重新出现时恢复。没有屏幕录制权限时，预览可能显示应用图标。"),
            ("为什么有的图标不能隐藏或拖动？", "时钟等由 macOS 固定位置的图标会显示锁形标记。Superbar 会保留这些图标的位置，避免影响系统菜单栏。"),
            ("快捷键为什么不能用？", "组合键必须包含 Command、Control、Option 或 Shift 中至少一个修饰键。与全局快捷键或其它图标重复的组合不会保存；被系统或其它应用占用时，会显示注册失败提示。请换一个组合键。"),
            ("透明图标如何打开？", "透明图标的位置仍然可以点击，也可用左侧的全局快捷键打开 Superbar。要恢复可见图标，在“菜单栏”页面选择另一种样式。"),
            ("间隙设置何时生效？", "不同应用的菜单栏图标更新时间不同。部分图标需要重新登录 macOS 后才会采用新间隙；选择“默认”可恢复系统默认值。"),
            ("如何备份设置？", "在“关于 Superbar”中导出或导入设置。导入会先完整校验，失败时保留当前设置。原有设置文件若损坏，Superbar 会保留一份恢复文件，并尽量保留有效隐藏规则。"),
            ("截图和设置会上传吗？", "不会。菜单栏图标预览和设置都在本机处理。诊断日志默认关闭，启用后也仅保存在本机。")]
        }
    }
}

struct TutorialPreferencesView: View {
    @ObservedObject var session: PreferencesSession
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PageHeader(title: "学习教程", subtitle: "几分钟内完成设置，所有说明都保存在本地")
                tutorialCard(.guide, subtitle: "从授权到整理菜单栏图标")
                tutorialCard(.faq, subtitle: "了解聚合模式、权限和快捷键")
                PreferenceCard {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("本地数据").font(.system(size: 13, weight: .semibold))
                        Text("Superbar 只在本机保存布局和快捷键设置。菜单栏截图用于显示当前图标，不会上传到网络。")
                            .font(.system(size: 11)).foregroundColor(PreferencesStyle.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }.padding(28)
        }
    }
    private func tutorialCard(_ article: TutorialArticle, subtitle: String) -> some View {
        Button { session.tutorial = article } label: {
            HStack(spacing: 16) {
                Image(systemName: article.symbol).font(.system(size: 26, weight: .semibold)).frame(width: 48, height: 48)
                    .background(Color.white.opacity(0.18)).clipShape(RoundedRectangle(cornerRadius: 13))
                VStack(alignment: .leading, spacing: 5) {
                    Text(article.title).font(.system(size: 16, weight: .semibold))
                    Text(subtitle).font(.system(size: 11)).opacity(0.85)
                }
                Spacer(); Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold))
            }.foregroundColor(.white).padding(.horizontal, 20).frame(maxWidth: .infinity, minHeight: 90, alignment: .leading)
                .background(LinearGradient(colors: [Color(red: 0.19, green: 0.59, blue: 0.94), Color(red: 0.15, green: 0.38, blue: 0.88)], startPoint: .topLeading, endPoint: .bottomTrailing))
                .clipShape(RoundedRectangle(cornerRadius: 16))
        }.buttonStyle(.plain)
    }
}

struct TutorialArticleView: View {
    let article: TutorialArticle
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack {
                Image(systemName: article.symbol).foregroundColor(PreferencesStyle.selectedText)
                Text(article.title).font(.system(size: 19, weight: .semibold)); Spacer()
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(article.sections, id: \.0) { title, text in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(title).font(.system(size: 13, weight: .semibold))
                            Text(text).font(.system(size: 12)).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            HStack { Spacer(); Button("好") { dismiss() }.keyboardShortcut(.defaultAction) }
        }.padding(26).frame(width: 540, height: 430).background(PreferencesStyle.page)
    }
}

struct AboutPreferencesView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var session: PreferencesSession
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 19) {
                PageHeader(title: "关于 Superbar", subtitle: "为 macOS 菜单栏而生")
                PreferenceCard {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 13) {
                            SuperbarMark(size: 58)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Superbar").font(.system(size: 18, weight: .semibold))
                                Text("版本 \(version) · MIT License").font(.system(size: 11)).foregroundColor(PreferencesStyle.secondary)
                            }
                        }
                        Text("Superbar 是一个开源的 macOS 菜单栏整理工具。布局、快捷键和图标预览均在本机处理。")
                            .font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                        Link("查看源代码", destination: URL(string: "https://github.com/amtbsl/superbar")!).font(.system(size: 12))
                    }
                }
                SectionTitle(title: "设置文件", symbol: "arrow.triangle.2.circlepath", color: PreferencesStyle.purple)
                PreferenceCard {
                    VStack(alignment: .leading, spacing: 11) {
                        Text("导出设置用于备份，导入时会先验证文件。无效文件不会改变当前设置。")
                            .font(.system(size: 11)).foregroundColor(PreferencesStyle.secondary)
                        HStack(spacing: 10) {
                            Button(action: session.exportSettings) { Label("导出设置", systemImage: "square.and.arrow.up") }.buttonStyle(.bordered)
                            Button(action: session.importSettings) { Label("导入设置", systemImage: "square.and.arrow.down") }.buttonStyle(.bordered)
                            Spacer()
                            Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([model.settingsURL]) }.buttonStyle(.link).font(.system(size: 11))
                        }
                    }
                }
                SectionTitle(title: "诊断", symbol: "stethoscope", color: PreferencesStyle.orange)
                PreferenceCard {
                    VStack(alignment: .leading, spacing: 9) {
                        Toggle("启用本地诊断日志", isOn: Binding(get: { model.settings.diagnosticsEnabled }, set: { _ = model.setDiagnosticsEnabled($0) }))
                            .toggleStyle(.checkbox).font(.system(size: 12))
                        Text("用于排查菜单栏问题，会在本机记录权限状态和图标名称。分享日志前请检查内容。")
                            .font(.system(size: 10)).foregroundColor(PreferencesStyle.secondary)
                    }
                }
                ModelStatusView(model: model)
            }.padding(28)
        }
    }
    private var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0" }
}
