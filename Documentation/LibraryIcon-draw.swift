import AppKit
// Library alternate icon: same canvas, colours, strokes and rows as TaskFlowIcon.png; the check becomes a play
// symbol and the two boxes become bookmarks. Coordinates are in the original's top-left pixel space.
let size = 1024
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
ctx.translateBy(x: 0, y: CGFloat(size)); ctx.scaleBy(x: 1, y: -1)   // top-left origin, like the measurements
func rgb(_ hex: UInt32) -> CGColor { CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1) }
let background = rgb(0x1F2225), blue = rgb(0x3DA8FE), red = rgb(0xFF6553)
ctx.setFillColor(background); ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
ctx.setLineCap(.round); ctx.setLineJoin(.round)

func line(_ y: CGFloat, from x0: CGFloat, to x1: CGFloat, _ color: CGColor) {
    ctx.setStrokeColor(color); ctx.setLineWidth(44)
    ctx.move(to: CGPoint(x: x0 + 22, y: y)); ctx.addLine(to: CGPoint(x: x1 - 22, y: y)); ctx.strokePath()
}
// Row lines, exactly where the original's are.
line(370, from: 432, to: 792, blue)
line(526, from: 430, to: 792, red)
line(682, from: 430, to: 692, red)

// Row 1: a rounded play triangle in place of the check (centred on the blue line, same visual weight).
ctx.setStrokeColor(blue); ctx.setLineWidth(32)
let play = CGMutablePath()
play.move(to: CGPoint(x: 266, y: 318)); play.addLine(to: CGPoint(x: 350, y: 370)); play.addLine(to: CGPoint(x: 266, y: 422)); play.closeSubpath()
ctx.addPath(play); ctx.strokePath()

// Rows 2 and 3: bookmarks in the boxes' space (x 234–362), with the boxes' 26 px stroke.
func bookmark(top: CGFloat, bottom: CGFloat) {
    let left: CGFloat = 250, right: CGFloat = 346, notch: CGFloat = 34
    let path = CGMutablePath()
    path.move(to: CGPoint(x: left, y: top)); path.addLine(to: CGPoint(x: right, y: top))
    path.addLine(to: CGPoint(x: right, y: bottom)); path.addLine(to: CGPoint(x: (left + right) / 2, y: bottom - notch))
    path.addLine(to: CGPoint(x: left, y: bottom)); path.closeSubpath()
    ctx.setStrokeColor(red); ctx.setLineWidth(26); ctx.addPath(path); ctx.strokePath()
}
bookmark(top: 478, bottom: 575)
bookmark(top: 637, bottom: 732)

let image = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: image)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
