// HUD 게이지 막대를 그대로 축약한 앱 아이콘을 만든다.
// 각 크기를 개별 렌더링해 작은 크기에서도 선명하게 유지한다.
import AppKit

let bg1 = NSColor(calibratedRed: 0.14, green: 0.15, blue: 0.17, alpha: 1)
let bg2 = NSColor(calibratedRed: 0.08, green: 0.09, blue: 0.10, alpha: 1)
let bars: [(CGFloat, NSColor)] = [
    (0.86, NSColor(calibratedRed: 0.36, green: 0.80, blue: 0.51, alpha: 1)),  // green
    (0.58, NSColor(calibratedRed: 0.42, green: 0.66, blue: 0.95, alpha: 1)),  // blue
    (0.32, NSColor(calibratedRed: 0.97, green: 0.76, blue: 0.31, alpha: 1)),  // amber
]

func render(_ size: Int) -> Data? {
    let s = CGFloat(size)
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // macOS 아이콘 그리드: 여백을 두고 둥근 사각형
    let inset = s * 0.065
    let tile = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let radius = tile.width * 0.2237
    let shape = NSBezierPath(roundedRect: tile, xRadius: radius, yRadius: radius)

    NSGradient(starting: bg1, ending: bg2)?.draw(in: shape, angle: -90)

    // 상단 하이라이트 — 작은 크기에서는 생략
    if size >= 64 {
        shape.lineWidth = max(1, s * 0.006)
        NSColor.white.withAlphaComponent(0.10).setStroke()
        shape.stroke()
    }

    // 게이지 막대
    let padX = tile.width * 0.145
    let barW = tile.width - padX * 2
    let barH = tile.height * 0.132
    let gap = tile.height * 0.105
    let total = barH * 3 + gap * 2
    var y = tile.midY + total / 2 - barH

    for (frac, color) in bars {
        let track = NSRect(x: tile.minX + padX, y: y, width: barW, height: barH)
        NSColor.white.withAlphaComponent(0.13).setFill()
        NSBezierPath(roundedRect: track, xRadius: barH / 2, yRadius: barH / 2).fill()
        let fill = NSRect(x: track.minX, y: y, width: barW * frac, height: barH)
        color.setFill()
        NSBezierPath(roundedRect: fill, xRadius: barH / 2, yRadius: barH / 2).fill()
        y -= barH + gap
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
let want: [(Int, String)] = [
    (16, "icon_16x16.png"), (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"), (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"), (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"), (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"), (1024, "icon_512x512@2x.png"),
]
for (px, name) in want {
    guard let d = render(px) else { continue }
    try? d.write(to: URL(fileURLWithPath: "\(out)/\(name)"))
}
print("wrote \(want.count) images to \(out)")
