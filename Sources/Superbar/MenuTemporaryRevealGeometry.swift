import CoreGraphics

/// The observed macOS 26 temporary-show destination. All X coordinates are
/// screen coordinates except `blank`, which belongs to the full-display host.
enum MenuTemporaryRevealGeometry {
    static func targetX(width: CGFloat, screen: CGRect, main: CGRect, blank: CGRect,
                        notchRight: CGFloat?, firstVisible: CGRect?) -> CGFloat? {
        guard width.isFinite, width > 0, MenuLayoutPlanner.usable(screen),
              MenuLayoutPlanner.usable(main), blank.minX.isFinite, blank.maxX.isFinite else { return nil }
        func trunc(_ value: CGFloat) -> CGFloat { value.rounded(.towardZero) }
        var candidate = trunc(screen.minX + trunc(blank.maxX - width))
        var lower = trunc(blank.minX)
        if let notchRight, notchRight.isFinite { lower = trunc(max(lower, notchRight + 20)) }
        lower = trunc(screen.minX + lower)
        if candidate < lower {
            guard let firstVisible, MenuLayoutPlanner.usable(firstVisible) else { return nil }
            candidate = trunc(firstVisible.minX - width)
        }
        return (main.midX > candidate ? candidate : trunc(main.midX - width)) + 4
    }
}
