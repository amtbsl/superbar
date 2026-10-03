# Full reconstruction acceptance contract

The reconstruction uses GPT-6.1-Sol workers with max reasoning at the user's request. This document defines the intended behavior; it is not a claim that native verification has passed.

## Architecture

- Persisted configuration, transient UI state, native window discovery, layout planning, native event delivery, separator visibility, and icon capture have separate responsibilities.
- A pure layout planner operates on stable icon identities, visibility groups, fixed anchors, and current geometry. The runtime uses this same planner.
- Quartz renderer identity and Accessibility application identity remain separate. A valid renderer window and its actual owner PID are required before sending an event. Negative proxy window numbers are never converted to unsigned identifiers.
- The installed app's current geometry is authoritative. A posted event or delivery acknowledgement cannot stand in for an observed movement.
- The app releases observers, event taps, timers, held synthetic buttons, captures, and tasks when cancelled or stopped.

## Mouse behavior

Normal reveal and conceal only change separator visibility and restore its saved native position. Aggregation reveal and dismissal only show or hide the local icon panel and update the separator state. Hover, ordinary automatic return, list refresh, capture completion, polling, and panel dismissal must not invoke native icon movement, keyboard synthesis, cursor hiding, or cursor warping.

Only a genuine visibility change or explicit reorder/application may request native movement. Startup restores native separator positions without sending movement events. Layout operations are serialized and bounded. Real pointer input takes priority and ends the synthetic operation. An unchanged visibility value produces no layout request. A failed layout stays visible and waits for the user to apply it; there are no repeating automatic repair gestures.

An explicit icon activation may temporarily move that one icon into the native bar for its real menu. Return after the configured delay and menu closure restores the separator's native preferred position and visibility, with zero synthetic movement. This matches the reference's macOS 26 routine hide path. Real input takes priority during explicit placement. Always-hidden groups are never expanded by activation.

## Required product behavior

1. Normal mode reveals native hidden icons after 0.2 seconds over blank menu-bar space, independent of the aggregation trigger preference.
2. Aggregation mode displays the actual hidden icons locally and activates their real menus. Always-hidden icons are excluded.
3. Visible, hidden, and always-hidden states are exclusive and survive restart. Ordering changes are persisted and reflected in native positions.
4. Global and per-icon shortcuts, icon/click/hover triggers, configurable automatic return, spacing, login startup, status-symbol/transparent choice, settings export/import, and tutorials remain functional.
5. The native settings UI corresponds to the reference's organization and controls, with suitable sizing. Trial, purchase, recommended products, and promotional UI are omitted.
6. Existing user preferences survive reconstruction. Permission grants remain within the previously authorized Accessibility and Screen Recording scope.

## Evidence required before completion

- Meaningful pure-logic tests use the same planner and state transitions as the app.
- The final installed binary builds for macOS 13 or later, has verified architecture and signature, and passes native interaction and visual checks on this Mac.
- During ordinary reveal, conceal, refresh, capture, and menu dismissal, movement counters stay unchanged while normal mouse input remains usable.
- GitHub contains the complete browsable source with an open-source license and downloadable release assets matching the tested binary and published checksums.
- Only after those checks, iBar and Hidden Bar are closed and moved to recoverable Trash with their exact app-specific residuals; unrelated Better365 apps are preserved.

Other macOS releases, Intel execution, multiple displays, and unusual third-party status items require their own verification. Those boundaries must be described accurately in the release documentation.
