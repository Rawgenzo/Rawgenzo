import CoreGraphics
import CoreImage
import CoreText
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

    /// 番号付きで描く線(傾きの推定の候補など)
    public struct Mark: Sendable {
        public enum Color: Sendable { case horizontal, vertical, subject }
        public var label: String
        public var from: CGPoint
        public var to: CGPoint
        public var color: Color
        public init(label: String, from: CGPoint, to: CGPoint, color: Color) {
            self.label = label; self.from = from; self.to = to; self.color = color
        }
    }

    static func cgColor(_ c: Mark.Color) -> CGColor {
        switch c {
        case .horizontal: return CGColor(srgbRed: 0.3, green: 0.85, blue: 1.0, alpha: 1)
        case .vertical: return CGColor(srgbRed: 1.0, green: 0.55, blue: 0.3, alpha: 1)
        case .subject: return CGColor(srgbRed: 0.5, green: 1.0, blue: 0.4, alpha: 1)
        }
    }

    /// - frame: 切り抜き枠(nil なら描かない)。枠の外は暗くする
    /// - guides: 描くガイド。guideArea(既定は枠、枠が無ければ画像全体)の中に描く
    /// - marks: 番号付きの線
    public static func draw(on image: CIImage, frame: CGRect?, guides: [CompositionGuide] = [],
                            guideArea: CGRect? = nil, options: GuideOptions = GuideOptions(),
                            marks: [Mark] = [], grid: Bool = false) throws -> CIImage {
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
        // 座標の目盛り(10% ごと。0.5 は少し太く)。AI が写真の中の位置を比率で読むため(色別補正の色を拾う位置など)
        if grid {
            let labelFont = CTFontCreateWithName("Helvetica" as CFString, max(10, CGFloat(max(w, h)) / 70), nil)
            for k in 1..<10 {
                let t = CGFloat(k) / 10
                let lineWidth = (k == 5 ? 1.6 : 0.8) * line / 2
                for (a, b) in [(CGPoint(x: t * CGFloat(w), y: 0), CGPoint(x: t * CGFloat(w), y: CGFloat(h))),
                               (CGPoint(x: 0, y: (1 - t) * CGFloat(h)), CGPoint(x: CGFloat(w), y: (1 - t) * CGFloat(h)))] {
                    for (color, extra) in [(CGColor(gray: 0, alpha: 0.35), lineWidth), (CGColor(gray: 1, alpha: 0.55), 0)] {
                        ctx.setStrokeColor(color); ctx.setLineWidth(lineWidth + extra)
                        ctx.move(to: a); ctx.addLine(to: b); ctx.strokePath()
                    }
                }
                let label = String(format: "%.1f", Double(t))
                for (pos, isX) in [(CGPoint(x: t * CGFloat(w) + 3, y: CGFloat(h) - 14), true),
                                   (CGPoint(x: 3, y: (1 - t) * CGFloat(h) + 3), false)] {
                    _ = isX
                    let text = NSAttributedString(string: label, attributes: [
                        NSAttributedString.Key(kCTFontAttributeName as String): labelFont,
                        NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 0.95),
                    ])
                    let ctLine = CTLineCreateWithAttributedString(text)
                    ctx.textPosition = .zero
                    let bounds = CTLineGetImageBounds(ctLine, ctx)
                    ctx.setFillColor(CGColor(gray: 0, alpha: 0.5))
                    ctx.fill(CGRect(x: pos.x - 2, y: pos.y - 2, width: bounds.width + 4, height: bounds.height + 4))
                    ctx.textPosition = CGPoint(x: pos.x - bounds.minX, y: pos.y - bounds.minY)
                    CTLineDraw(ctLine, ctx)
                }
            }
        }

        // 番号付きの線: 線を描いてから、端に番号の札を置く(札は画像の中に収める)
        let fontSize = max(11, CGFloat(max(w, h)) / 60)
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, fontSize, nil)
        var placed: [CGRect] = []
        for m in marks {
            let a = CGPoint(x: m.from.x * CGFloat(w), y: (1 - m.from.y) * CGFloat(h))
            let b = CGPoint(x: m.to.x * CGFloat(w), y: (1 - m.to.y) * CGFloat(h))
            for (color, extra) in [(CGColor(gray: 0, alpha: 0.6), line * 1.2), (cgColor(m.color), 0)] {
                ctx.saveGState()
                ctx.setStrokeColor(color); ctx.setLineWidth(line * 1.2 + extra); ctx.setLineCap(.round)
                ctx.move(to: a); ctx.addLine(to: b); ctx.strokePath()
                ctx.restoreGState()
            }
            let text = NSAttributedString(string: m.label, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1),
            ])
            let ctLine = CTLineCreateWithAttributedString(text)
            // CTLineGetImageBounds は今の文字の位置からの範囲を返すので、0 にしてから測る
            // (しないと、1 つ前の札の位置だけずれて、札と番号が離れた)
            ctx.textPosition = .zero
            let bounds = CTLineGetImageBounds(ctLine, ctx)
            let pad = fontSize * 0.25
            let size = CGSize(width: bounds.width + pad * 2, height: fontSize + pad)
            // 線の左端(縦の線なら上端)の少し外に置く
            let anchor = m.from.x <= m.to.x ? a : b
            var box = CGRect(x: anchor.x - size.width / 2, y: anchor.y + line * 2, width: size.width, height: size.height)
            box.origin.x = min(max(box.minX, 0), CGFloat(w) - box.width)
            box.origin.y = min(max(box.minY, 0), CGFloat(h) - box.height)
            // 先に置いた札と重なるなら、横にずらす(窓のブラインドのように線が密集すると、番号が隠れて選べなくなる)
            for _ in 0..<8 where placed.contains(where: { $0.insetBy(dx: -1, dy: -1).intersects(box) }) {
                box.origin.x += box.width + pad
                if box.maxX > CGFloat(w) { box.origin.x = 0; box.origin.y = max(box.minY - box.height - pad, 0) }
            }
            placed.append(box)
            ctx.setFillColor(cgColor(m.color))
            ctx.addPath(CGPath(roundedRect: box, cornerWidth: pad, cornerHeight: pad, transform: nil))
            ctx.fillPath()
            ctx.textPosition = CGPoint(x: box.minX + pad - bounds.minX, y: box.minY + pad * 0.6 + fontSize * 0.15)
            CTLineDraw(ctLine, ctx)
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
