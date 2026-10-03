import AppKit

/// Opt-in local snapshots. This service never refreshes icons, schedules
/// movement, captures a screen, or changes settings.
@MainActor final class LocalDiagnostics {
    private let model: AppModel
    private weak var engine: MenuBarEngine?
    private let aggregateVisible: () -> Bool
    private var timer: Timer?

    init(model: AppModel, engine: MenuBarEngine, aggregateVisible: @escaping () -> Bool) {
        self.model = model
        self.engine = engine
        self.aggregateVisible = aggregateVisible
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled else {
            timer?.invalidate()
            timer = nil
            return
        }
        guard timer == nil else { return }
        writeSnapshot()
        let timer = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.writeSnapshot() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func writeSnapshot() {
        guard let engine else { return }
        var payload: [String: Any] = [
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "statusItemFrames": engine.statusItemFramesSnapshot,
            "accessibility": model.accessibilityGranted,
            "screenRecording": model.screenRecordingGranted,
            "expanded": model.expanded, "busy": model.busy,
            "loginItemState": String(describing: model.loginItemState),
            "aggregateVisible": aggregateVisible(),
            "layoutPassCount": engine.layoutPassCount,
            "commandDragAttempts": engine.commandDragAttempts,
            "activationCount": engine.activationCount,
            "lastLayoutReason": engine.lastLayoutReason,
            "lastLayoutGestureResult": engine.lastLayoutGestureResult,
            "eventRouting": MenuEventDelivery.diagnostics,
            "resources": engine.resourceSnapshot,
            "message": model.statusMessage,
            "icons": model.sortedIcons.map { icon in
                ["id": icon.id, "title": icon.title, "bundleID": icon.bundleID,
                 "x": icon.frame.minX, "y": icon.frame.minY, "width": icon.frame.width,
                 "windowID": icon.windowID ?? 0, "hasImage": icon.image != nil,
                 "movable": icon.movable,
                 "visibility": model.rule(for: icon.id).visibility.rawValue] as [String: Any]
            }
        ]
        if let displacement = engine.lastPointerDisplacementDuringDrag {
            payload["lastPointerDisplacementDuringDrag"] = displacement
        }
        if let mapping = try? JSONEncoder().encode(engine.windowMappingSnapshot),
           let value = try? JSONSerialization.jsonObject(with: mapping) {
            payload["windowMappings"] = value
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) else { return }
        let directory = model.settingsURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: directory.appendingPathComponent("diagnostics.json"), options: .atomic)
    }
}
