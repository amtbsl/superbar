import AppKit
let folder = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let n = size * scale
        let image = NSImage(size: NSSize(width: n, height: n))
        image.lockFocus()
        let rect = NSRect(x: CGFloat(n) * 0.08, y: CGFloat(n) * 0.08, width: CGFloat(n) * 0.84, height: CGFloat(n) * 0.84)
        let path = NSBezierPath(roundedRect: rect, xRadius: CGFloat(n) * 0.19, yRadius: CGFloat(n) * 0.19)
        NSGradient(starting: NSColor(calibratedRed: 0.05, green: 0.87, blue: 0.93, alpha: 1), ending: NSColor(calibratedRed: 0.15, green: 0.32, blue: 1, alpha: 1))!.draw(in: path, angle: -65)
        let inner = NSRect(x: CGFloat(n) * 0.23, y: CGFloat(n) * 0.26, width: CGFloat(n) * 0.54, height: CGFloat(n) * 0.47)
        NSColor.white.setStroke()
        let outline = NSBezierPath(roundedRect: inner, xRadius: CGFloat(n) * 0.04, yRadius: CGFloat(n) * 0.04)
        outline.lineWidth = max(1, CGFloat(n) * 0.045); outline.stroke()
        let line = NSBezierPath(); line.move(to: NSPoint(x: inner.minX, y: inner.maxY - CGFloat(n) * 0.13)); line.line(to: NSPoint(x: inner.maxX, y: inner.maxY - CGFloat(n) * 0.13)); line.lineWidth = max(1, CGFloat(n) * 0.032); line.stroke()
        NSColor.white.setFill()
        for i in 0..<3 { NSBezierPath(ovalIn: NSRect(x: inner.minX + CGFloat(n) * (0.06 + Double(i) * 0.07), y: inner.maxY - CGFloat(n) * 0.085, width: CGFloat(n) * 0.027, height: CGFloat(n) * 0.027)).fill() }
        image.unlockFocus()
        let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
        let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        try bitmap.representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent(name))
    }
}
