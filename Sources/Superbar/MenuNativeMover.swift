import AppKit
import ApplicationServices
import CoreGraphics

/// The sole owner of native Command movement. It performs one window-targeted
/// gesture and observes real renderer geometry. Explicit positioning uses a
/// bounded renderer handshake within that gesture. Real input always wins.
@MainActor final class MenuNativeMover {
    enum Style { case position, temporaryReveal }
    struct Result {
        let moved: Bool
        let stage: String
        let frame: CGRect?
    }
    private struct HeldButton {
        let release: CGEvent
        let pid: pid_t
        let pointer: CGPoint?
        let inputGeneration: UInt64
        let pointerGeneration: UInt64
        let syntheticStart: CGPoint
        let syntheticEnd: CGPoint
    }
    private let discovery: MenuWindowDiscovery
    private let pointer: MenuPointerMonitor
    private var lifetime = MenuOperationGeneration()
    private var held: HeldButton?
    private var cursorLease: MenuCursorLease?
    private(set) var attempts = 0
    private(set) var rendererHandshakeCount = 0
    private(set) var lastRendererHandshakeCount = 0
    private(set) var lastMovement: [String: Any] = [:]
    private(set) var lastResult = "idle"
    private(set) var lastPointerDisplacement: Double?
    private(set) var running = false

    init(discovery: MenuWindowDiscovery, pointer: MenuPointerMonitor) {
        self.discovery = discovery; self.pointer = pointer
    }

    var hasHeldButton: Bool { held != nil }
    var cursorIsHidden: Bool { cursorLease != nil }
    var userIsInteracting: Bool {
        let flags: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]
        return CGEventSource.buttonState(.hidSystemState, button: .left)
            || CGEventSource.buttonState(.hidSystemState, button: .right)
            || CGEventSource.buttonState(.hidSystemState, button: .center)
            || !CGEventSource.flagsState(.hidSystemState).intersection(flags).isEmpty
    }

    /// A bounded wait observes input; it neither blocks nor modifies it.
    func waitForQuiet(maximum: TimeInterval = 0.65) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + maximum
        repeat {
            guard !Task.isCancelled else { return false }
            if !userIsInteracting, ProcessInfo.processInfo.systemUptime - pointer.lastInputTime >= 0.16 { return true }
            try? await Task.sleep(nanoseconds: 25_000_000)
        } while ProcessInfo.processInfo.systemUptime < deadline
        return false
    }

    func cancelAndRelease() {
        lifetime.advance()
        releaseHeldDirectly()
    }

    func move(windowID: CGWindowID, before anchorID: CGWindowID, style: Style = .position,
              temporaryTargetX: CGFloat? = nil) async -> Result {
        if #available(macOS 26.0, *) { return await moveCurrent(windowID: windowID, before: anchorID, style: style, temporaryTargetX: temporaryTargetX) }
        return await moveLegacy(windowID: windowID, before: anchorID)
    }

    /// Independent implementation of the observed iBar macOS 26 mechanism:
    /// raw selected-window targeting, HID source, session delivery, real frame
    /// observation. The temporary-show path is session-only; the explicit
    /// position path includes the original bounded PID geometry handshake.
    private func moveCurrent(windowID: CGWindowID, before anchorID: CGWindowID, style: Style,
                             temporaryTargetX: CGFloat?) async -> Result {
        lastMovement = [:]
        guard !running else { return result(false, "operation-already-running", frame: nil) }
        guard AXIsProcessTrusted(), !Task.isCancelled, !userIsInteracting,
              let original = discovery.window(windowID), let anchor = discovery.window(anchorID),
              original.id != anchor.id, MenuLayoutPlanner.usable(original.frame), MenuLayoutPlanner.usable(anchor.frame),
              let source = MenuNativeEvents.source() else {
            return result(false, "invalid-target-or-user-input", frame: nil)
        }
        // Earlier placements in this same layout can already move both live
        // anchors into the correct order. Avoid a redundant gesture and do
        // not mistake unchanged, already-correct geometry for a failure.
        if style == .position, immediatelyBefore(original.frame, anchor.frame) {
            lastRendererHandshakeCount = 0
            return result(true, "already-positioned", frame: original.frame)
        }
        running = true
        let lease = lifetime.advance()
        let inputGeneration = pointer.generation
        let coordinates = MenuCoordinates.current
        let screen = coordinates.screens.first { $0.contains(CGPoint(x: anchor.frame.midX, y: anchor.frame.midY)) }
            ?? coordinates.screens.first ?? CGRect(x: 0, y: 0, width: 1, height: coordinates.primaryTop)
        let top = coordinates.quartzRect(screen).minY
        let start = CGPoint(x: style == .temporaryReveal ? -16_000 : 16_000,
                            y: style == .temporaryReveal ? top + 7 : original.quartzFrame.minY + 7)
        // The renderer inserts before the item hit at its center. A target
        // at the left edge can hit its preceding neighbor after reflow.
        let end = CGPoint(x: style == .temporaryReveal ? (temporaryTargetX ?? anchor.quartzFrame.minX - 0.5) : anchor.quartzFrame.midX + 2,
                          y: style == .temporaryReveal ? top + 1 : original.quartzFrame.minY + 7)
        lastMovement = ["style": style == .position ? "position" : "temporaryReveal",
                        "windowID": original.id, "rendererPID": original.pid, "anchorID": anchor.id,
                        "originalFrame": MenuWindowDiscovery.components(original.frame),
                        "originalAnchorFrame": MenuWindowDiscovery.components(anchor.frame),
                        "target": [Double(end.x), Double(end.y)]]
        let fallback = CGPoint(x: original.quartzFrame.midX, y: original.quartzFrame.midY)
        let movementType: CGEventType = style == .temporaryReveal ? .mouseMoved : .leftMouseDragged
        guard let down = MenuNativeEvents.mouse(.leftMouseDown, at: start, window: original.id, pid: original.pid,
                                               source: source, command: true, hitTestFields: false),
              let movement = MenuNativeEvents.mouse(movementType, at: end, window: original.id, pid: original.pid,
                                                   source: source, command: true, hitTestFields: false),
              let up = MenuNativeEvents.mouse(.leftMouseUp, at: end, window: original.id, pid: original.pid,
                                             source: source, command: true, hitTestFields: false),
              let release = MenuNativeEvents.mouse(.leftMouseUp, at: fallback, window: original.id, pid: original.pid,
                                                  source: source, hitTestFields: false) else {
            running = false
            return result(false, "event-creation-failed", frame: nil)
        }
        attempts += 1
        lastRendererHandshakeCount = 0
        held = HeldButton(release: release, pid: original.pid, pointer: CGEvent(source: nil)?.location,
                          inputGeneration: inputGeneration, pointerGeneration: pointer.pointerGeneration,
                          syntheticStart: start, syntheticEnd: end)
        cursorLease = MenuCursorLease()
        cursorLease?.hide()
        lastMovement["backgroundCursorEnabled"] = cursorLease?.backgroundEnabled ?? false
        defer { releaseHeldDirectly(); running = false }
        MenuEventDelivery.postSession(down)
        // Yield before the second event so newly arrived real input can win.
        try? await Task.sleep(nanoseconds: 5_000_000)
        guard lifetime.accepts(lease), !Task.isCancelled, pointer.generation == inputGeneration else {
            releaseHeldDirectly()
            return result(false, "interrupted-by-user", frame: discovery.window(windowID)?.frame)
        }
        MenuEventDelivery.postSession(movement)
        cursorLease?.hide()
        if style == .position {
            // One session down+drag owns the gesture. The renderer needs up
            // to five down/up handshakes before it commits the new position;
            // an event ACK is never used as evidence of actual movement.
            // This bounded loop is reachable only by an explicit layout.
            for _ in 0..<5 {
                guard lifetime.accepts(lease), !Task.isCancelled, pointer.generation == inputGeneration else {
                    releaseHeldDirectly()
                    return result(false, "interrupted-by-user", frame: discovery.window(windowID)?.frame)
                }
                guard let renderer = discovery.window(windowID), renderer.pid == original.pid else {
                    releaseHeldDirectly()
                    return result(false, "renderer-changed", frame: nil)
                }
                rendererHandshakeCount += 1
                lastRendererHandshakeCount += 1
                lastMovement["rendererHandshakes"] = lastRendererHandshakeCount
                MenuEventDelivery.postRenderer(down, pid: renderer.pid)
                try? await Task.sleep(nanoseconds: 10_000_000)
                guard lifetime.accepts(lease), !Task.isCancelled, pointer.generation == inputGeneration else {
                    releaseHeldDirectly()
                    return result(false, "interrupted-by-user", frame: discovery.window(windowID)?.frame)
                }
                MenuEventDelivery.postRenderer(up, pid: renderer.pid)
                try? await Task.sleep(nanoseconds: 10_000_000)
                guard lifetime.accepts(lease), !Task.isCancelled, pointer.generation == inputGeneration else {
                    releaseHeldDirectly()
                    return result(false, "interrupted-by-user", frame: discovery.window(windowID)?.frame)
                }
                let windows = discovery.allWindows()
                if let frame = windows.first(where: { $0.id == windowID })?.frame,
                   let liveAnchor = windows.first(where: { $0.id == anchorID })?.frame {
                    let changed = abs(frame.midX - original.frame.midX) > 0.5
                    let placed = immediatelyBefore(frame, liveAnchor)
                    lastMovement["handshakeFrame"] = MenuWindowDiscovery.components(frame)
                    lastMovement["handshakeAnchorFrame"] = MenuWindowDiscovery.components(liveAnchor)
                    lastMovement["handshakePlaced"] = placed
                    // The reference handshake ends as soon as the renderer
                    // center changes. Adjacency is established only after
                    // the final session up; checking it while still held
                    // would needlessly repeat the native down/up handshake.
                    if changed { break }
                }
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        } else {
            _ = await waitForChange(windowID, original: original.frame, lease: lease,
                                    inputGeneration: inputGeneration, milliseconds: 200)
        }
        guard lifetime.accepts(lease), !Task.isCancelled, pointer.generation == inputGeneration else {
            releaseHeldDirectly()
            return result(false, "interrupted-by-user", frame: discovery.window(windowID)?.frame)
        }
        let saved = held
        MenuEventDelivery.postSession(up)
        cursorLease?.hide()
        held = nil
        try? await Task.sleep(nanoseconds: 10_000_000)
        if let saved { restoreSyntheticPointer(saved) }
        releaseCursor()
        // WindowServer may commit the reflow after the selected gesture is
        // released. This observation wait holds neither a button nor cursor.
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        var stable = 0
        var previous: CGRect?
        while ProcessInfo.processInfo.systemUptime < deadline {
            guard lifetime.accepts(lease), !Task.isCancelled, pointer.generation == inputGeneration else {
                return result(false, "interrupted-by-user", frame: discovery.window(windowID)?.frame)
            }
            let windows = discovery.allWindows()
            if let frame = windows.first(where: { $0.id == windowID })?.frame,
               let anchor = windows.first(where: { $0.id == anchorID })?.frame {
                lastMovement["finalFrame"] = MenuWindowDiscovery.components(frame)
                lastMovement["finalAnchorFrame"] = MenuWindowDiscovery.components(anchor)
                let changed = abs(frame.midX - original.frame.midX) > 0.5
                // Other pending tokens can remain between this item and its
                // anchor until the complete plan places them. The gesture
                // verifies the requested side; the engine verifies all order
                // relationships after the complete explicit pass.
                if changed && frame.maxX <= anchor.minX + 2 && abs(frame.midY - anchor.midY) < 12 {
                    stable = previous == frame ? stable + 1 : 1
                    if stable >= 2 { return result(true, "position-verified", frame: frame) }
                } else { stable = 0 }
                previous = frame
            }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        return result(false, "position-not-verified", frame: discovery.window(windowID)?.frame)
    }

    private func moveLegacy(windowID: CGWindowID, before anchorID: CGWindowID) async -> Result {
        guard !running else { return result(false, "operation-already-running", frame: nil) }
        guard AXIsProcessTrusted(), !Task.isCancelled, !userIsInteracting,
              let original = discovery.window(windowID), let anchor = discovery.window(anchorID),
              original.id != anchor.id, MenuLayoutPlanner.usable(original.frame), MenuLayoutPlanner.usable(anchor.frame) else {
            return result(false, "invalid-target-or-user-input", frame: nil)
        }
        running = true
        let lease = lifetime.advance()
        let inputGeneration = pointer.generation
        let sourcePID = original.pid // The renderer, which can differ from AX's application PID.
        // A targeted off-desktop down selects the renderer without clicking
        // its menu. The release targets the next item's renderer, with Command
        // cleared. A mouseDragged event is unnecessary and changes routing.
        let start = CGPoint(x: 20_000, y: 20_000)
        let end = MenuCoordinates.current.quartzPoint(CGPoint(x: anchor.frame.minX - 0.5, y: anchor.frame.midY))
        let fallback = MenuCoordinates.current.quartzPoint(CGPoint(x: original.frame.midX, y: original.frame.midY))
        guard let source = MenuNativeEvents.source(),
              let down = MenuNativeEvents.mouse(.leftMouseDown, at: start, window: original.id,
                                               pid: sourcePID, source: source, command: true),
              let up = MenuNativeEvents.mouse(.leftMouseUp, at: end, window: anchor.id, pid: sourcePID, source: source),
              let release = MenuNativeEvents.mouse(.leftMouseUp, at: fallback, window: original.id, pid: sourcePID, source: source) else {
            running = false
            return result(false, "event-creation-failed", frame: nil)
        }
        attempts += 1
        held = HeldButton(release: release, pid: sourcePID, pointer: CGEvent(source: nil)?.location,
                          inputGeneration: inputGeneration, pointerGeneration: pointer.pointerGeneration,
                          syntheticStart: start, syntheticEnd: end)
        defer {
            releaseHeldDirectly()
            running = false
        }
        let downDelivery = await MenuEventDelivery.send(down, to: sourcePID)
        // Give the remote renderer time to enter native move state. A lack of
        // detachment is diagnostic, not evidence that placement succeeded.
        _ = await waitForChange(windowID, original: original.frame, lease: lease,
                                inputGeneration: inputGeneration, milliseconds: 100)
        guard lifetime.accepts(lease), !Task.isCancelled, pointer.generation == inputGeneration else {
            await releaseHeld()
            return result(false, "interrupted-by-user", frame: discovery.window(windowID)?.frame)
        }
        guard downDelivery.acknowledged else {
            await releaseHeld()
            return result(false, "down-\(downDelivery.stage)", frame: discovery.window(windowID)?.frame)
        }
        let saved = held
        let upDelivery = await MenuEventDelivery.send(up, to: sourcePID, cancellationSensitive: false)
        // This up balances the one down. Fallback is only button cleanup, never
        // a second placement or a retry of the operation.
        held = nil
        if downDelivery.submittedToSession && !upDelivery.submittedToSession { up.post(tap: .cgSessionEventTap) }
        if let saved { restoreSyntheticPointer(saved) }
        guard lifetime.accepts(lease), !Task.isCancelled, pointer.generation == inputGeneration else {
            return result(false, "interrupted-by-user", frame: discovery.window(windowID)?.frame)
        }
        guard upDelivery.acknowledged else { return result(false, "up-\(upDelivery.stage)", frame: discovery.window(windowID)?.frame) }
        let deadline = ProcessInfo.processInfo.systemUptime + 0.75
        var stable = 0
        var previous: CGRect?
        while ProcessInfo.processInfo.systemUptime < deadline {
            guard lifetime.accepts(lease), !Task.isCancelled, pointer.generation == inputGeneration else {
                return result(false, "interrupted-by-user", frame: discovery.window(windowID)?.frame)
            }
            let windows = discovery.allWindows()
            if let frame = windows.first(where: { $0.id == windowID })?.frame,
               let liveAnchor = windows.first(where: { $0.id == anchorID })?.frame {
                let changed = abs(frame.midX - original.frame.midX) > 0.5 || abs(frame.midY - original.frame.midY) > 0.5
                let placed = frame.maxX <= liveAnchor.minX + 2 && abs(frame.midY - liveAnchor.midY) < 12
                if changed && placed {
                    stable = previous == frame ? stable + 1 : 1
                    if stable >= 2 { return result(true, "position-verified", frame: frame) }
                } else { stable = 0 }
                previous = frame
            }
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
        return result(false, "position-not-verified", frame: discovery.window(windowID)?.frame)
    }

    /// A user explicitly requested a click. Ordinary hide/hover/capture paths
    /// cannot reach this method. PID delivery keeps the real cursor untouched.
    func click(windowID: CGWindowID, right: Bool) async -> Bool {
        guard !running, !Task.isCancelled, !userIsInteracting,
              let window = discovery.window(windowID), let source = MenuNativeEvents.source() else { return false }
        // The renderer's target-window fields select the item; a real pointer
        // location is unnecessary and must not steer the user's cursor.
        let point = CGPoint.zero
        guard let down = MenuNativeEvents.mouse(right ? .rightMouseDown : .leftMouseDown, at: point,
                                               window: window.id, pid: window.pid, source: source, click: true),
              let up = MenuNativeEvents.mouse(right ? .rightMouseUp : .leftMouseUp, at: point,
                                             window: window.id, pid: window.pid, source: source, click: true) else { return false }
        MenuEventDelivery.postRenderer(down, pid: window.pid)
        try? await Task.sleep(nanoseconds: 10_000_000)
        MenuEventDelivery.postRenderer(up, pid: window.pid)
        return !Task.isCancelled
    }

    private func waitForChange(_ id: CGWindowID, original: CGRect, lease: UInt64,
                               inputGeneration: UInt64, milliseconds: Int) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + Double(milliseconds) / 1_000
        while ProcessInfo.processInfo.systemUptime < deadline {
            guard lifetime.accepts(lease), !Task.isCancelled, pointer.generation == inputGeneration else { return false }
            if let frame = discovery.window(id)?.frame, frame != original { return true }
            try? await Task.sleep(nanoseconds: 15_000_000)
        }
        return false
    }
    private func releaseHeld() async {
        guard let saved = held else { releaseCursor(); return }
        held = nil
        if let current = CGEvent(source: nil)?.location { saved.release.location = current }
        let delivered = await MenuEventDelivery.send(saved.release, to: saved.pid, cancellationSensitive: false)
        if !delivered.submittedToSession, !CGEventSource.buttonState(.hidSystemState, button: .left) {
            saved.release.post(tap: .cgSessionEventTap)
        }
        restoreSyntheticPointer(saved)
        releaseCursor()
    }
    private func releaseHeldDirectly() {
        guard let saved = held else { releaseCursor(); return }
        held = nil
        // Release only the owned renderer gesture at the current pointer.
        // A fallback up at the old icon center would move the real cursor;
        // a global up during a physical drag would steal the user's button.
        if let current = CGEvent(source: nil)?.location { saved.release.location = current }
        saved.release.postToPid(saved.pid)
        if !CGEventSource.buttonState(.hidSystemState, button: .left) {
            saved.release.post(tap: .cgSessionEventTap)
        }
        restoreSyntheticPointer(saved)
        releaseCursor()
    }
    private func releaseCursor() { cursorLease?.release(); cursorLease = nil }
    private func immediatelyBefore(_ frame: CGRect, _ anchor: CGRect) -> Bool {
        abs(frame.midY - anchor.midY) < 12 && abs(anchor.minX - frame.maxX) <= 2
    }
    private func restoreSyntheticPointer(_ saved: HeldButton) {
        guard let original = saved.pointer, let current = CGEvent(source: nil)?.location else { return }
        lastPointerDisplacement = hypot(Double(current.x - original.x), Double(current.y - original.y))
        // Cursor restoration belongs only to this explicit gesture. If real
        // input arrived or the cursor is somewhere else, its position wins.
        guard pointer.pointerGeneration == saved.pointerGeneration else {
            lastMovement["pointerRestoreYieldedToUser"] = true; return
        }
        // WindowServer can clamp an offscreen gesture, so endpoint equality
        // is not a reliable ownership check. Real pointer input is the guard.
        if original != current { CGWarpMouseCursorPosition(original) }
        if let restored = CGEvent(source: nil)?.location {
            lastMovement["pointerAfterRestore"] = [Double(restored.x), Double(restored.y)]
            lastMovement["pointerRestoredDistance"] = hypot(Double(restored.x - original.x), Double(restored.y - original.y))
        }
    }
    private func result(_ moved: Bool, _ stage: String, frame: CGRect?) -> Result {
        lastResult = stage
        lastMovement["result"] = stage
        return Result(moved: moved, stage: stage, frame: frame)
    }
}
