import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

func render(_ pixels: Int, _ name: String) throws {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let context = NSGraphicsContext(bitmapImageRep: bitmap)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    let scale = CGFloat(pixels) / 1024
    context.cgContext.scaleBy(x: scale, y: scale)
    context.cgContext.clear(CGRect(x: 0, y: 0, width: 1024, height: 1024))

    let base = NSBezierPath(roundedRect: CGRect(x: 75, y: 75, width: 874, height: 874), xRadius: 205, yRadius: 205)
    NSGradient(starting: NSColor(calibratedRed: 0.28, green: 0.24, blue: 0.70, alpha: 1),
               ending: NSColor(calibratedRed: 0.08, green: 0.61, blue: 0.77, alpha: 1))!
        .draw(in: base, angle: -45)

    let panel = NSBezierPath(roundedRect: CGRect(x: 202, y: 261, width: 620, height: 502), xRadius: 92, yRadius: 92)
    NSColor(calibratedWhite: 1, alpha: 0.18).setFill()
    panel.fill()
    NSColor(calibratedWhite: 1, alpha: 0.85).setStroke()
    panel.lineWidth = 17
    panel.stroke()

    for x in [237.0, 751.0] {
        for y in [337.0, 486.0, 635.0] {
            NSColor(calibratedWhite: 1, alpha: 0.92).setFill()
            NSBezierPath(roundedRect: CGRect(x: x, y: y, width: 35, height: 53), xRadius: 12, yRadius: 12).fill()
        }
    }

    let play = NSBezierPath()
    play.move(to: CGPoint(x: 420, y: 382))
    play.line(to: CGPoint(x: 420, y: 642))
    play.curve(to: CGPoint(x: 652, y: 533), controlPoint1: CGPoint(x: 420, y: 680), controlPoint2: CGPoint(x: 665, y: 545))
    play.curve(to: CGPoint(x: 646, y: 494), controlPoint1: CGPoint(x: 675, y: 515), controlPoint2: CGPoint(x: 660, y: 503))
    play.line(to: CGPoint(x: 450, y: 367))
    play.curve(to: CGPoint(x: 420, y: 382), controlPoint1: CGPoint(x: 430, y: 354), controlPoint2: CGPoint(x: 420, y: 367))
    play.close()
    NSColor.white.setFill()
    play.fill()

    context.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    let data = bitmap.representation(using: .png, properties: [:])!
    try data.write(to: root.appendingPathComponent(name))
}

for size in [16, 32, 128, 256, 512] {
    try render(size, "icon_\(size)x\(size).png")
    try render(size * 2, "icon_\(size)x\(size)@2x.png")
}
