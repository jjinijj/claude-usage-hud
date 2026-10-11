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

let out = 128                 // HUD 가 쓰는 논리 해상도. 64pt·32pt 로 정수배 축소된다.
let bottomMargin = 3

/*
 * 알파는 0 아니면 255 로 자른다. 생성된 시트는 배경이 완전 투명이 아니라
 * a=16~31 의 옅은 안개가 깔려 있는 경우가 있다. 그대로 두면 캐릭터 뒤에
 * 회색 사각형이 비치고, 경계 판정도 안개를 내용으로 세어 프레임마다
 * 크기가 달라진다. 실제 내용은 a>=240 에 몰려 있어서 128 로 잘라도
 * 여유가 크다.
 */
let alphaCut: UInt8 = 128

/*
 * 칸 크기는 시트마다 다르다(512px 도, 443.5px 도 있었다). 정수배를 가정하는
 * 대신 논리 픽셀의 중심을 집는다 — 512px 칸이면 (x+0.5)*4 = 4x+2 로, 기존
 * 정수배 방식과 같은 좌표가 나온다. 격자는 명시로 받는다. 가로세로 비만으로는
 * 4x2 와 2x1 을 구별할 수 없어서 자동 판별이 안 된다.
 */
guard CommandLine.arguments.count >= 3 else {
    print("usage: make-sprites <input> <output.png> [<cols>x<rows>]  (기본 3x2)"); exit(1)
}
let grid = CommandLine.arguments.count >= 4 ? CommandLine.arguments[3] : "3x2"
let gp = grid.split(separator: "x").compactMap { Int($0) }
guard gp.count == 2, gp[0] > 0, gp[1] > 0 else {
    print("격자 형식이 잘못됐습니다: \(grid) — 예: 4x2"); exit(1)
}
let cols = gp[0], rows = gp[1]
guard let img = NSImage(contentsOfFile: CommandLine.arguments[1]),
      let tiff = img.tiffRepresentation,
      let src = NSBitmapImageRep(data: tiff),
      let sBuf = src.bitmapData else {
    print("입력을 읽지 못했습니다"); exit(1)
}
let sSPP = src.samplesPerPixel, sRow = src.bytesPerRow
// 칸 크기가 정수로 떨어지지 않는 시트가 있어 실수로 둔다 (1774/4 = 443.5)
let cwF = Double(src.pixelsWide) / Double(cols), chF = Double(src.pixelsHigh) / Double(rows)
let cw = Int(cwF.rounded()), ch = Int(chF.rounded())
let step = cwF / Double(out)        // 논리 픽셀 하나가 차지하는 원본 픽셀 수
print("  격자 \(cols)x\(rows)  칸 \(String(format: "%.1f", cwF))x\(String(format: "%.1f", chF))px  "
      + "논리 \(out)px  (논리 1px = 원본 \(String(format: "%.2f", step))px)")

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
    let idx = r * cols + c
    let ox = Int((Double(c) * cwF).rounded()), oy = Int((Double(r) * chF).rounded())
    var minX = cw, maxX = -1, minY = ch, maxY = -1
    for y in 0..<ch { for x in 0..<cw where alphaAt(ox + x, oy + y) >= alphaCut {
        if x < minX { minX = x }; if x > maxX { maxX = x }
        if y < minY { minY = y }; if y > maxY { maxY = y }
    }}
    guard maxX >= 0 else { continue }

    let sw = Int(Double(maxX - minX + 1) / step), sh = Int(Double(maxY - minY + 1) / step)
    let left = out / 2 - sw / 2, top = out - bottomMargin - sh

    for y in 0..<sh { for x in 0..<sw {
        // 논리 픽셀의 한가운데 — 평균을 내면 가장자리가 흐려진다
        let sx = ox + minX + Int((Double(x) + 0.5) * step)
        let sy = oy + minY + Int((Double(y) + 0.5) * step)
        guard sx < src.pixelsWide, sy < src.pixelsHigh else { continue }
        let dx = idx * out + left + x, dy = top + y
        guard dx >= 0, dx < dst.pixelsWide, dy >= 0, dy < dst.pixelsHigh else { continue }
        let s = sy * sRow + sx * sSPP, d = dy * dRow + dx * 4
        guard sSPP < 4 || sBuf[s + 3] >= alphaCut else { continue }   // 투명은 건너뛴다
        dBuf[d]     = sBuf[s]
        dBuf[d + 1] = sBuf[s + (sSPP > 1 ? 1 : 0)]
        dBuf[d + 2] = sBuf[s + (sSPP > 2 ? 2 : 0)]
        dBuf[d + 3] = 255
    }}
    print(String(format: "  프레임 %d  %3dx%3d → x:%3d y:%3d", idx + 1, sw, sh, left, top))
}}

guard let data = dst.representation(using: .png, properties: [:]) else { exit(1) }
try? data.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
print("  저장: \(CommandLine.arguments[2]) (\(dst.pixelsWide)x\(dst.pixelsHigh))")
