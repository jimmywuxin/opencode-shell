import AppKit

// opencode-shell 应用图标渲染
// 参照 opencode-desktop-icon.png（240×240）重绘，比例/配色按原图采样还原：
//   深炭色 squircle 底 → 银色金属框（竖向渐变）→ 内嵌暗屏（黑→灰反射带→暖黑）
// 输出 1024×1024 PNG，2× 超采样后高质降采样。
//
// 用法（图标源图就在本脚本里，改完重跑即可，无需图形软件）：
//   /usr/bin/swiftc -O tools/render_icon.swift -o /tmp/render_icon
//   /tmp/render_icon assets/icon_1024.png
//   bash build.sh        # 自动生成各档尺寸 iconset → AppIcon.icns

let S: CGFloat = 1024
let SS: CGFloat = 2
let C = S * SS

func hex(_ s: String) -> NSColor {
    let v = UInt32(s, radix: 16)!
    return NSColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255,
                   green: CGFloat((v >> 8) & 0xff) / 255,
                   blue: CGFloat(v & 0xff) / 255, alpha: 1)
}

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(C), pixelsHigh: Int(C),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: C, height: C)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext
ctx.setAllowsAntialiasing(true)
ctx.setShouldAntialias(true)
ctx.interpolationQuality = .high

// 竖向渐变铺满 path（显式起止点：AppKit 的 draw(in:angle:) 角度约定容易画反）
func fillV(_ path: NSBezierPath, _ stops: [(CGFloat, NSColor)]) {
    let b = path.bounds
    let g = NSGradient(colors: stops.map { $0.1 }, atLocations: stops.map { $0.0 }, colorSpace: .sRGB)!
    ctx.saveGState()
    path.addClip()
    g.draw(from: NSPoint(x: b.midX, y: b.maxY), to: NSPoint(x: b.midX, y: b.minY),
           options: [.drawsBeforeStartingLocation, .drawsAfterEndingLocation])
    ctx.restoreGState()
}

// 超椭圆（Apple squircle 近似）
func superellipse(_ rect: NSRect, n: CGFloat = 6.0, steps: Int = 1440) -> NSBezierPath {
    let p = NSBezierPath()
    let a = rect.width / 2, b = rect.height / 2
    let e = 2 / n
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let ct = cos(t), st = sin(t)
        let x = rect.midX + a * (ct < 0 ? -1 : 1) * pow(abs(ct), e)
        let y = rect.midY + b * (st < 0 ? -1 : 1) * pow(abs(st), e)
        if i == 0 { p.move(to: NSPoint(x: x, y: y)) } else { p.line(to: NSPoint(x: x, y: y)) }
    }
    p.close()
    return p
}

// ── 1) 底：深炭色 squircle ──────────────────────────────────
let margin = 16 * SS
let body = NSRect(x: margin, y: margin, width: C - margin * 2, height: C - margin * 2)
let bodyPath = superellipse(body, n: 6.2)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10 * SS), blur: 26 * SS,
              color: NSColor.black.withAlphaComponent(0.45).cgColor)
hex("262626").setFill()
bodyPath.fill()
ctx.restoreGState()

fillV(bodyPath, [(0.00, hex("363636")), (0.32, hex("2A2A2A")),
                 (0.64, hex("212121")), (1.00, hex("151515"))])

// 顶部环境光，避免整块死黑
ctx.saveGState()
bodyPath.addClip()
NSGradient(colors: [NSColor.white.withAlphaComponent(0.09), NSColor.white.withAlphaComponent(0.0)],
           atLocations: [0.0, 0.5], colorSpace: .sRGB)!
    .draw(from: NSPoint(x: body.midX, y: body.maxY), to: NSPoint(x: body.midX, y: body.minY),
          options: [.drawsBeforeStartingLocation])
ctx.restoreGState()

// ── 2) 银色金属框 ─────────────────────────────────────────
// 比例取自参考图实测（占底的比例）：x 22.08%–77.50%，y 15.42%–83.75%
let frame = NSRect(x: body.minX + body.width * 0.2208,
                   y: body.minY + body.height * (1 - 0.8375),
                   width: body.width * (0.7750 - 0.2208),
                   height: body.height * (0.8375 - 0.1542))
let rFrame = 15 * SS
let framePath = NSBezierPath(roundedRect: frame, xRadius: rFrame, yRadius: rFrame)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -8 * SS), blur: 14 * SS,
              color: NSColor.black.withAlphaComponent(0.52).cgColor)
hex("D2D2D2").setFill()
framePath.fill()
ctx.restoreGState()

fillV(framePath, [(0.00, hex("FFFFFF")), (0.14, hex("F4F4F4")), (0.40, hex("E0E0E0")),
                  (0.66, hex("C9C9C9")), (0.86, hex("B7B7B7")), (1.00, hex("A9A9A9"))])

// 外沿 1px 高光（顶部最强），金属倒角
ctx.saveGState()
framePath.addClip()
let topRim = NSBezierPath(roundedRect: frame.insetBy(dx: 0.6 * SS, dy: 0.6 * SS),
                          xRadius: rFrame, yRadius: rFrame)
topRim.lineWidth = 1.2 * SS
NSColor.white.withAlphaComponent(0.70).setStroke()
topRim.stroke()
ctx.restoreGState()

// ── 3) 内嵌暗屏 ───────────────────────────────────────────
let inner = NSRect(x: frame.minX + frame.width * (34.0 / 133.0),
                   y: frame.minY + frame.height * (34.0 / 164.0),
                   width: frame.width * (64.0 / 133.0),
                   height: frame.height * (96.0 / 164.0))
let rInner = 8 * SS
let innerPath = NSBezierPath(roundedRect: inner, xRadius: rInner, yRadius: rInner)

// 凹槽：开口周围一圈暗边
ctx.saveGState()
innerPath.lineWidth = 2.4 * SS
NSColor.black.withAlphaComponent(0.5).setStroke()
innerPath.stroke()
ctx.restoreGState()

hex("030303").setFill()
innerPath.fill()

// 屏幕本体：顶部近黑 → 43% 处反射带 #52524F → 底部暖黑 #1F1A0A（按参考图采样）
fillV(innerPath, [(0.00, hex("010101")), (0.10, hex("121212")), (0.22, hex("232323")),
                  (0.30, hex("2A2A28")), (0.36, hex("4A4A47")), (0.44, hex("52524F")),
                  (0.56, hex("4E4E4B")), (0.66, hex("46443D")), (0.76, hex("3C3A31")),
                  (0.86, hex("322E23")), (0.94, hex("282416")), (1.00, hex("1D180A"))])

// 屏幕顶部内阴影，做出凹陷感
ctx.saveGState()
innerPath.addClip()
let sh = NSRect(x: inner.minX, y: inner.maxY - inner.height * 0.16,
                width: inner.width, height: inner.height * 0.16)
NSGradient(colors: [NSColor.black.withAlphaComponent(0.75), NSColor.black.withAlphaComponent(0.0)],
           atLocations: [0.0, 1.0], colorSpace: .sRGB)!
    .draw(from: NSPoint(x: sh.midX, y: sh.maxY), to: NSPoint(x: sh.midX, y: sh.minY),
          options: [.drawsAfterEndingLocation])
ctx.restoreGState()

// 开口下沿的高光倒角（参考图 y≈169 的亮线）
ctx.saveGState()
let bevel = NSBezierPath()
let by = inner.minY - 1.0 * SS
bevel.move(to: NSPoint(x: inner.minX + rInner, y: by))
bevel.line(to: NSPoint(x: inner.maxX - rInner, y: by))
bevel.lineWidth = 1.8 * SS
bevel.lineCapStyle = .round
NSColor.white.withAlphaComponent(0.45).setStroke()
bevel.stroke()
ctx.restoreGState()

NSGraphicsContext.restoreGraphicsState()

// ── 4) 降采样输出 ─────────────────────────────────────────
let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(S), pixelsHigh: Int(S),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
out.size = NSSize(width: S, height: S)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
NSGraphicsContext.current!.imageInterpolation = .high
rep.draw(in: NSRect(x: 0, y: 0, width: S, height: S))
NSGraphicsContext.restoreGraphicsState()

let dest = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/icon.png"
try! out.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: dest))
print("wrote \(dest)")
