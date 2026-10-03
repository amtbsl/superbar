# Menu bar architecture

Superbar separates native layout, ordinary presentation, image capture, persisted settings, and preferences. An event delivery acknowledgement is never treated as proof that a window moved: native geometry must change as expected.

## Reference investigation

The reference is the installed iBar 2.1.1 (2026082501), inspected on macOS 26.5.1. Its preferences and menu bar windows were observed through the native UI. Read-only analysis of its Objective-C method metadata and ARM64 system-call paths established the mechanisms below. This goes beyond an imported-symbol inventory. No reference executable, disassembly, implementation, or artwork is distributed with Superbar.

| Operation | Directly observed reference mechanism | Superbar contract |
| --- | --- | --- |
| Ordinary conceal | A normal separator is an NSStatusItem of length 5000. Its saved native position is restored while its visibility is toggled off and on. | Restore the separator's native position and visibility; send no mouse events. |
| Ordinary reveal | The normal separator becomes invisible. The system makes room for the icons. | Toggle the separator; preserve the always-hidden boundary. |
| Automatic return | hideAllIcon delegates to separator restoration. The reference's per-icon drag-to-hide routine is used by visibility changes, not the popup timer. | Use the same separator restoration for ordinary return and return after icon activation. |
| Explicit layout changes | Window-targeted Command gestures change native icon placement; geometry is checked. | Serialize bounded placement operations and verify actual window positions. |
| Aggregation images on macOS 26 | Menu bar window IDs are collected, composited, and cropped into individual icons. | Capture only the identified menu bar windows locally and publish actual icon images. |
| Aggregation activation on macOS 26 | Temporarily show one selected icon with a dedicated session event sequence, then deliver a click to the Control Center renderer with that window ID. | Reveal and activate only the selected icon; restore concealment through the separator. |
| Hover and return timing | Pointer entry/exit, delay timers, and menu-window closure observations control presentation. | Passive pointer observation and cancellable timers; no background layout repair. |

The macOS 26 reference uses an HID-state event source but posts into the **session** event stream. Temporary activation sends Command mouse-down at x = -16000, Command mouse-moved to the target, then Command mouse-up. Explicit ordering uses a different sequence: Command mouse-down at x = +16000, a mouse-dragged event, and up to five renderer down/up handshakes inside the same placement transaction. Source state and event-stream destination are distinct. The click routine targets com.apple.controlcenter, with the selected window fields and a click count of one; the application's Accessibility PID is not necessarily the renderer PID.

The reference also contains a separate macOS 27 path. That path's existence is not evidence that it runs on this Mac. Future macOS support and Intel execution need independent native verification.

## Daily presentation and mouse ownership

The divider, rather than a synthetic pointer gesture, handles concealment. The main status item sits between the hidden boundary and the visible group. Before an explicit temporary reveal, the engine records MAIN's native preferred position. On return, it hides the normal divider, writes that saved MAIN position under the divider's AppKit autosave key, and makes the divider visible again. Native reflow places the hidden group behind the divider. This is also the return path after an aggregation click.

Refresh, capture completion, hover, panel dismissal, and automatic return cannot request native movement. A visibility checkbox or an ordering drag may place only its selected icon. The Apply Layout button may run a complete ordering pass. Startup restores named native divider positions without synthetic movement. Failed placement is reported; polling never retries it.

During a selected-window gesture, Superbar follows the reference's background cursor-hide and restore mechanism. Its balanced cursor lease ends before geometry verification waits, including on cancellation. Real pointer input takes priority; a user interruption does not cause a later cursor warp.

## Window identity and capture

Accessibility identifies the app and menu item; Quartz identifies the renderer and native window. These identities remain separate. On this Mac, third-party menu bar windows can be hosted by Control Center even though Accessibility belongs to the third-party application.

Superbar's AppKit status windows can have a proxy windowNumber of -1. Checked conversion and a strict geometry match resolve the actual renderer. A negative number is never converted into an unsigned window ID. On macOS 26.5.1, single-window Quartz queries can return empty while the all-window list contains the window, so discovery filters the full list.

The reference batch capture passes a CFArray of raw window IDs, CGRectNull, and boundsIgnoreFraming | bestResolution to CGWindowListCreateImageFromArray. NSNumber objects are not valid raw window-ID entries. Its macOS 26 discovery excludes the Control Center privacy indicator AudioVideoModule. Superbar scans the complete cropped alpha channel, keeps semantic system identities separate from their renderer PID, invalidates images when geometry/scale/appearance changes, and refreshes live icons locally. A capture fallback uses the selected system item's symbol instead of one shared Control Center application icon. Captured images stay in memory and are used only for the local panel and layout table. Capture does not move icons. Always-hidden icons are excluded from the aggregation panel. Capture generations prevent a cancelled or older request from replacing current images.

## Aggregate appearance

The aggregate is a single 36-point row with 6-point rounded corners and native item widths. Actual captured glyphs retain their menu-bar colors. A tiny local sample of the menu-bar background window supplies the backdrop; the menu material and captured-glyph contrast provide a permission-aware fallback. Buttons use neutral native hover feedback, and overflow scrolls within a viewport that preserves the settings button and the final icon's hit area.

## Settings and lifecycle

Named model mutations validate and atomically save configuration before publishing it. No-op values do not emit a layout change. Existing JSON settings and icon rules survive reconstruction. Preferences opening and shortcut recording have no layout side effects. Shortcut registration changes incrementally and is suspended only while a recorder has focus.

The application coordinator owns services and disconnects them on exit. Optional local diagnostics record geometry, routing, layout counts, and activation counts without scheduling actions. Diagnostics and local reference-analysis files are excluded from source and releases.

## Verification

Tests share the runtime planner and scheduling policies. Native acceptance additionally requires real menus to open, geometry to match persisted visibility and order, and routine presentation to leave movement counters unchanged. A successful build alone does not establish these properties. [FEATURES.md](FEATURES.md) records the current verification status.

Public product descriptions are available on the [iBar developer page](https://www.better365.cn/ibar.html) and [iBar Pro App Store page](https://apps.apple.com/us/app/ibar-pro-menubar-control-tool/id6737150304?mt=12). Superbar is an independent implementation and is not affiliated with the reference vendor.
