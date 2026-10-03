# Feature scope and verification

The required scope includes the functionality advertised for iBar and iBar Pro, including per-icon shortcuts. The reference is the installed iBar 2.1.1 inspected on 2026-10-02 and the public [developer website](https://www.better365.cn/ibar.html) and [iBar Pro App Store description](https://apps.apple.com/us/app/ibar-pro-menubar-control-tool/id6737150304?mt=12). Superbar is independently implemented and uses no proprietary source or extracted artwork. These capabilities are free under the MIT license.

This table tracks the current reconstruction. Earlier builds and screenshots do not establish acceptance of this implementation. Automated results and native UI evidence are recorded separately.

Mechanism acceptance must establish the ordinary hide/reveal path and the aggregate activation sequence: targeted temporary placement, the real native app menu, menu-aware delay, then return. Offline selector and call-path analysis provides bounded mechanism evidence; framework imports and matching surface controls do not establish complete equivalence. Observed differences and unverified branches must remain explicit in the native acceptance record.

| Required behavior | Superbar implementation and acceptance criterion | Current verification |
| --- | --- | --- |
| General preferences | Native SwiftUI/AppKit sidebar and setting cards; every enabled control changes its corresponding setting, with no clipped controls at supported window sizes | Native preferences visual check and control interaction passed on macOS 26.5.1; see native acceptance below |
| Normal mode | Separators unfold hidden native menu extras; collapsing hides them again without reordering the menu bar | Pure separator-policy and movement-request tests pass; native check pending |
| Aggregation mode | Floating panel displays actual hidden menu extra icons; clicking temporarily places an item in the native menu bar and opens its real app menu | 18 actual icon captures and native system menu activation passed; temporary return awaits physical dismissal verification |
| Show / hide / always hide | Exclusive visibility states. Always-hidden items stay out of the aggregate panel and remain hidden when normal mode expands | Pure isolation, group boundary, and separator tests pass; native checks in both modes pending |
| Vertical layout drag ordering | Native settings list orders items by drag/drop and persists that order; explicit apply performs a bounded layout plan respecting fixed anchors | Pure order/anchor tests pass; explicit native layout completed and full geometry verified |
| Per-icon Pro shortcuts | Recorded physical key combinations can temporarily show/click the selected real item; conflicts include the global shortcut and disconnected rules | Validation, collision, and persistence tests pass; native registration, activation, and cleanup check pending |
| Global shortcut | Default `⌃⌥B` and a configurable shortcut reveal/return hidden items; ordinary reveal schedules no physical layout movement | Pure no-relayout and clear/reload tests pass; native shortcut check pending |
| Reveal triggers | Status icon, menu bar empty-space click, and empty-space hover; normal mode hover delay is 0.2 seconds, aggregate hover delay is 0.5 seconds | Empty-space click and status/menu reveal passed; hover verification pending |
| Adjustable automatic return | Delay is configurable from 1 to 60 seconds; open menus postpone return; temporary activation restores the item after its menu closes | Delay validation, stale-operation invalidation, and temporary-return movement prohibition tests pass; native elapsed-time and menu-dismissal checks pending |
| Status symbol and transparency | Custom SF Symbols, provided choices, and a transparent status item still offer a usable reveal target | Stored symbol/transparent-value validation tests pass; native visual/interaction check pending |
| Four menu extra gap choices | Default, compact, small, and no gap; system spacing preferences change and default restoration removes overrides | Native preference write/default restoration pending; visible spacing requires logout/restart and is unverified |
| Start at login | SMAppService registration reflects the requested setting and system approval state | Native registration/unregistration passed, restored disabled; login cycle unverified |
| Tutorials | Local instructions and FAQ open, navigate, and close without altering layout | Native tutorial, FAQ, and About navigation passed |
| Import/export and persistence | Versioned JSON; atomic saves; invalid imports and write failures keep the previous state; corrupt/invalid startup data is preserved for recovery | Round-trip, legacy and discovered-identity migrations, corruption repair, concurrent readers, and import/write-failure tests pass |
| Permissions | Accessibility controls native menu items; Screen Recording captures menu icon windows; missing access shows a clear state and allows a retry | Granted AX and Screen Recording verified; rebuild permission-record refresh passed |
| Routine operation and cleanup | Show/hide, polling, icon capture, menu dismissal, and ordinary settings do not request bulk movement; cancelled work and terminated sessions release their owned resources | Pure request policy and stale-generation tests pass; native idleness and actual resource cleanup check pending |
| Trial, purchase, and advertising | All functional capabilities are free; no trial limit, purchase flow, or advertising is included | Product policy; no live feature gate |

`scripts/test.sh` runs only deterministic production logic in temporary storage. It neither grants permissions nor sends synthetic UI/CG events. `scripts/build.sh` compiles an isolated app, independently verifies the Mach-O macOS 13.0 target and architecture, and checks its strict code signature. A build or pure-logic test pass does not demonstrate live control of third-party menu bar items.

On 2026-10-03, `zsh scripts/test.sh` passed 10,018 assertions against the current production model, store, layout planner, request policy, separator policy, and operation generation. The placement cases exhaust all 720 permutations of a six-token plan and all 2,520 seven-token arrangements preserving two fixed anchors. The persistence test reads 1,000 complete documents while a writer atomically commits 40 replacements. These are deterministic logic/storage checks, not native transport tests.

`scripts/release.sh --app /Applications/Superbar.app` packages an explicitly selected, already accepted app without rebuilding or signing it. It compares app bytes after ZIP extraction and read-only DMG mounting, verifies signatures again, and publishes SHA-256 checksums with a source commit and executable identity manifest. The deterministic git source archive excludes generated builds, private settings/diagnostics, and reference checkouts. The packaged source inputs must match the build receipt in the selected app. CI packaging is not a claim of native UI acceptance.

`scripts/test-packaging.sh` checks the standalone app verifier with isolated fixtures: wrong architecture, wrong plist minimum, a signed Mach-O with a higher deployment target, and a modified signed resource must all fail for the expected reason. It also checks source identity stability and compile-input change detection. This packaging guard suite passed against the installed app on 2026-10-03.

Root-led native acceptance and release results will be appended here only after completion. Multiple displays, all third-party menu apps, Intel execution, login cycles, visible spacing after a restart, and every supported macOS version remain separate hardware/software checks.

## Native acceptance, 2026-10-03

Hardware: Apple Silicon M3 Pro, macOS 26.5.1. Installed executable SHA-256: `54cbc4686ba44aeca48cd8447902700eee602bbb26b9196a33caec8e9c49a183`.

- The current app starts with AX and Screen Recording access and zero layout, gesture, or activation counts. It restores native separator positions without moving other apps' icons.
- An explicit layout completed and verified the full native order on the preceding build sharing the same mover/planner. Five necessary selected-window gestures finished; final pointer displacement after restoration was zero. The current build additionally freezes semantic identities throughout menu-return transactions and reads the displayed menu-bar owner.
- All 18 native items acquired real images, including Input Menu, Sound, Display, Wi-Fi, Battery and Now Playing. Privacy AudioVideoModule is excluded. Temporary WindowServer clones disappear after stable discovery rather than being used as guessed app identities.
- The aggregate screenshot is a 36-point native row, with actual glyph colors, native item widths and a neutral settings button. Ten configured hidden icons are present; no promotional UI is included.
- Clicking blank menu-bar space opens that row with zero placement gestures. Clicking Now Playing temporarily placed only that selected renderer at x=941, opened its real Control Center media popup, and restored the pointer exactly. Held synthetic button and hidden cursor flags were both false before waiting for menu dismissal. The popup remained open past the 15-second delay.
- Automated keyboard input did not dismiss that system popup; physical dismissal/temporary return is still pending. Global shortcut and hover activation are not claimed as passed by an automation key-delivery attempt.
- Settings export/import round-trip, tutorial/FAQ/About, and SMAppService registration/unregistration passed in the reconstruction session; login startup was restored disabled.

Full compatibility across macOS 13–27, multiple displays, Intel execution and every third-party item is unverified. Visible spacing changes need a logout/login cycle; this session did not interrupt the user's login session.
