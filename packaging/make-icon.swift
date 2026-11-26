import AppKit

let size = 1024.0
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
guard let ctx = NSGraphicsContext.current?.cgContext else { fatalError("no context") }

// Transparent canvas, 100pt margin keeps the macOS icon grid optical size.
let inset = 92.0
let rect = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
let path = NSBezierPath(roundedRect: rect, xRadius: 196, yRadius: 196)

ctx.saveGState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
shadow.shadowBlurRadius = 28
shadow.shadowOffset = NSSize(width: 0, height: -10)
shadow.set()
NSColor.black.setFill()
path.fill()
ctx.restoreGState()

let gradient = NSGradient(colors: [
    NSColor(srgbRed: 0.09, green: 0.27, blue: 0.62, alpha: 1),
    NSColor(srgbRed: 0.10, green: 0.55, blue: 0.80, alpha: 1),
    NSColor(srgbRed: 0.08, green: 0.68, blue: 0.66, alpha: 1),
])!
gradient.draw(in: path, angle: -52)

// Soft highlight in the upper-left corner.
ctx.saveGState()
path.addClip()
let glow = NSGradient(colors: [NSColor.white.withAlphaComponent(0.22), NSColor.white.withAlphaComponent(0)])!
glow.draw(in: NSRect(x: inset, y: size * 0.55, width: rect.width, height: rect.height * 0.45), angle: -90)
ctx.restoreGState()

func node(_ p: NSPoint, _ r: CGFloat, alpha: CGFloat = 1) {
    let circle = NSBezierPath(ovalIn: NSRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
    NSColor.white.withAlphaComponent(alpha).setFill()
    circle.fill()
}

let topLeft = NSPoint(x: 362, y: 630)
let topRight = NSPoint(x: 662, y: 630)
let bottom = NSPoint(x: 512, y: 372)

ctx.saveGState()
let link = NSBezierPath()
link.lineWidth = 26
link.lineCapStyle = .round
link.move(to: topLeft)
link.line(to: topRight)
link.move(to: topLeft)
link.line(to: bottom)
link.move(to: topRight)
link.line(to: bottom)
NSColor.white.withAlphaComponent(0.55).setStroke()
link.stroke()
ctx.restoreGState()

node(topLeft, 44, alpha: 0.95)
node(topRight, 44, alpha: 0.95)
node(bottom, 56)

// Downward arrow inside the bottom node: the "download" half of the story.
let arrow = NSBezierPath()
arrow.lineWidth = 20
arrow.lineCapStyle = .round
arrow.move(to: NSPoint(x: 512, y: 402))
arrow.line(to: NSPoint(x: 512, y: 344))
arrow.move(to: NSPoint(x: 484, y: 368))
arrow.line(to: NSPoint(x: 512, y: 340))
arrow.line(to: NSPoint(x: 540, y: 368))
NSColor(srgbRed: 0.08, green: 0.45, blue: 0.70, alpha: 1).setStroke()
arrow.stroke()

image.unlockFocus()

let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
let png = rep.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: "packaging/icon_1024.png"))
print("wrote packaging/icon_1024.png")
