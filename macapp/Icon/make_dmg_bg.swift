// Renders the DMG window background (660×400 pt) at 1x and 2x: "drag to Applications" arrow + Gatekeeper hint.
import AppKit

let args = CommandLine.arguments
guard args.count >= 3 else {
    FileHandle.standardError.write(Data("usage: make_dmg_bg out.png out@2x.png\n".utf8))
    exit(1)
}

let W: CGFloat = 660, H: CGFloat = 400
let accent = NSColor(srgbRed: 1.0, green: 0.141, blue: 0.259, alpha: 1)
let ink = NSColor(srgbRed: 0.13, green: 0.13, blue: 0.14, alpha: 1)
let inkSecondary = NSColor(srgbRed: 0.42, green: 0.42, blue: 0.45, alpha: 1)

func centered(_ text: String, size: CGFloat, weight: NSFont.Weight, color: NSColor, top: CGFloat, height: CGFloat) {
    let style = NSMutableParagraphStyle()
    style.alignment = .center
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: color,
        .paragraphStyle: style,
    ]
    NSAttributedString(string: text, attributes: attrs)
        .draw(in: NSRect(x: 24, y: H - top - height, width: W - 48, height: height))
}

func render(scale: CGFloat, to path: String) {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(W * scale), pixelsHigh: Int(H * scale),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ) else { exit(2) }
    rep.size = NSSize(width: W, height: H) // point size → 72·scale dpi, which tiffutil's hidpi pairing needs

    NSGraphicsContext.saveGraphicsState()
    guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else { exit(3) }
    NSGraphicsContext.current = ctx // the context already maps points to the rep's pixels via rep.size

    // Background: warm off-white with a faint accent wash at the top.
    NSColor(srgbRed: 0.985, green: 0.98, blue: 0.98, alpha: 1).setFill()
    NSRect(x: 0, y: 0, width: W, height: H).fill()
    let wash = NSGradient(colors: [accent.withAlphaComponent(0.07), accent.withAlphaComponent(0)])!
    wash.draw(in: NSRect(x: 0, y: H - 140, width: W, height: 140), angle: -90)

    centered("把 ArxivFeed 拖进 Applications", size: 21, weight: .bold, color: ink, top: 42, height: 30)
    centered("装好后从启动台或应用程序里打开", size: 12.5, weight: .regular, color: inkSecondary, top: 74, height: 18)

    // Arrow between the two icons (their centres sit at x=170 and x=490, y=165 from the top).
    let y = H - 165
    let line = NSBezierPath()
    line.move(to: NSPoint(x: 262, y: y))
    line.line(to: NSPoint(x: 384, y: y))
    line.lineWidth = 5
    line.lineCapStyle = .round
    accent.setStroke()
    line.stroke()
    let head = NSBezierPath()
    head.move(to: NSPoint(x: 402, y: y))
    head.line(to: NSPoint(x: 380, y: y + 14))
    head.line(to: NSPoint(x: 380, y: y - 14))
    head.close()
    accent.setFill()
    head.fill()

    centered("第一次打开会自动把后台装到本机，需要电脑上有 python3，并且已安装并登录 ChatGPT 桌面版（速览用它的 Codex）。",
             size: 11, weight: .regular, color: inkSecondary, top: 318, height: 18)
    centered("如果系统提示「无法验证开发者」：打开 系统设置 → 隐私与安全性 → 拉到最下面点「仍要打开」。",
             size: 11, weight: .regular, color: inkSecondary, top: 340, height: 18)

    NSGraphicsContext.restoreGraphicsState()
    guard let png = rep.representation(using: .png, properties: [:]) else { exit(4) }
    do { try png.write(to: URL(fileURLWithPath: path)) } catch { exit(5) }
}

render(scale: 1, to: args[1])
render(scale: 2, to: args[2])
