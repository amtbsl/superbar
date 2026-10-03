import Foundation
import CoreGraphics

enum CaptureGeometryTests {
    static func run() throws {
        try alphaCoverage()
        try displayAndRowIsolation()
        try freshPixelGeometry()
        try duplicateIdentity()
        try refreshAndBackoff()
        print("PASS full alpha coverage, fresh crop dimensions, display/scale/row isolation, strict renderer duplication and capture backoff")
    }

    private static func alphaCoverage() throws {
        let width = 88, height = 48, rowBytes = width * 4
        var pixels = [UInt8](repeating: 0, count: rowBytes * height)
        func bounds() -> CGRect? {
            pixels.withUnsafeBytes { MenuCaptureGeometry.alphaBounds($0, width: width, height: height, rowBytes: rowBytes) }
        }
        try expect(bounds() == nil, "A fully transparent composite must not become a cached icon")
        // A one-pixel letter stem lies between every column of the previous
        // 16-column sampler. The production scanner must still recover it.
        for y in 3...35 { pixels[y * rowBytes + 2 * 4 + 3] = 255 }
        try expect(bounds() == CGRect(x: 2, y: 3, width: 1, height: 33), "Sparse IME strokes require full pixel coverage")
        pixels = [UInt8](repeating: 0, count: rowBytes * height)
        pixels[19 * rowBytes + 7 * 4 + 3] = 51
        try expect(bounds() == nil, "Alpha exactly 0.2 must not count as native icon content")
        pixels[19 * rowBytes + 7 * 4 + 3] = 52
        try expect(bounds() == CGRect(x: 7, y: 19, width: 1, height: 1), "The strict alpha threshold must retain a single valid pixel")
        for y in 0..<height { for x in 0..<width { pixels[y * rowBytes + x * 4 + 3] = 255 } }
        try expect(bounds() == CGRect(x: 0, y: 0, width: width, height: height),
                   "Uniform opaque content is valid without brightness or alpha variance")
        let padded = [UInt8](repeating: 0, count: 24)
        try padded.withUnsafeBytes { bytes in
            try expect(MenuCaptureGeometry.alphaBounds(bytes, width: 2, height: 2, rowBytes: 12) == nil, "Row padding is not content")
            try expect(MenuCaptureGeometry.alphaBounds(bytes, width: 4, height: 2, rowBytes: 12) == nil, "A short row is rejected safely")
            try expect(MenuCaptureGeometry.alphaBounds(bytes, width: Int.max, height: 2, rowBytes: 12) == nil, "Pixel stride multiplication cannot overflow")
            try expect(MenuCaptureGeometry.alphaBounds(bytes, width: 1, height: Int.max, rowBytes: 12) == nil, "Total bitmap size cannot overflow")
            try expect(MenuCaptureGeometry.alphaBounds(bytes, width: 1, height: 2, rowBytes: 12, alphaOffset: 4) == nil, "Invalid alpha offsets are rejected")
        }
    }

    private static func displayAndRowIsolation() throws {
        let primary = MenuCaptureGeometry.Screen(id: 1, quartzBounds: CGRect(x: 0, y: 0, width: 1512, height: 982), scale: 2)
        let secondary = MenuCaptureGeometry.Screen(id: 2, quartzBounds: CGRect(x: 1512, y: 0, width: 1920, height: 1080), scale: 1)
        let screens = [primary, secondary]
        let firstFrame = CGRect(x: 1000, y: 0, width: 38, height: 33)
        let secondFrame = CGRect(x: 1600, y: 0, width: 38, height: 33)
        let first = MenuCaptureGeometry.context(for: firstFrame, screens: screens)
        let second = MenuCaptureGeometry.context(for: secondFrame, screens: screens)
        try expect(first == .init(displayID: 1, scale: 2), "An onscreen status renderer uses its own Retina display")
        try expect(second == .init(displayID: 2, scale: 1), "A second display keeps its independent backing scale")
        let hidden = CGRect(x: -4000, y: 0, width: 38, height: 33)
        try expect(MenuCaptureGeometry.context(for: hidden, screens: screens, previous: second) == second,
                   "A hidden window retains its known display instead of inheriting the primary scale")
        try expect(MenuCaptureGeometry.context(for: hidden, screens: screens).displayID == 0,
                   "Ambiguous offscreen windows require individual capture")
        func item(_ id: UInt32, _ frame: CGRect, _ context: MenuCaptureGeometry.Context,
                  appearance: String = "NSAppearanceNameAqua") -> MenuCaptureGeometry.Item {
            .init(id: id, signature: .init(quartzFrame: frame, context: context, appearance: appearance))
        }
        let items = [item(1, firstFrame, first), item(2, firstFrame.offsetBy(dx: 38, dy: 0), first),
                     item(3, secondFrame, second), item(4, firstFrame.offsetBy(dx: 0, dy: -100), first),
                     item(5, hidden, .init(displayID: 0, scale: 2)),
                     item(6, hidden.offsetBy(dx: 38, dy: 0), .init(displayID: 0, scale: 2)),
                     item(7, firstFrame.offsetBy(dx: 76, dy: 0), first, appearance: "NSAppearanceNameDarkAqua")]
        let groups = MenuCaptureGeometry.batches(items)
        try expect(groups.map { $0.map(\.id) } == [[1, 2], [3], [4], [5], [6], [7]],
                   "Composite batches must separate displays, scale, rows, unknown displays and appearance")
        let many = (0..<18).map { item(UInt32($0 + 10), firstFrame.offsetBy(dx: CGFloat($0) * 38, dy: 0), first) }
        let bounded = MenuCaptureGeometry.batches(many)
        try expect(bounded.map(\.count) == [16, 2], "At most sixteen windows share one composite")
        try expect(Set(bounded.flatMap { $0.map(\.id) }).count == 18, "Batch limits cannot lose or duplicate an icon")
        let distant = item(100, firstFrame.offsetBy(dx: 5000, dy: 0), first)
        try expect(MenuCaptureGeometry.batches([items[0], distant]).count == 2, "Offscreen separation cannot allocate an enormous bitmap")
        try expect(MenuCaptureGeometry.batches([item(101, .null, first)]).isEmpty, "Invalid geometry is never passed to the compositor")
    }

    private static func freshPixelGeometry() throws {
        // Battery widened from an earlier 36-point observation to 71 points.
        // The current renderer and bitmap determine the published NSImage size.
        let battery = CGRect(x: 1000, y: 0, width: 71, height: 33)
        let sound = CGRect(x: 1071, y: 0, width: 38, height: 33)
        let bounds = battery.union(sound)
        let bitmap = CGSize(width: 218, height: 66)
        let batteryCrop = MenuCaptureGeometry.crop(frame: battery, compositeBounds: bounds, bitmapSize: bitmap, scale: 2)
        let soundCrop = MenuCaptureGeometry.crop(frame: sound, compositeBounds: bounds, bitmapSize: bitmap, scale: 2)
        try expect(batteryCrop?.pixels == CGRect(x: 0, y: 9, width: 142, height: 48), "The central native strip uses the fresh battery width")
        try expect(batteryCrop?.pointSize == CGSize(width: 71, height: 24), "A stale queued width must not stretch the captured icon")
        try expect(soundCrop?.pixels == CGRect(x: 142, y: 9, width: 76, height: 48), "Adjacent icon crops preserve their exact own horizontal region")
        try expect(soundCrop?.pointSize == CGSize(width: 38, height: 24), "Retina pixels convert back to native points")
        let above = CGRect(x: -5000, y: -120, width: 44, height: 33)
        try expect(MenuCaptureGeometry.crop(frame: above, compositeBounds: above, bitmapSize: CGSize(width: 88, height: 66), scale: 2)?.pixels
                   == CGRect(x: 0, y: 9, width: 88, height: 48), "An offscreen row still crops relative to its own composite")
        try expect(!MenuCaptureGeometry.bitmapMatches(bounds: bounds, bitmapSize: CGSize(width: 76, height: 66), scale: 2),
                   "A composite omitting a selected window requires individual fallback, not a neighbor's crop")
        try expect(MenuCaptureGeometry.crop(frame: sound, compositeBounds: bounds, bitmapSize: CGSize(width: 218, height: 66), scale: 1) == nil,
                   "Mixed backing scales cannot silently produce incorrect crops")
        let short = CGRect(x: 0, y: 0, width: 20, height: 20)
        try expect(MenuCaptureGeometry.crop(frame: short, compositeBounds: short, bitmapSize: CGSize(width: 40, height: 40), scale: 2)?.pointSize
                   == CGSize(width: 20, height: 20), "A clipped vertical strip retains its actual point height")
        for size in [CGSize.zero, CGSize(width: CGFloat.nan, height: 66), CGSize(width: 218, height: -66)] {
            try expect(!MenuCaptureGeometry.bitmapMatches(bounds: bounds, bitmapSize: size, scale: 2), "Invalid bitmap dimensions must fail safely")
        }
    }

    private static func duplicateIdentity() throws {
        let frame = CGRect(x: 1000, y: 949, width: 38, height: 33)
        func duplicate(_ candidate: CGRect, pid: Int32 = 640, title: String = "", existing: CGRect? = frame,
                       existingPID: Int32? = 640, existingTitle: String? = "") -> Bool {
            MenuCaptureGeometry.duplicateRenderer(candidateFrame: candidate, candidatePID: pid, candidateTitle: title,
                                                   existingFrame: existing, existingPID: existingPID, existingTitle: existingTitle)
        }
        try expect(duplicate(frame), "The same existing renderer rectangle is a genuine duplicate")
        try expect(!duplicate(frame, existing: nil, existingPID: nil), "An unmatched AX item cannot swallow an unknown CG renderer")
        try expect(!duplicate(frame.offsetBy(dx: 12, dy: 0)), "Neighboring overlapping icons remain independent")
        try expect(!duplicate(CGRect(x: 1000, y: 949, width: 44, height: 33)), "Different renderer widths are not duplicates")
        try expect(!duplicate(frame, pid: 852), "Different renderer processes remain independent")
        try expect(!duplicate(frame, title: "Focus", existingTitle: "Sound"), "Distinct named Control Center modules cannot merge during overlap")
        try expect(duplicate(frame, title: "Focus", existingTitle: "Focus"), "A named renderer's exact duplicate is recognized")
    }

    private static func refreshAndBackoff() throws {
        let frame = CGRect(x: 1000, y: 0, width: 44, height: 33)
        let signature = MenuCaptureGeometry.Signature(quartzFrame: frame, context: .init(displayID: 1, scale: 2), appearance: "Aqua")
        var state: MenuCaptureRefreshPolicy.State?
        try expect(MenuCaptureRefreshPolicy.ready(state, signature: signature, now: 10), "A newly discovered icon captures immediately")
        state = MenuCaptureRefreshPolicy.completed(success: true, signature: signature, previous: state, now: 10)
        try expect(!MenuCaptureRefreshPolicy.ready(state, signature: signature, now: 10.5), "A completion callback cannot create a capture loop")
        try expect(MenuCaptureRefreshPolicy.ready(state, signature: signature, now: 11), "Successful live symbols are ready within the local one-second tick")
        var now = 11.0
        for expected in [2.0, 4.0, 8.0, 16.0, 30.0, 30.0, 30.0] {
            state = MenuCaptureRefreshPolicy.completed(success: false, signature: signature, previous: state, now: now)
            try expect(state!.nextAttempt - now == expected, "Empty windows must back off rather than capture continuously")
            try expect(!MenuCaptureRefreshPolicy.ready(state, signature: signature, now: now + 1), "An empty result cannot recapture on every tick")
            now = state!.nextAttempt
        }
        let changes = [
            MenuCaptureGeometry.Signature(quartzFrame: frame.offsetBy(dx: 1, dy: 0), context: signature.context, appearance: "Aqua"),
            MenuCaptureGeometry.Signature(quartzFrame: CGRect(x: 1000, y: 0, width: 71, height: 33), context: signature.context, appearance: "Aqua"),
            MenuCaptureGeometry.Signature(quartzFrame: frame, context: .init(displayID: 2, scale: 1), appearance: "Aqua"),
            MenuCaptureGeometry.Signature(quartzFrame: frame, context: signature.context, appearance: "DarkAqua")
        ]
        for changed in changes {
            try expect(MenuCaptureRefreshPolicy.ready(state, signature: changed, now: now - 29),
                       "Geometry, size, display scale and appearance changes invalidate stale images/backoff")
        }
        state = MenuCaptureRefreshPolicy.completed(success: true, signature: signature, previous: state, now: now)
        try expect(state!.failures == 0 && state!.nextAttempt == now + 1, "A recovered icon returns to prompt live refresh")
    }
}
