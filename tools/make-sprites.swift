/*
 * 시트 한 장(3x2, 512px 셀)을 가로 스트립 PNG 한 장으로 바꾼다.
 *
 * 원본은 프레임마다 내용 위치가 어긋나 있다(가로 38px, 바닥 41px). 그대로
 * 재생하면 캐릭터가 밀리고 튄다. 그래서 각 프레임의 내용 경계를 재서
 * **바닥 중앙**을 기준으로 다시 앉힌다.
 *
 * 축소는 정확히 4:1이다. 원본의 픽셀 블록이 4px이라 블록당 한 점만 집으면
 * 격자가 그대로 살아난다. 보간을 쓰면 픽셀아트가 뭉개진다.
 *
 * 픽셀은 NSColor 가 아니라 바이트로 직접 다룬다. colorAt/setColor 는 느리고,
 * 컬러스페이스를 섞으면 경고를 쏟아낸다.
 */
import AppKit

let cols = 3, rows = 2, scale = 4
let out = 128                 // 512 / 4 — 이 그림의 논리 해상도
let bottomMargin = 3

guard CommandLine.arguments.count >= 3 else {
    print("usage: make-sprites <input> <output.png>"); exit(1)
}
guard let img = NSImage(contentsOfFile: CommandLine.arguments[1]),
      let tiff = img.tiffRepresentation,
      let src = NSBitmapImageRep(data: tiff),
      let sBuf = src.bitmapData else {
    print("입력을 읽지 못했습니다"); exit(1)
}
let sSPP = src.samplesPerPixel, sRow = src.bytesPerRow
let cw = src.pixelsWide / cols, ch = src.pixelsHigh / rows

@inline(__always) func alphaAt(_ x: Int, _ y: Int) -> UInt8 {
    sSPP < 4 ? 255 : sBuf[y * sRow + x * sSPP + 3]
}

guard let dst = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: out * cols * rows, pixelsHigh: out,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: out * cols * rows * 4, bitsPerPixel: 32),
      let dBuf = dst.bitmapData else { exit(1) }
memset(dBuf, 0, dst.bytesPerRow * dst.pixelsHigh)
let dRow = dst.bytesPerRow

for r in 0..<rows { for c in 0..<cols {
    let idx = r * cols + c, ox = c * cw, oy = r * ch
    var minX = cw, maxX = -1, minY = ch, maxY = -1
    for y in 0..<ch { for x in 0..<cw where alphaAt(ox + x, oy + y) > 25 {
        if x < minX { minX = x }; if x > maxX { maxX = x }
        if y < minY { minY = y }; if y > maxY { maxY = y }
    }}
    guard maxX >= 0 else { continue }

    let sw = (maxX - minX + 1) / scale, sh = (maxY - minY + 1) / scale
    let left = out / 2 - sw / 2, top = out - bottomMargin - sh

    for y in 0..<sh { for x in 0..<sw {
        // 4x4 블록의 가운데 점 — 평균을 내면 가장자리가 흐려진다
        let sx = ox + minX + x * scale + scale / 2
        let sy = oy + minY + y * scale + scale / 2
        guard sx < src.pixelsWide, sy < src.pixelsHigh else { continue }
        let dx = idx * out + left + x, dy = top + y
        guard dx >= 0, dx < dst.pixelsWide, dy >= 0, dy < dst.pixelsHigh else { continue }
        let s = sy * sRow + sx * sSPP, d = dy * dRow + dx * 4
        dBuf[d]     = sBuf[s]
        dBuf[d + 1] = sBuf[s + (sSPP > 1 ? 1 : 0)]
        dBuf[d + 2] = sBuf[s + (sSPP > 2 ? 2 : 0)]
        dBuf[d + 3] = sSPP < 4 ? 255 : sBuf[s + 3]
    }}
    print(String(format: "  프레임 %d  %3dx%3d → x:%3d y:%3d", idx + 1, sw, sh, left, top))
}}

guard let data = dst.representation(using: .png, properties: [:]) else { exit(1) }
try? data.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
print("  저장: \(CommandLine.arguments[2]) (\(dst.pixelsWide)x\(dst.pixelsHigh))")
