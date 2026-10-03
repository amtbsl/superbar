import AppKit
import CoreGraphics

/// A short-lived renderer/session handshake. It observes only our tagged
/// events, never filters real input, and reports delivery rather than motion.
/// Native movement must separately inspect the renderer's updated geometry.
final class MenuEventDelivery: NSObject {
    struct Outcome {
        let submittedToSession: Bool
        let acknowledged: Bool
        let stage: String
    }
    private static var attempts = 0
    private static var processAcknowledgements = 0
    private static var sessionAcknowledgements = 0
    private static var lastStage = "idle"
    private static var active: [UUID: MenuEventDelivery] = [:]
    static var diagnostics: [String: Any] {
        ["attempts": attempts, "processAcknowledgements": processAcknowledgements,
         "sessionAcknowledgements": sessionAcknowledgements, "lastStage": lastStage,
         "activeDeliveries": active.count]
    }

    @MainActor static func postSession(_ event: CGEvent) {
        attempts += 1
        lastStage = "native-session-\(event.type.rawValue)"
        event.post(tap: .cgSessionEventTap)
    }
    @MainActor static func postRenderer(_ event: CGEvent, pid: pid_t) {
        attempts += 1
        lastStage = "native-renderer-\(event.type.rawValue)"
        event.postToPid(pid)
    }

    private let identifier = UUID()
    private let event: CGEvent
    private let pid: pid_t
    private let probe: CGEvent
    private var processTap: CFMachPort?
    private var sessionTap: CFMachPort?
    private var sources: [CFRunLoopSource] = []
    private var timer: Timer?
    private var continuation: CheckedContinuation<Outcome, Never>?
    private var finished = false
    private var forwarded = false

    private init?(event: CGEvent, pid: pid_t) {
        guard pid > 0, let probe = CGEvent(source: nil) else { return nil }
        self.event = event; self.pid = pid; self.probe = probe
        probe.setIntegerValueField(.eventSourceUserData, value: event.getIntegerValueField(.eventSourceUserData))
        super.init()
    }

    @MainActor static func send(_ event: CGEvent, to pid: pid_t, cancellationSensitive: Bool = true) async -> Outcome {
        guard let delivery = MenuEventDelivery(event: event, pid: pid) else {
            return Outcome(submittedToSession: false, acknowledged: false, stage: "invalid-event")
        }
        if cancellationSensitive && Task.isCancelled {
            return Outcome(submittedToSession: false, acknowledged: false, stage: "cancelled")
        }
        return await withTaskCancellationHandler {
            await delivery.start(cancellationSensitive: cancellationSensitive)
        } onCancel: {
            if cancellationSensitive {
                Task { @MainActor in delivery.finish(acknowledged: false, stage: "cancelled") }
            }
        }
    }

    @MainActor static func cancelAll() {
        for delivery in Array(active.values) { delivery.finish(acknowledged: false, stage: "stopped") }
    }

    @MainActor private func start(cancellationSensitive: Bool) async -> Outcome {
        if finished || (cancellationSensitive && Task.isCancelled) {
            return Outcome(submittedToSession: false, acknowledged: false, stage: "cancelled")
        }
        Self.attempts += 1
        Self.lastStage = "creating-taps"
        Self.active[identifier] = self
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            let context = Unmanaged.passUnretained(self).toOpaque()
            processTap = CGEvent.tapCreateForPid(pid: pid, place: .tailAppendEventTap, options: .defaultTap,
                                                eventsOfInterest: 1 << CGEventType.null.rawValue,
                                                callback: { _, type, received, context in
                guard let context else { return Unmanaged.passUnretained(received) }
                let delivery = Unmanaged<MenuEventDelivery>.fromOpaque(context).takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let tap = delivery.processTap, !delivery.finished { CGEvent.tapEnable(tap: tap, enable: true) }
                    return Unmanaged.passUnretained(received)
                }
                guard !delivery.finished, !delivery.forwarded, type == .null,
                      received.getIntegerValueField(.eventSourceUserData) == delivery.probe.getIntegerValueField(.eventSourceUserData) else {
                    return Unmanaged.passUnretained(received)
                }
                delivery.forwarded = true
                MenuEventDelivery.processAcknowledgements += 1
                MenuEventDelivery.lastStage = "renderer-ready"
                delivery.event.post(tap: .cgSessionEventTap)
                return nil // Only our own wake-up null event is consumed.
            }, userInfo: context)
            sessionTap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly,
                                          eventsOfInterest: 1 << event.type.rawValue,
                                          callback: { _, type, received, context in
                guard let context else { return Unmanaged.passUnretained(received) }
                let delivery = Unmanaged<MenuEventDelivery>.fromOpaque(context).takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let tap = delivery.sessionTap, !delivery.finished { CGEvent.tapEnable(tap: tap, enable: true) }
                } else if !delivery.finished, delivery.forwarded, type == delivery.event.type,
                          received.getIntegerValueField(.eventSourceUserData) == delivery.event.getIntegerValueField(.eventSourceUserData) {
                    delivery.event.postToPid(delivery.pid)
                    MenuEventDelivery.sessionAcknowledgements += 1
                    delivery.finish(acknowledged: true, stage: "delivered")
                }
                return Unmanaged.passUnretained(received)
            }, userInfo: context)
            guard let processTap, let sessionTap else { finish(acknowledged: false, stage: "tap-creation-failed"); return }
            for tap in [processTap, sessionTap] {
                guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
                    finish(acknowledged: false, stage: "runloop-source-failed"); return
                }
                sources.append(source)
                CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            let timer = Timer(timeInterval: 0.15, target: self, selector: #selector(deadlineReached), userInfo: nil, repeats: false)
            self.timer = timer
            RunLoop.main.add(timer, forMode: .common)
            probe.postToPid(pid)
        }
    }

    @objc private func deadlineReached() { finish(acknowledged: false, stage: "delivery-timeout") }

    private func finish(acknowledged: Bool, stage: String) {
        guard !finished else { return }
        finished = true
        Self.lastStage = stage
        timer?.invalidate(); timer = nil
        for source in sources { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        sources.removeAll()
        for tap in [processTap, sessionTap].compactMap({ $0 }) { CFMachPortInvalidate(tap) }
        processTap = nil; sessionTap = nil
        let continuation = continuation; self.continuation = nil
        Self.active.removeValue(forKey: identifier)
        continuation?.resume(returning: Outcome(submittedToSession: forwarded, acknowledged: acknowledged, stage: stage))
    }
}

/// Only MenuNativeMover and an explicitly requested native click use these
/// constructors. The engine's routine presentation paths cannot post input.
@MainActor enum MenuNativeEvents {
    static func source() -> CGEventSource? {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return nil }
        source.localEventsSuppressionInterval = 0
        let allowed: CGEventFilterMask = [.permitLocalMouseEvents, .permitLocalKeyboardEvents, .permitSystemDefinedEvents]
        source.setLocalEventsFilterDuringSuppressionState(allowed, state: .eventSuppressionStateRemoteMouseDrag)
        source.setLocalEventsFilterDuringSuppressionState(allowed, state: .eventSuppressionStateSuppressionInterval)
        return source
    }
    static func mouse(_ type: CGEventType, at point: CGPoint, window: CGWindowID, pid: pid_t,
                      source: CGEventSource, command: Bool = false, click: Bool = false,
                      hitTestFields: Bool = true) -> CGEvent? {
        guard window != 0, pid > 0, point.x.isFinite, point.y.isFinite else { return nil }
        let button: CGMouseButton = type == .rightMouseDown || type == .rightMouseUp ? .right : .left
        guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: button) else { return nil }
        event.flags = command ? [.maskCommand] : []
        let tag = MenuPointerMonitor.syntheticTag | UInt64(UInt32.random(in: 1...UInt32.max))
        event.setIntegerValueField(.eventSourceUserData, value: Int64(bitPattern: tag))
        if hitTestFields {
            event.setIntegerValueField(.eventTargetUnixProcessID, value: Int64(pid))
            event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(window))
            event.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(window))
        }
        // Remote AppKit renderers require this window-target field. It is not
        // a stable public contract, so success is always checked by geometry.
        if let field = CGEventField(rawValue: 0x33) { event.setIntegerValueField(field, value: Int64(window)) }
        event.setIntegerValueField(.mouseEventClickState, value: click ? 1 : 0)
        return event
    }
}
