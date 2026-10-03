import Foundation
import CoreGraphics

/// Geometry and pixel decisions shared by the native capture service and its
/// deterministic tests. This type does not query a display or capture a window.
enum MenuCaptureGeometry {
    struct Screen {
        let id: UInt32
        let quartzBounds: CGRect
        let scale: CGFloat
    }
    struct Context: Equatable {
        let displayID: UInt32
        let scale: CGFloat
    }
    struct Signature: Equatable {
        let quartzFrame: CGRect
        let context: Context
        let appearance: String
    }
    struct Item {
        let id: UInt32
        let signature: Signature
        var frame: CGRect { signature.quartzFrame }
    }
    struct Crop {
        let pixels: CGRect
        let pointSize: CGSize
    }

    static func context(for frame: CGRect, screens: [Screen], previous: Context? = nil) -> Context {
        let valid = screens.filter { usable($0.quartzBounds) && $0.scale.isFinite && $0.scale > 0 && $0.scale <= 4 }
        let intersecting = valid.filter { $0.quartzBounds.intersects(frame) }
        if intersecting.count == 1, let screen = intersecting.first {
            return Context(displayID: screen.id, scale: screen.scale)
        }
        // Hidden status windows can be far to the left or above their display.
        // A known display survives that displacement; ambiguous new windows
        // are captured individually instead of mixing display resolutions.
        let row = valid.filter { abs(frame.minY - $0.quartzBounds.minY) <= 200 }
        if let previous, let screen = row.first(where: { $0.id == previous.displayID }) {
            return Context(displayID: screen.id, scale: screen.scale)
        }
        if row.count == 1, let screen = row.first {
            return Context(displayID: screen.id, scale: screen.scale)
        }
        return Context(displayID: 0, scale: previous?.scale ?? valid.first?.scale ?? 1)
    }

    static func batches(_ items: [Item], maximumCount: Int = 16,
                        maximumWidth: CGFloat = 4_096, maximumHeight: CGFloat = 100) -> [[Item]] {
        guard maximumCount > 0 else { return [] }
        var pending = items.filter { usable($0.frame) }
        var result: [[Item]] = []
        while !pending.isEmpty {
            let first = pending.removeFirst()
            var group = [first]
            var bounds = first.frame
            var index = 0
            while index < pending.count && group.count < maximumCount {
                let item = pending[index]
                let union = bounds.union(item.frame)
                if compatible(first, item), union.width <= maximumWidth, union.height <= maximumHeight {
                    group.append(pending.remove(at: index)); bounds = union
                } else { index += 1 }
            }
            result.append(group.sorted { $0.frame.minX == $1.frame.minX ? $0.id < $1.id : $0.frame.minX < $1.frame.minX })
        }
        return result
    }

    static func compatible(_ lhs: Item, _ rhs: Item) -> Bool {
        lhs.signature.context.displayID != 0
            && lhs.signature.context == rhs.signature.context
            && lhs.signature.appearance == rhs.signature.appearance
            && abs(lhs.frame.midY - rhs.frame.midY) <= 2
    }

    static func bitmapMatches(bounds: CGRect, bitmapSize: CGSize, scale: CGFloat) -> Bool {
        usable(bounds) && bitmapSize.width.isFinite && bitmapSize.height.isFinite
            && bitmapSize.width > 0 && bitmapSize.height > 0
            && scale.isFinite && scale > 0 && scale <= 4
            && abs(bitmapSize.width - bounds.width * scale) <= 2
            && abs(bitmapSize.height - bounds.height * scale) <= 2
    }

    static func crop(frame: CGRect, compositeBounds: CGRect, bitmapSize: CGSize, scale: CGFloat) -> Crop? {
        guard usable(frame), bitmapMatches(bounds: compositeBounds, bitmapSize: bitmapSize, scale: scale) else { return nil }
        // This is the observed native central 24-point strip. Its x origin is
        // the leftmost selected renderer; no AX y coordinate enters the crop.
        let rectangle = CGRect(x: (frame.minX - compositeBounds.minX) * scale,
                               y: floor(bitmapSize.height * 0.5) - 12 * scale,
                               width: frame.width * scale, height: 24 * scale).integral
        let pixels = rectangle.intersection(CGRect(origin: .zero, size: bitmapSize))
        guard !pixels.isNull, !pixels.isEmpty else { return nil }
        return Crop(pixels: pixels, pointSize: CGSize(width: pixels.width / scale, height: pixels.height / scale))
    }

    /// Every pixel participates. Sparse letters and uniform opaque symbols
    /// are valid even when a small sampling grid would miss their variation.
    static func alphaBounds(_ bytes: UnsafeRawBufferPointer, width: Int, height: Int,
                            rowBytes: Int, alphaOffset: Int = 3, pixelBytes: Int = 4) -> CGRect? {
        guard width > 0, height > 0, pixelBytes > 0, alphaOffset >= 0, alphaOffset < pixelBytes else { return nil }
        let (minimumRow, rowOverflow) = width.multipliedReportingOverflow(by: pixelBytes)
        let (required, sizeOverflow) = height.multipliedReportingOverflow(by: rowBytes)
        guard !rowOverflow, !sizeOverflow, rowBytes >= minimumRow, required <= bytes.count else { return nil }
        var left = width, right = -1, top = height, bottom = -1
        for y in 0..<height {
            for x in 0..<width where bytes[y * rowBytes + x * pixelBytes + alphaOffset] > 51 {
                left = min(left, x); right = max(right, x)
                top = min(top, y); bottom = max(bottom, y)
            }
        }
        guard right >= left, bottom >= top else { return nil }
        return CGRect(x: left, y: top, width: right - left + 1, height: bottom - top + 1)
    }

    static func duplicateRenderer(candidateFrame: CGRect, candidatePID: Int32, candidateTitle: String,
                                  existingFrame: CGRect?, existingPID: Int32?, existingTitle: String?) -> Bool {
        guard let existingFrame, let existingPID, candidatePID == existingPID,
              usable(candidateFrame), usable(existingFrame),
              abs(candidateFrame.minX - existingFrame.minX) <= 0.5,
              abs(candidateFrame.minY - existingFrame.minY) <= 0.5,
              abs(candidateFrame.width - existingFrame.width) <= 0.5,
              abs(candidateFrame.height - existingFrame.height) <= 0.5 else { return false }
        // Distinct named system modules remain distinct even during a layout
        // transition where their renderer rectangles temporarily coincide.
        if let existingTitle, !existingTitle.isEmpty, !candidateTitle.isEmpty { return candidateTitle == existingTitle }
        return true
    }

    private static func usable(_ rectangle: CGRect) -> Bool {
        !rectangle.isNull && !rectangle.isInfinite && rectangle.minX.isFinite && rectangle.minY.isFinite
            && rectangle.width.isFinite && rectangle.height.isFinite && rectangle.width > 0 && rectangle.height > 0
    }
}

/// Successful live icons refresh locally within two timer ticks. Empty or
/// unavailable windows back off, and a changed identity/geometry can retry now.
enum MenuCaptureRefreshPolicy {
    struct State {
        let signature: MenuCaptureGeometry.Signature
        let failures: Int
        let nextAttempt: TimeInterval
    }
    static func ready(_ state: State?, signature: MenuCaptureGeometry.Signature, now: TimeInterval) -> Bool {
        guard let state, state.signature == signature else { return true }
        return now >= state.nextAttempt
    }
    static func completed(success: Bool, signature: MenuCaptureGeometry.Signature,
                          previous: State?, now: TimeInterval) -> State {
        let prior = previous?.signature == signature ? previous?.failures ?? 0 : 0
        let failures = success ? 0 : min(prior + 1, 6)
        let interval = success ? 1 : min(30, pow(2, Double(failures)))
        return State(signature: signature, failures: failures, nextAttempt: now + interval)
    }
}
