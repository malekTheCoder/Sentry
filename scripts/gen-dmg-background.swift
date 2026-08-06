// Renders the DMG window background (800x400) used by scripts/release.sh.
// Regenerate: swift scripts/gen-dmg-background.swift scripts/dmg-background.png
import AppKit
import CoreGraphics

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "dmg-background.png"
let W = 800.0, H = 400.0

let ctx = CGContext(
    data: nil, width: Int(W), height: Int(H),
    bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
)!

let cream = CGColor(red: 0.972, green: 0.965, blue: 0.945, alpha: 1)
let ink = NSColor(calibratedRed: 0.239, green: 0.239, blue: 0.227, alpha: 1)
let inkSoft = NSColor(calibratedRed: 0.451, green: 0.447, blue: 0.424, alpha: 1)
let amber = CGColor(red: 0.847, green: 0.494, blue: 0.157, alpha: 1)

ctx.setFillColor(cream)
ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))

// Faint oversized dial arc anchored bottom-left, echoing the app icon.
ctx.saveGState()
ctx.setStrokeColor(CGColor(red: 0.847, green: 0.494, blue: 0.157, alpha: 0.10))
ctx.setLineWidth(46)
ctx.setLineCap(.round)
ctx.addArc(center: CGPoint(x: 60, y: 40), radius: 190,
           startAngle: .pi * 0.10, endAngle: .pi * 0.75, clockwise: false)
ctx.strokePath()
ctx.restoreGState()

NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)

func draw(_ text: String, size: CGFloat, weight: NSFont.Weight, color: NSColor, centerX: CGFloat, y: CGFloat, kern: CGFloat = 0) {
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: color,
        .kern: kern,
    ]
    let s = NSAttributedString(string: text, attributes: attrs)
    let sz = s.size()
    s.draw(at: NSPoint(x: centerX - sz.width / 2, y: y))
}

// Wordmark and tagline, top center. (CG origin is bottom-left.)
draw("Sentry", size: 44, weight: .bold, color: ink, centerX: W / 2, y: H - 96)
draw("Your Mac's vitals, everywhere.", size: 16, weight: .regular, color: inkSoft, centerX: W / 2, y: H - 128)

// Install hint between the two icon wells (create-dmg centers: app 200, /Applications 600, y 185 from top).
// Arrow at the icons' vertical center: y_cg = H - 185 = 215.
let arrowY = 215.0
ctx.setStrokeColor(CGColor(red: 0.451, green: 0.447, blue: 0.424, alpha: 0.9))
ctx.setLineWidth(3)
ctx.setLineCap(.round)
ctx.setLineDash(phase: 0, lengths: [1, 10])
ctx.move(to: CGPoint(x: 305, y: arrowY))
ctx.addLine(to: CGPoint(x: 480, y: arrowY))
ctx.strokePath()
ctx.setLineDash(phase: 0, lengths: [])
ctx.move(to: CGPoint(x: 462, y: arrowY + 12))
ctx.addLine(to: CGPoint(x: 486, y: arrowY))
ctx.addLine(to: CGPoint(x: 462, y: arrowY - 12))
ctx.strokePath()

draw("Drag Sentry into Applications to install", size: 14, weight: .medium, color: inkSoft, centerX: W / 2, y: 52)

let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
