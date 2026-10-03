# Superbar

A free, open-source macOS menu bar organizer. 独立开发的 macOS 菜单栏图标管理工具，所有功能免费，使用 MIT 许可。

[下载 macOS 安装包 / Download](https://github.com/amtbsl/superbar/releases/latest)

Superbar follows the interaction model of iBar's menu bar manager: a floating bar, a normal folding mode, a visibility/order table, and native preferences. It contains no iBar source code, binaries, extracted assets, license checks, advertising, or purchase screens, and is not affiliated with its developer. Branding and artwork are independently drawn.

## Features

- **聚合模式**：将隐藏图标放入菜单栏下方的浮窗；点击访问原应用的菜单。
- **普通模式**：直接展开或折叠菜单栏中的图标；悬停空白菜单栏 0.2 秒展开。
- **三种可见性**：显示、隐藏、始终隐藏；始终隐藏的图标不进入聚合栏。
- **布局**：拖动设置表格中的图标来排序，保存每个图标的可见性。
- **快捷键**：全局展开/收回（默认 `⌃⌥B`），以及每个图标的显示与点击快捷键。
- **触发**：点击 Superbar 图标、点击菜单栏空白处、悬停空白处。
- **自动收回**：1–60 秒延迟；菜单操作期间避免收回。
- **个性化**：多种菜单栏图标和透明图标；系统图标间距设置。
- **开机自启动**、本地教程、设置 JSON 导入/导出。

## Build

macOS 13 or later, Xcode Command Line Tools. No third-party dependencies.

```sh
zsh scripts/test.sh
zsh scripts/build.sh
open build/Superbar.app
```

Output: `build/Superbar.app`. The build explicitly targets macOS 13 and verifies its ad hoc code signature and Mach-O deployment target. On Intel, build on an Intel Mac or set `SUPERBAR_ARCH=x86_64`; the published initial binary is Apple Silicon.

## Permissions and first use

1. Install Superbar in `/Applications` and run it. Keep only one menu bar manager running.
2. In its preferences, enable **Accessibility** to control and reorder menu extras.
3. Enable **Screen Recording** to show screenshots of the actual menu bar icons. Capture is limited to menu bar icon windows and their visible icon rectangles; there is no video recording, saved image history, server, analytics, or upload. Without this permission, each system item uses its own semantic symbol and third-party items use their application icon as a fallback.
4. Open **菜单栏布局**, select icons to hide, and apply the layout. System-owned fixed items may reject dragging; Superbar reports those failures.
5. Click the Superbar icon or press `⌃⌥B` to reveal hidden icons.

macOS protects these permissions; grant them in System Settings when prompted. After changing Screen Recording permission, quit and reopen Superbar. Menu bar spacing changes use the system preference keys and require logging out and in or restarting to take effect. Choose 默认间隙 to restore the spacing values that were present before Superbar changed them.

本地构建使用临时签名。重新编译或更新后，如果系统设置显示权限已开但 Superbar 仍提示未授权，请在对应权限列表中选中 **Superbar**，用减号移除旧记录，再用加号添加 `/Applications/Superbar.app`，然后重新打开应用。不要修改其他应用的权限。

The downloadable app is ad hoc signed and **not Apple-notarized**. Build from source or use the normal System Settings approval flow for downloaded unsigned software.

## Configuration and diagnostics

Settings are atomically saved to `~/Library/Application Support/Superbar/settings.json`. `--diagnostics` enables a local `diagnostics.json` in that directory for permission and layout troubleshooting; it can contain the names of running menu bar apps, so review it before sharing. Diagnostics are off by default.

```sh
open /Applications/Superbar.app --args --settings --diagnostics
zsh scripts/release.sh --app /Applications/Superbar.app
```

## Practical limits

macOS offers no public API for freely managing other apps' menu bar items. Superbar uses Accessibility, window metadata, and separator geometry. Explicit placement uses bounded window-targeted Command gestures. Ordinary reveal, concealment, and return after an aggregation click restore the separator’s saved native position and visibility; they send no mouse events. The macOS 26 aggregation activation sequence was established through read-only analysis of the installed iBar method call paths, with real input taking priority as an improvement. Some system items cannot move; some third-party items do not expose accessible labels or a standard press action. Icons recreated by an app can change identifiers. Layout and capture behavior depend on the macOS release, permissions, display arrangement, and available menu bar space. See [architecture](docs/ARCHITECTURE.md) and [feature verification](docs/FEATURES.md) for the mechanism and the status actually tested.

## License

[MIT](LICENSE). Source repository: [amtbsl/superbar](https://github.com/amtbsl/superbar).
