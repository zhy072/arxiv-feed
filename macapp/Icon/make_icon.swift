import AppKit
import CoreGraphics

// Renders the ArxivFeed app icon (a fanned stack of paper cards on a red plate)
// at every size macOS wants and writes them into an .iconset folder.
// Usage: make_icon <output.iconset> [preview.png]

let args = CommandLine.arguments
let outDir = args.count > 1 ? args[1] : "AppIcon.iconset"
let previewPath = args.count > 2 ? args[2] : nil

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
        green: CGFloat((hex >> 8) & 0xff) / 255,
        blue: CGFloat(hex & 0xff) / 255,
        alpha: alpha
    )
}

/// Classic heart outline (32 x 29.6 box, y-down), returned in a y-up box of `size` centred on `center`.
func heartPath(center: CGPoint, size: CGFloat) -> CGPath {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: 23.6, y: 0))
    p.addCurve(to: CGPoint(x: 16, y: 5.6), control1: CGPoint(x: 20.2, y: 0), control2: CGPoint(x: 17.3, y: 2.7))
    p.addCurve(to: CGPoint(x: 8.4, y: 0), control1: CGPoint(x: 14.7, y: 2.7), control2: CGPoint(x: 11.8, y: 0))
    p.addCurve(to: CGPoint(x: 0, y: 8.4), control1: CGPoint(x: 3.8, y: 0), control2: CGPoint(x: 0, y: 3.8))
    p.addCurve(to: CGPoint(x: 16, y: 29.6), control1: CGPoint(x: 0, y: 17.8), control2: CGPoint(x: 9.5, y: 20.3))
    p.addCurve(to: CGPoint(x: 32, y: 8.4), control1: CGPoint(x: 22.1, y: 20.3), control2: CGPoint(x: 32, y: 17.5))
    p.addCurve(to: CGPoint(x: 23.6, y: 0), control1: CGPoint(x: 32, y: 3.8), control2: CGPoint(x: 28.2, y: 0))
    p.closeSubpath()
    let scale = size / 32
    var t = CGAffineTransform.identity
    t = t.translatedBy(x: center.x - size / 2, y: center.y + (29.6 * scale) / 2)
    t = t.scaledBy(x: scale, y: -scale) // flip to y-up
    return p.copy(using: &t) ?? p
}

func render(px: Int) -> CGImage {
    let u = CGFloat(px) / 1024 // design grid is 1024
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(
        data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
        space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high

    // Plate: Apple's macOS grid puts the squircle at 824pt inset by 100pt.
    let plate = CGRect(x: 100 * u, y: 100 * u, width: 824 * u, height: 824 * u)
    let platePath = CGPath(roundedRect: plate, cornerWidth: 186 * u, cornerHeight: 186 * u, transform: nil)
    ctx.saveGState()
    ctx.addPath(platePath)
    ctx.clip()
    let base = CGGradient(
        colorsSpace: cs,
        colors: [rgb(0xFF5C79), rgb(0xFF2442), rgb(0xDE1238)] as CFArray,
        locations: [0, 0.55, 1]
    )!
    ctx.drawLinearGradient(
        base, start: CGPoint(x: plate.minX, y: plate.maxY), end: CGPoint(x: plate.maxX, y: plate.minY), options: []
    )
    let glow = CGGradient(colorsSpace: cs, colors: [rgb(0xFFFFFF, 0.30), rgb(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(
        glow, startCenter: CGPoint(x: 330 * u, y: 790 * u), startRadius: 0,
        endCenter: CGPoint(x: 330 * u, y: 790 * u), endRadius: 560 * u, options: []
    )
    ctx.restoreGState()

    // Card stack.
    let front = CGRect(x: 302 * u, y: 236 * u, width: 420 * u, height: 552 * u)
    func card(rotation deg: CGFloat, dx: CGFloat, dy: CGFloat, fill: CGColor, shadow: Bool) {
        ctx.saveGState()
        let r = front.offsetBy(dx: dx * u, dy: dy * u)
        ctx.translateBy(x: r.midX, y: r.midY)
        ctx.rotate(by: deg * .pi / 180)
        ctx.translateBy(x: -r.midX, y: -r.midY)
        if shadow {
            ctx.setShadow(offset: CGSize(width: 0, height: -16 * u), blur: 44 * u, color: rgb(0x5A0012, 0.35))
        }
        ctx.setFillColor(fill)
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: 40 * u, cornerHeight: 40 * u, transform: nil))
        ctx.fillPath()
        ctx.restoreGState()
    }
    card(rotation: 14, dx: 26, dy: 10, fill: rgb(0xFFFFFF, 0.30), shadow: false)
    card(rotation: 7, dx: 14, dy: 6, fill: rgb(0xFFFFFF, 0.55), shadow: false)
    card(rotation: 0, dx: 0, dy: 0, fill: rgb(0xFFFFFF), shadow: true)

    // Front card content: a red label chip, title bars, body bars, heart.
    let inset = 42 * u
    var y = front.maxY - inset
    func bar(width: CGFloat, height: CGFloat, color: CGColor, gapAfter: CGFloat) {
        y -= height * u
        let r = CGRect(x: front.minX + inset, y: y, width: width * u, height: height * u)
        ctx.setFillColor(color)
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: r.height / 2, cornerHeight: r.height / 2, transform: nil))
        ctx.fillPath()
        y -= gapAfter * u
    }
    bar(width: 128, height: 44, color: rgb(0xFF2442), gapAfter: 40)
    bar(width: 336, height: 36, color: rgb(0x1F1F24), gapAfter: 20)
    bar(width: 292, height: 36, color: rgb(0x1F1F24), gapAfter: 20)
    bar(width: 212, height: 36, color: rgb(0x1F1F24), gapAfter: 44)
    bar(width: 336, height: 20, color: rgb(0xD6D6DC), gapAfter: 18)
    bar(width: 336, height: 20, color: rgb(0xD6D6DC), gapAfter: 18)
    bar(width: 230, height: 20, color: rgb(0xD6D6DC), gapAfter: 0)

    let heart = heartPath(center: CGPoint(x: front.maxX - inset - 46 * u, y: front.minY + inset + 44 * u), size: 100 * u)
    ctx.setFillColor(rgb(0xFF2442))
    ctx.addPath(heart)
    ctx.fillPath()

    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to path: String) throws {
    let rep = NSBitmapImageRep(cgImage: image)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "make_icon", code: 1, userInfo: [NSLocalizedDescriptionKey: "png encode failed"])
    }
    try data.write(to: URL(fileURLWithPath: path))
}

let sizes: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

do {
    try FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
    for (name, px) in sizes {
        try writePNG(render(px: px), to: "\(outDir)/\(name).png")
    }
    if let previewPath {
        try writePNG(render(px: 512), to: previewPath)
    }
    print("wrote \(sizes.count) images to \(outDir)")
} catch {
    FileHandle.standardError.write("make_icon failed: \(error)\n".data(using: .utf8)!)
    exit(1)
}
