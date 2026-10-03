import AppKit
import CoreGraphics

/// Window-only Quartz compositing, matching the original native icon capture
/// principle. No ScreenCaptureKit session or desktop screenshot is started.
/// Explicit native operations pause the queue; every completion has a lease.
@MainActor final class MenuIconCapture {
    var onUpdate: (() -> Void)?
    private struct Cache {
        let image: NSImage
        let signature: MenuCaptureGeometry.Signature
    }
    private struct Request {
        let id: CGWindowID
        let signature: MenuCaptureGeometry.Signature
        var item: MenuCaptureGeometry.Item { .init(id: id, signature: signature) }
    }
    private struct Captured {
        let bitmap: CGImage
        let pointSize: CGSize
        let signature: MenuCaptureGeometry.Signature
    }
    private var images: [CGWindowID: Cache] = [:]
    private var retry: [CGWindowID: MenuCaptureRefreshPolicy.State] = [:]
    private var tracked: [CGWindowID: CGRect] = [:]
    private var geometry: [CGWindowID: Request] = [:]
    private var geometryTimestamp: TimeInterval = -.infinity
    private var queued = Set<CGWindowID>()
    private var requests: [Request] = []
    private var worker: Task<Void, Never>?
    private var refreshTimer: Timer?
    private var lifetime = MenuOperationGeneration()
    private var running = false
    private var pauseDepth = 0
    private var compositeAttempts = 0
    private var compositeSuccesses = 0
    private var croppedImages = 0
    private var singleWindowFallbacks = 0
    private var lastResult = "idle"
    private var lastWindowIDs: [CGWindowID] = []
    private var lastBitmapSize: [Int] = []

    func start() {
        guard !running else { return }
        running = true; pauseDepth = 0
        lifetime.advance()
        // A one-second tick and one-second successful-image interval keep
        // changing IME/battery symbols current within two seconds. Empty
        // windows use a separate bounded backoff rather than this interval.
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshTrackedWindows() }
        }
        refreshTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    func stop() {
        running = false; pauseDepth = 0
        refreshTimer?.invalidate(); refreshTimer = nil
        invalidateQueue()
        images.removeAll(); retry.removeAll(); tracked.removeAll(); geometry.removeAll()
    }
    func pause() {
        pauseDepth += 1
        if pauseDepth == 1 { invalidateQueue() }
    }
    func resume() {
        if pauseDepth > 0 { pauseDepth -= 1 }
        processQueueIfNeeded()
    }
    var isPaused: Bool { pauseDepth > 0 }
    var pendingCount: Int { queued.count }
    var diagnostics: [String: Any] {
        ["attempts": compositeAttempts, "composites": compositeSuccesses,
         "croppedImages": croppedImages, "cachedImages": images.count,
         "singleWindowFallbacks": singleWindowFallbacks,
         "result": lastResult, "windowIDs": lastWindowIDs, "bitmapSize": lastBitmapSize,
         "worker": worker != nil, "refreshTimer": refreshTimer != nil, "generation": lifetime.value,
         "backoffWindows": retry.values.filter { $0.failures > 0 }.count,
         "images": images.keys.sorted().map { id -> [String: Any] in
             let cached = images[id]!
             return ["windowID": id, "pointSize": [cached.image.size.width, cached.image.size.height],
                     "displayID": cached.signature.context.displayID, "scale": cached.signature.context.scale,
                     "appearance": cached.signature.appearance, "failures": retry[id]?.failures ?? 0]
         }]
    }

    func retain(windowIDs: Set<CGWindowID>) {
        images = images.filter { windowIDs.contains($0.key) }
        retry = retry.filter { windowIDs.contains($0.key) }
        tracked = tracked.filter { windowIDs.contains($0.key) }
        requests.removeAll { !windowIDs.contains($0.id) }
        queued.formIntersection(windowIDs)
    }
    func image(windowID: CGWindowID, frame: CGRect) -> NSImage? {
        guard running, CGPreflightScreenCaptureAccess(), windowID != 0,
              MenuLayoutPlanner.usable(frame), frame.width <= 400, frame.height <= 100 else { return nil }
        tracked[windowID] = frame
        refreshGeometry(force: false)
        if let request = geometry[windowID] { enqueue(request) }
        else { images.removeValue(forKey: windowID) }
        return images[windowID]?.image
    }
    private func invalidateQueue() {
        lifetime.advance()
        worker?.cancel(); worker = nil
        requests.removeAll(); queued.removeAll()
        geometryTimestamp = -.infinity
    }
    private func refreshTrackedWindows() {
        guard running, !isPaused, !tracked.isEmpty, CGPreflightScreenCaptureAccess() else { return }
        refreshGeometry(force: true)
        for id in tracked.keys.sorted() {
            if let request = geometry[id] { enqueue(request) }
            else { images.removeValue(forKey: id) }
        }
    }
    private func enqueue(_ request: Request) {
        if let cached = images[request.id], cached.signature != request.signature { images.removeValue(forKey: request.id) }
        let now = ProcessInfo.processInfo.systemUptime
        guard !isPaused, !queued.contains(request.id),
              MenuCaptureRefreshPolicy.ready(retry[request.id], signature: request.signature, now: now) else { return }
        requests.append(request); queued.insert(request.id)
        processQueueIfNeeded()
    }
    private func refreshGeometry(force: Bool) {
        let now = ProcessInfo.processInfo.systemUptime
        guard force || now - geometryTimestamp >= 0.1 else { return }
        let coordinates = MenuCoordinates.current
        let screens = NSScreen.screens.map { screen in
            MenuCaptureGeometry.Screen(id: (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0,
                                       quartzBounds: coordinates.quartzRect(screen.frame), scale: screen.backingScaleFactor)
        }
        let appearance = NSApp.effectiveAppearance.name.rawValue
        let descriptions = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        var fresh: [CGWindowID: Request] = [:]
        for description in descriptions {
            guard let number = description[kCGWindowNumber as String] as? NSNumber,
                  let id = CGWindowID(exactly: number.uint64Value), id != 0,
                  let layer = description[kCGWindowLayer as String] as? NSNumber,
                  layer.intValue == 24 || layer.intValue == 25,
                  let dictionary = description[kCGWindowBounds as String] as? NSDictionary,
                  let quartz = CGRect(dictionaryRepresentation: dictionary as CFDictionary),
                  coordinates.isMenuExtraFrame(quartz) else { continue }
            let previous = images[id]?.signature.context ?? geometry[id]?.signature.context
            let context = MenuCaptureGeometry.context(for: quartz, screens: screens, previous: previous)
            fresh[id] = Request(id: id, signature: .init(quartzFrame: quartz, context: context, appearance: appearance))
        }
        geometry = fresh; geometryTimestamp = now
    }
    private func processQueueIfNeeded() {
        guard worker == nil, running, !isPaused, !requests.isEmpty else { return }
        let lease = lifetime.value
        worker = Task { [weak self] in
            guard let self else { return }
            defer { if self.lifetime.accepts(lease) { self.worker = nil } }
            await Task.yield()
            while self.running, !self.isPaused, self.lifetime.accepts(lease), !Task.isCancelled, !self.requests.isEmpty {
                let batch = self.takeBatch()
                let captured = self.capture(batch)
                guard self.running, !self.isPaused, self.lifetime.accepts(lease), !Task.isCancelled else { return }
                let now = ProcessInfo.processInfo.systemUptime
                for request in batch {
                    self.queued.remove(request.id)
                    let image = captured[request.id]
                    let signature = image?.signature ?? self.geometry[request.id]?.signature ?? request.signature
                    self.retry[request.id] = MenuCaptureRefreshPolicy.completed(success: image != nil, signature: signature,
                                                                              previous: self.retry[request.id], now: now)
                    if let image {
                        // Both dimensions come from the fresh renderer crop,
                        // never from an earlier queued AX/CG observation.
                        self.images[request.id] = Cache(image: NSImage(cgImage: image.bitmap, size: image.pointSize), signature: signature)
                    } else if self.images[request.id]?.signature != signature { self.images.removeValue(forKey: request.id) }
                }
                if !captured.isEmpty { self.onUpdate?() }
                await Task.yield()
            }
        }
    }
    private func takeBatch() -> [Request] {
        let groups = MenuCaptureGeometry.batches(requests.map(\.item))
        guard let first = groups.first else { requests.removeAll(); queued.removeAll(); return [] }
        let selected = Set(first.map(\.id))
        let batch = requests.filter { selected.contains($0.id) }
        requests.removeAll { selected.contains($0.id) }
        return batch
    }
    private func capture(_ batch: [Request]) -> [CGWindowID: Captured] {
        guard CGPreflightScreenCaptureAccess(), !batch.isEmpty else { lastResult = "permission-unavailable"; return [:] }
        refreshGeometry(force: true)
        let fresh = batch.compactMap { geometry[$0.id] }
        guard !fresh.isEmpty else { lastResult = "requested-windows-unavailable"; return [:] }
        let lookup = Dictionary(uniqueKeysWithValues: fresh.map { ($0.id, $0) })
        var result: [CGWindowID: Captured] = [:]
        // A divider/display change during queueing can split the old batch.
        for group in MenuCaptureGeometry.batches(fresh.map(\.item)) {
            result.merge(composite(group.compactMap { lookup[$0.id] }, allowFallback: true)) { _, new in new }
        }
        croppedImages += result.count
        if !result.isEmpty { lastResult = "captured" }
        return result
    }
    private func composite(_ current: [Request], allowFallback: Bool) -> [CGWindowID: Captured] {
        guard let first = current.first else { return [:] }
        let bounds = current.reduce(CGRect.null) { $0.union($1.signature.quartzFrame) }
        guard bounds.width <= 4_096, bounds.height <= 100 else { lastResult = "window-bounds-exceeded"; return [:] }
        lastWindowIDs = current.map(\.id)
        compositeAttempts += 1
        // The original API receives pointer-width raw IDs with NULL callbacks.
        // NSArray<NSNumber> would send object addresses as window IDs.
        var rawIDs: [UnsafeRawPointer?] = current.map { UnsafeRawPointer(bitPattern: UInt($0.id)) }
        guard let ids = rawIDs.withUnsafeMutableBufferPointer({ buffer in
            CFArrayCreate(kCFAllocatorDefault, buffer.baseAddress, buffer.count, nil)
        }) else { lastResult = "window-array-creation-failed"; return [:] }
        guard let bitmap = CGImage(windowListFromArrayScreenBounds: .null, windowArray: ids,
                                   imageOption: [.boundsIgnoreFraming, .bestResolution]) else {
            lastResult = "window-composite-unavailable"; lastBitmapSize = []; return [:]
        }
        compositeSuccesses += 1
        lastBitmapSize = [bitmap.width, bitmap.height]
        let bitmapSize = CGSize(width: bitmap.width, height: bitmap.height)
        // An unknown offscreen display is isolated. Its actual bitmap scale is
        // measurable without attributing it to a neighboring display's row.
        let scale = first.signature.context.displayID == 0 && current.count == 1
            ? CGFloat(bitmap.width) / bounds.width : first.signature.context.scale
        guard MenuCaptureGeometry.bitmapMatches(bounds: bounds, bitmapSize: bitmapSize, scale: scale) else {
            lastResult = "composite-geometry-mismatch"
            guard allowFallback, current.count > 1 else { return [:] }
            singleWindowFallbacks += current.count
            return current.reduce(into: [:]) { result, request in
                result.merge(composite([request], allowFallback: false)) { _, new in new }
            }
        }
        var result: [CGWindowID: Captured] = [:]
        for request in current {
            guard let crop = MenuCaptureGeometry.crop(frame: request.signature.quartzFrame, compositeBounds: bounds,
                                                     bitmapSize: bitmapSize, scale: scale),
                  let image = bitmap.cropping(to: crop.pixels), hasIconContent(image) else { continue }
            let signature = MenuCaptureGeometry.Signature(quartzFrame: request.signature.quartzFrame,
                                                         context: .init(displayID: request.signature.context.displayID, scale: scale),
                                                         appearance: request.signature.appearance)
            result[request.id] = Captured(bitmap: image, pointSize: crop.pointSize, signature: signature)
        }
        lastResult = result.isEmpty ? "composite-has-no-icon-content" : "captured"
        return result
    }
    private func hasIconContent(_ image: CGImage) -> Bool {
        let width = image.width, height = image.height
        guard width > 0, height > 0, width <= 1_600, height <= 400 else { return false }
        let rowBytes = width * 4
        var bytes = [UInt8](repeating: 0, count: rowBytes * height)
        return bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: rowBytes, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return MenuCaptureGeometry.alphaBounds(UnsafeRawBufferPointer(buffer), width: width, height: height, rowBytes: rowBytes) != nil
        }
    }
}
