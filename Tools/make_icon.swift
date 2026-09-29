import AppKit

let S: CGFloat = 1024
let img = NSImage(size: NSSize(width: S, height: S))
img.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext
func hex(_ h: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((h >> 16) & 0xFF) / 255, green: CGFloat((h >> 8) & 0xFF) / 255, blue: CGFloat(h & 0xFF) / 255, alpha: a)
}
// squircle cover
let body = NSRect(x: 100, y: 100, width: 824, height: 824)
let cover = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 30, color: hex(0x000000, 0.3).cgColor)
NSGradient(colors: [hex(0xF6B9C8), hex(0xE58CA3)])!.draw(in: cover, angle: -60)
ctx.restoreGState()
// paper
let paper = NSRect(x: 196, y: 170, width: 632, height: 600)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 16, color: hex(0x000000, 0.22).cgColor)
hex(0xFDFCF8).setFill()
NSBezierPath(roundedRect: paper, xRadius: 26, yRadius: 26).fill()
ctx.restoreGState()
// highlighter stripes
let stripes: [(CGFloat, CGFloat, UInt32)] = [(560, 330, 0x8EDCD2), (480, 250, 0xF8B38A), (400, 380, 0x8EDCD2), (320, 200, 0xCDB6EF), (240, 300, 0xF3DB78)]
for (y, w, c) in stripes {
    hex(c, 0.95).setFill()
    NSBezierPath(roundedRect: NSRect(x: 250, y: y, width: w, height: 44), xRadius: 12, yRadius: 12).fill()
}
// check circles
hex(0xE0474C).setStroke()
for y in [582, 502, 422] as [CGFloat] {
    let p = NSBezierPath(ovalIn: NSRect(x: 690, y: y - 2, width: 46, height: 46)); p.lineWidth = 11; p.stroke()
}
let tri = NSBezierPath(); tri.move(to: NSPoint(x: 713, y: 380)); tri.line(to: NSPoint(x: 738, y: 336)); tri.line(to: NSPoint(x: 688, y: 336)); tri.close()
tri.lineWidth = 11; tri.lineJoinStyle = .round; tri.stroke()
// spiral rings on top
for i in 0..<9 {
    let x = 250 + CGFloat(i) * 66
    hex(0x55575E).setFill()
    NSBezierPath(roundedRect: NSRect(x: x - 11, y: 712, width: 22, height: 22), xRadius: 6, yRadius: 6).fill()
    let ring = NSBezierPath(roundedRect: NSRect(x: x - 10, y: 716, width: 20, height: 104), xRadius: 10, yRadius: 10)
    ring.lineWidth = 9
    hex(0xB9BCC2).setStroke(); ring.stroke()
    let hi = NSBezierPath(roundedRect: NSRect(x: x - 10, y: 716, width: 20, height: 104), xRadius: 10, yRadius: 10)
    hi.lineWidth = 3; hex(0xFFFFFF, 0.8).setStroke(); hi.stroke()
}
img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
