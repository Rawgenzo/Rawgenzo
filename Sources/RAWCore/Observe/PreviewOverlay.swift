import CoreGraphics
import CoreImage
import Foundation

/// AI に見せる縮小画像に、切り抜き枠と構図ガイドを描き込む。
/// 切り抜く前の全体と切り抜いた後の 2 枚を見比べなくても、1 枚で枠の位置と構図を確かめられるようにする。
/// 座標はクロップ・ガイドと同じく、画像に対する比率 (0...1, 左上原点)。
public enum PreviewOverlay {
    private static let context = CIContext(options: [.cacheIntermediates: false])

    /// ガイドの色(複数重ねたときに見分けられるよう、順に使う)
    static let guideColors: [CGColor] = [
        CGColor(srgbRed: 1.0, green: 0.8, blue: 0.3, alpha: 0.95),
        CGColor(srgbRed: 0.35, green: 0.85, blue: 1.0, alpha: 0.95),
        CGColor(srgbRed: 1.0, green: 0.45, blue: 0.75, alpha: 0.95),
    ]

    /// - frame: 切り抜き枠(nil なら描かない)。枠の外は暗くする
    /// - guides: 描くガイド。guideArea(既定は枠、枠が無ければ画像全体)の中に描く
    public static func draw(on image: CIImage, frame: CGRect?, guides: [CompositionGuide] = [],
                            guideArea: CGRect? = nil, options: GuideOptions = GuideOptions()) throws -> CIImage {
        let extent = image.extent.integral
        let w = Int(extent.width), h = Int(extent.height)
        guard w > 0, h > 0, let source = context.createCGImage(image, from: extent),
              let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw RAWError.renderFailed("枠やガイドを描けません")
        }
        ctx.draw(source, in: CGRect(x: 0, y: 0, width: w, height: h))
        // 線の太さは画像の大きさに合わせる(長辺 1000 で 2 ピクセルほど)
        let line = max(1.5, CGFloat(max(w, h)) / 500)

        if let f = frame {
            let r = pixelRect(f, width: w, height: h)
            ctx.saveGState()
            ctx.addRect(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.addRect(r)
            ctx.setFillColor(CGColor(gray: 0, alpha: 0.5))
            ctx.fillPath(using: .evenOdd)
            ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.95))
            ctx.setLineWidth(line)
            ctx.stroke(r)
            ctx.restoreGState()
        }

        let area = pixelRect(guideArea ?? frame ?? CGRect(x: 0, y: 0, width: 1, height: 1), width: w, height: h)
        for (i, guide) in guides.enumerated() {
            let color = guideColors[i % guideColors.count]
            for p in guide.paths(aspect: Double(area.width / max(area.height, 1)), options: options) {
                guard p.points.count >= 2 else { continue }
                let pts = p.points.map { CGPoint(x: area.minX + $0.x * area.width, y: area.maxY - $0.y * area.height) }
                let width = p.style == .fine ? line * 0.6 : line
                // 明るい所でも見えるよう、暗い縁取りの上に色の線を描く(アプリの表示と同じ)
                for (strokeColor, extra) in [(CGColor(gray: 0, alpha: 0.45), line * 0.8), (color, 0)] {
                    ctx.saveGState()
                    ctx.setStrokeColor(strokeColor)
                    ctx.setLineWidth(width + extra)
                    ctx.setLineCap(.round)
                    ctx.setLineJoin(.round)
                    if p.style == .dashed { ctx.setLineDash(phase: 0, lengths: [line * 4, line * 3]) }
                    ctx.addLines(between: pts)
                    ctx.strokePath()
                    ctx.restoreGState()
                }
            }
        }
        guard let out = ctx.makeImage() else { throw RAWError.renderFailed("枠やガイドを描けません") }
        return CIImage(cgImage: out)
    }

    /// 比率の座標(左上原点)→ CGContext のピクセル座標(左下原点)
    static func pixelRect(_ r: CGRect, width w: Int, height h: Int) -> CGRect {
        CGRect(x: r.minX * CGFloat(w), y: (1 - r.maxY) * CGFloat(h),
               width: r.width * CGFloat(w), height: r.height * CGFloat(h))
    }
}
