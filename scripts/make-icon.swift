// make-icon.swift — draws the Phaedrus icon (black-figure Greek pottery style)
// Usage: swift scripts/make-icon.swift <out.png>   (1024×1024)
// Then scripts/make-icon.sh turns it into Resources/AppIcon.icns.

import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let cg = NSGraphicsContext.current!.cgContext

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

let ink = rgb(0x1C1714)          // black glaze
let clayTop = rgb(0xDE7B4C)      // terracotta, lit
let clayBottom = rgb(0xB0502B)   // terracotta, shade
let incision = rgb(0xD8794B)     // incised lines show the clay through the glaze

// --- tile (macOS icon grid: 824pt squircle-ish rounded rect, centred) ---
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = CGPath(roundedRect: tile, cornerWidth: 186, cornerHeight: 186, transform: nil)

cg.saveGState()
cg.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: rgb(0x000000, 0.35))
cg.addPath(tilePath); cg.setFillColor(clayBottom); cg.fillPath()
cg.restoreGState()

cg.saveGState()
cg.addPath(tilePath); cg.clip()
let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [clayTop, clayBottom] as CFArray, locations: [0, 1])!
cg.drawLinearGradient(grad, start: CGPoint(x: 0, y: 924), end: CGPoint(x: 0, y: 100), options: [])
// soft glaze sheen
let sheen = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                       colors: [rgb(0xFFFFFF, 0.16), rgb(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
cg.drawRadialGradient(sheen, startCenter: CGPoint(x: 400, y: 800), startRadius: 0,
                      endCenter: CGPoint(x: 400, y: 800), endRadius: 520, options: [])
cg.restoreGState()

cg.setLineCap(.round)
cg.setLineJoin(.round)

// --- microphone (black figure) ---
let cx: CGFloat = 512
let capsule = CGRect(x: cx - 112, y: 505, width: 224, height: 330)
cg.addPath(CGPath(roundedRect: capsule, cornerWidth: 112, cornerHeight: 112, transform: nil))
cg.setFillColor(ink); cg.fillPath()

// incised grille lines
cg.setStrokeColor(incision)
cg.setLineWidth(11)
for y in stride(from: CGFloat(600), through: 760, by: 40) {
    cg.move(to: CGPoint(x: cx - 62, y: y)); cg.addLine(to: CGPoint(x: cx + 62, y: y))
}
cg.strokePath()

// holder (U), stem, base
cg.setStrokeColor(ink)
cg.setLineWidth(42)
let r: CGFloat = 168, hc: CGFloat = 640
cg.move(to: CGPoint(x: cx - r, y: hc + 70))
cg.addLine(to: CGPoint(x: cx - r, y: hc))
cg.addArc(center: CGPoint(x: cx, y: hc), radius: r, startAngle: .pi, endAngle: 0, clockwise: false)
cg.addLine(to: CGPoint(x: cx + r, y: hc + 70))
cg.move(to: CGPoint(x: cx, y: hc - r))
cg.addLine(to: CGPoint(x: cx, y: 392))
cg.move(to: CGPoint(x: cx - 100, y: 392))
cg.addLine(to: CGPoint(x: cx + 100, y: 392))
cg.strokePath()

// --- meander (Greek key) band ---
let g: CGFloat = 16                      // grid step; each unit is 5g wide, 4g tall
let bandBottom: CGFloat = 206
let units = 8
let unitW = 5 * g
let bandW = CGFloat(units) * unitW
let x0 = cx - bandW / 2 + g / 2          // + g/2: last unit has no trailing gap
func p(_ ux: CGFloat, _ uy: CGFloat, _ base: CGFloat) -> CGPoint { CGPoint(x: base + ux * g, y: bandBottom + uy * g) }

cg.setLineWidth(9)
cg.setLineCap(.square)
cg.setLineJoin(.miter)
// border lines above and below the key
for y in [bandBottom - 1.4 * g, bandBottom + 5.4 * g] {
    cg.move(to: CGPoint(x: cx - bandW / 2 - g / 2, y: y)); cg.addLine(to: CGPoint(x: cx + bandW / 2 + g / 2, y: y))
}
// each unit: from the baseline, up, right, down, and spiral inward
for i in 0..<units {
    let b = x0 + CGFloat(i) * unitW
    cg.move(to: p(-1, 0, b))
    for (ux, uy) in [(0.0, 0.0), (0.0, 4.0), (4.0, 4.0), (4.0, 1.0), (2.0, 1.0), (2.0, 2.5), (3.0, 2.5)] as [(CGFloat, CGFloat)] {
        cg.addLine(to: p(ux, uy, b))
    }
}
cg.move(to: p(4, 0, x0 + CGFloat(units - 1) * unitW)); cg.addLine(to: p(-1, 0, x0 + CGFloat(units - 1) * unitW))
cg.strokePath()

NSGraphicsContext.current = nil
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
