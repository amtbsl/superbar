import AppKit

/// Passive observation only. Every local event is returned unchanged. Input
/// from a real user advances a generation that explicit native operations
/// must check before posting their next event.
@MainActor final class MenuPointerMonitor {
    struct Input {
        let type: NSEvent.EventType
        let point: CGPoint
        let timestamp: TimeInterval
    }
    var onInput: ((Input) -> Void)?
    private(set) var generation: UInt64 = 0
    private(set) var pointerGeneration: UInt64 = 0
    private(set) var lastInputTime: TimeInterval = 0
    private var global: Any?
    private var local: Any?
    private var lastEvent: (TimeInterval, NSEvent.EventType)?
    static let syntheticTag: UInt64 = 0x5355_5045_0000_0000
    static func synthetic(_ event: CGEvent?) -> Bool {
        guard let event else { return false }
        return UInt64(bitPattern: event.getIntegerValueField(.eventSourceUserData)) >> 32 == syntheticTag >> 32
    }

    func start() {
        guard global == nil && local == nil else { return }
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
                                          .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
                                          .otherMouseDown, .otherMouseUp, .scrollWheel, .keyDown, .flagsChanged]
        global = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            Task { @MainActor [weak self] in self?.receive(event) }
        }
        local = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.receive(event)
            return event
        }
    }
    func stop() {
        if let global { NSEvent.removeMonitor(global) }
        if let local { NSEvent.removeMonitor(local) }
        global = nil; local = nil; lastEvent = nil
        generation &+= 1
        pointerGeneration &+= 1
    }
    private func receive(_ event: NSEvent) {
        guard !Self.synthetic(event.cgEvent) else { return }
        if let lastEvent, event.timestamp != 0,
           lastEvent.0 == event.timestamp && lastEvent.1 == event.type { return }
        lastEvent = (event.timestamp, event.type)
        generation &+= 1
        if event.type != .keyDown && event.type != .flagsChanged { pointerGeneration &+= 1 }
        lastInputTime = ProcessInfo.processInfo.systemUptime
        onInput?(Input(type: event.type, point: NSEvent.mouseLocation, timestamp: event.timestamp))
    }
}
