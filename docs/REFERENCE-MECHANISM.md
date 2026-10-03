# iBar mechanism investigation

Reference: the locally installed iBar 2.1.1, build 2026082501, ARM64 executable, inspected on macOS 26.5.1. This record describes observed system interactions. It does not claim recovery of the original source or verification of every operating-system branch. The executable, extracted resources, and disassembly are kept outside the published source.

## Hiding and revealing native icons

The ordinary hidden group is bounded by a named `NSStatusItem` with length **5000**. macOS moves the icons on its left outside the visible menu bar to accommodate that wide item. This uses the menu bar's own layout.

The macOS 26 `hideAllIcon` path delegates to `newHideAllIconAfter:` with a saved preferred position. The relevant order is:

1. Make the normal hidden status item invisible.
2. Write the saved position to `NSStatusItem Preferred Position NormalHiddenStatusItem`.
3. Make that same status item visible again.

Writing the position after reinsertion is not equivalent. The reveal path makes the normal hidden item invisible; the permanent hidden boundary remains in place. Ordinary folding and automatic return do not call the per-icon mouse-drag routines.

## Clicking blank menu-bar space

The original owns a transparent nonactivating NSPanel at window level 101, containing `MenuBarView`, with a computed blank-space rectangle and a separate notch rectangle. Its host spans the native menu-bar height across the display. Drawing marks the intended input regions with very low alpha; other pixels remain transparent. This view receives mouse and tracking events. Superbar uses native panels limited to the computed regions, to keep application menus outside their window bounds.

`MenuBarView.mouseDown:` ignores modifier-bearing clicks and checks `showPanelWhenClick`. If its aggregate window is already visible, it closes it. Otherwise it schedules opening after 0.05 seconds. The anchor is a 10-point rectangle centered on the clicked x coordinate, using the native menu-bar item's vertical geometry.

Hover uses a cancellable timer: approximately 0.2 seconds for normal mode and 0.5 seconds for aggregate mode. Normal mode reveals the native group by making the normal divider invisible. Aggregate mode checks that the pointer remains in the blank-space or notch rectangle before showing its icon panel.

The original click callback itself has no normal-mode gate, while its input-region drawing also depends on separate advanced-mode preferences. Superbar consistently treats blank-space click as the aggregate trigger offered in its settings; normal-mode hover always reveals the native group. This is an explicit behavior clarification rather than a claim that all incidental reference branches are identical.

There is also an independent global blank-click monitor and split-item length path in the executable. Its installation is guarded by the system availability check for **macOS 27 or later**. It is not the active mechanism on the tested macOS 26.5.1 system and must not be mixed into the macOS 26 reconstruction.

## Capturing and activating an icon

The macOS 26 image path supplies **raw CGWindowID values**, rather than NSNumber object addresses, in a CFArray created without element callbacks. It calls `CGWindowListCreateImageFromArray` with `CGRectNull` and options `boundsIgnoreFraming | bestResolution`. Individual icons are cropped from the composite's central 24-point band. The system privacy indicator `AudioVideoModule` is excluded from discovery.

Explicit ordering and temporary activation have different transports. Ordering uses a selected-window Command gesture and at most five renderer down/up handshakes within that single operation. Temporary activation uses an offscreen Command down, a mouse-moved event to the target, and an up. A selected-window click is then sent to the actual renderer PID. Native geometry and an opened menu must establish success.

Return after activation reuses divider position restoration. It does not drag the icon back with the mouse. The temporary-show path hides the cursor through a WindowServer connection property and CGDisplayHideCursor, restores its saved position after the session release, and balances the hide count. Superbar follows this cursor lease and additionally yields immediately to real user input. Startup restores native divider placement without Command gestures. A visibility checkbox or row drag places only its selected icon; a complete ordering pass requires the explicit Apply Layout action.

Implementation and acceptance status: [ARCHITECTURE.md](ARCHITECTURE.md), [FEATURES.md](FEATURES.md).

## Target X, return checkpoint, and native order: address-level evidence

This narrower investigation concerns the selected macOS 26 temporary-show path and its native return. All addresses below belong to the same ARM64 reference executable identified above. The formulas are independently transcribed from register dataflow; final WindowServer insertion still requires live geometry verification.

| Method | IMP | Selector reference / message stub |
| --- | --- | --- |
| `showIconWithWindowIDOverMacOS26:ofPID:` | `0x100063fb4` | `0x1000da6c8` / `0x1000901a0` |
| `Global.hideAllIcon` | `0x1000702a4` | `0x1000d8860` / `0x100088800` |
| `Global.newHideAllIconAfter:` | `0x100070310` | `0x1000d9088` / `0x10008a8a0` |
| `MenuBarWindowController.rightLengthOfMenuBarChanged` | `0x1000672f0` | `0x1000d9728` |

### Temporary-show target

Let `R` be the selected renderer's Quartz rectangle, `W = R.width`, `M` the main status item's window rectangle converted by `Global.cgWindowRectToScreenRect:`, `S` the current screen, `P` the saved blank-space rectangle returned by `getMenuBarViewSpace`, and `t(x)` signed truncation toward zero. The main-window lookup at `0x1000640f8` uses `AppDelegate.statusItem` (`0x100090800`), not `statusItemOfNormalHidden`. At `0x100064178–18c`, the method directly clicks when `M.minX - R.maxX < 5000`; the remaining formula applies to the offscreen temporary-show case.

The exact destination calculation is:

```text
C = t(S.minX + t(P.maxX - W))
L = t(P.minX)
if currentScreenHaveNotch:
    L = t(max(L, notch.maxX + 20))
L = t(S.minX + L)
if C < L:
    C = t(first(sortedRightSideRenderers).minX - W)

mainCenter = M.minX + M.width / 2
targetX = (mainCenter > C ? C : t(mainCenter - W)) + 4
```

Candidate truncation occurs at `0x10006424c` and `0x100064270`; notch and lower-bound handling at `0x10006427c–338`; the first-rectangle fallback at `0x100064344–378`; final comparison and selection at `0x1000643c4–3ec`. The last conditional is not mathematically equivalent to `min(C, mainCenter - W)`. The reference uses this X for a Command `mouseMoved` and up, at Quartz menu-bar top + 1; the initial down is at −16000 and top + 7. The selected window ID remains the event target.

`P` comes through `AppDelegate.menuBarWindowController.window.contentView.getMenuBarViewSpace` (`0x1000641d4–218`). The method at `0x100067634` returns `rectOfSpace` through message stub `0x10008b8a0`. `MenuBarView.getMenuBarSpace` (`0x1000684f0`) computes the rectangle from its view frame `V` and the integer left/right lengths:

```text
P.minX = V.minX + leftLength
P.width = V.width - leftLength - rightLength - 4
```

If either length is zero it returns a zero rectangle. In aggregate mode, `rightLengthOfMenuBarChanged` reads `AppDelegate.statusItemOfNormalHidden.button.window.frame` (`0x10006745c–498`) and computes:

```text
rightLength = t(S.maxX - normalDivider.maxX - G.width)
```

Here `G` is a global CGRect at `0x1000e0880`; its width is loaded from `0x1000e0890` at `0x1000674d4`. With the full-display host frame and before integer truncation, `P.maxX + S.minX = normalDivider.maxX + G.width - 4`. Thus the temporary destination is normally near the normal divider's right edge, subject to the notch/fallback and main-center conditional. It is not simply an instruction to insert immediately before MAIN.

The fallback helper first finds the normal divider `D`, then collects named layer-25 renderers on exactly the same row whose `minX >= D.maxX`. Its result includes MAIN and is sorted by X. It does not return `D` itself or an arbitrary on-screen window. Superbar uses strict X ordering and refuses to send a temporary gesture when stable divider geometry is unavailable; the reference's unguarded empty result can instead reuse stale divider geometry.

The located writes to `G` (`0x10006b078–090` and `0x10006c394–3b8`) store the first sorted renderer rectangle only when its left edge exactly equals the normal divider's right edge; otherwise they store zero. Those writes are in older-system bodies. `getAllItemsInfoWhenStart` skips that body through `0x10006b6b8–6d4`, and `refreshAllItemsInfoForCheck` dispatches to `OverMacOS26` through `0x10006a124–18c`. `G` is zero-initialized in `__common`. The observed formula must retain its actual `G.width` value; these older writes do not justify adding an adjacent icon width on the macOS 26 path.

### Return checkpoint

At `0x1000702e4–30c`, `hideAllIcon` reads the application key **`PositionItem-0`** (CFString `0x1000c4770`) and passes that integer to `newHideAllIconAfter:`. It does not take the normal divider's current preferred position as its return checkpoint. Before reinsertion, `newHideAllIconAfter:` compares the main item's current native preferred position with this saved integer (`0x100070350–35c`) and returns immediately when `mainPreferredPosition > savedPosition`.

The modern branch then performs precisely:

```text
normalDivider.isVisible = false                 // 0x1000703dc–3e0
defaults["NSStatusItem Preferred Position NormalHiddenStatusItem"]
    = savedPosition                            // 0x1000703f4–404
normalDivider.isVisible = true                  // 0x10007042c–430
```

If the divider is absent, it first calls `addStatusItemOfNormalHidden` at `0x1000703b4`. No selected-icon drag or target-window argument participates in this return.

The source of the application checkpoint is also visible: `AppDelegate.observeValueForKeyPath:ofObject:change:context:` (IMP `0x10005de2c`) handles changes to **`NSStatusItem Preferred Position iBarStatusItem`** at `0x10005dee4–df0c`. For main preferred positions 1 through 1499, its unsigned range test at `0x10005df10–1c` enters `0x10005e020–02c` and stores that main position into `PositionItem-0`. Its other branch restores the main preferred-position key from `PositionItem-0` at `0x10005df34–74`. Consequently the return key is a saved main/boundary position, not an arbitrary expanded-divider snapshot.

### Native ordering established by the reference

The main item is the left boundary of the configured always-displayed group. This is directly supported by two independent paths:

- In `OverMacOS26.refreshAlwaysDisplayAndNormalHiddenMenuBarOverMacOS26` (IMP `0x10004df4c`), the main rectangle is read from `iBarItemRect` and its right edge retained (`0x10004dfc8–fec`, `0x10004e090`). Renderer candidates with `icon.minX >= main.maxX` take the visible-candidate branch (`0x10004e204–284`). Those candidates are added to `arrOfAlwaysDisplay` and removed from `arrOfNormalHidden` (`0x10004e548–57c`), then persisted (`0x10004e6e0–704`). Icons to the main item's left enter the hidden-candidate branch.
- `Preferences.displayOrHiddenMenuBarItems` (IMP `0x100042724`, block `0x100042848`) processes the visible array at `0x1000e0858`. Its array identity follows the `arrOfAlwaysDisplay` checks at `0x10004c254–268` and `0x10004c3a8–3bc`. The placement loop queries `getAlwaysDisplayAfterRectWithIdentifier:` (`0x100088000`), selects that anchor unless its X is left of MAIN (`0x100042a74–7c`), and calls the native mover with `anchor.centerX + 2` (`0x100042ac0–adc`). This places visible items toward MAIN's right side.

The required partial order is therefore **normal-hidden side → normal boundary / MAIN → configured visible items**, with the permanent hidden boundary retaining its independent role. These methods establish the group boundary and MAIN's side; they do not establish a unique order for every fixed system item. Putting MAIN after all configured visible items conflicts with this classification and checkpoint convention.

For the reported Superbar case—Display initially offscreen, temporary insertion before MAIN at 1286, then divider restoration to its separately saved 839—the original formulas support two concrete mismatches: the insertion target ignores the divider-derived blank-space edge, and the return checkpoint is not the reference's saved main/boundary checkpoint. This is a diagnosis from the reported geometry plus static reference evidence, not a live verification of a replacement implementation. Ordinary return must continue using native preferred-position reinsertion without synthetic input.

### Return timer ownership

The click path at `0x100062e74–ef0` and `showIconWithIdentifier:` at `0x100063ec8–f44` invalidate the previous global timer, then use `delayTimeHideIconAgain` to create a nonrepeating `NSTimer` targeting `hideAllLeftIcon`. That target at `0x100064bd0` calls `Global.hideAllIcon`. The return responsibility therefore belongs to a timer independent of a single placement gesture. This inspected path has no additional 120-second abandonment branch.

Superbar's menu-aware protection is an improvement over that timer: a pending return must survive a later activation and wait while a real native interface remains open. Waiting owns no synthetic button or cursor lease. Once the interface closes and the configured delay is satisfied, restoration must use the same native separator checkpoint path described above.
