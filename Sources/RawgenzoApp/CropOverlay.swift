import SwiftUI
import RAWCore

/// プレビュー上のクロップ枠。中をドラッグで移動、四隅のハンドルで大きさを変える。
struct CropOverlay: View {
    @Binding var crop: CropSettings
    /// 元画像の 幅/高さ
    let imageAspect: Double
    /// 構図ガイド。表示中なら三分割グリッドの代わりに枠内へ描く
    var guides = GuideDisplay()

    @State private var dragStart: CropSettings?

    private enum Corner: CaseIterable { case topLeft, topRight, bottomLeft, bottomRight }

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let rect = CGRect(x: crop.x * size.width, y: crop.y * size.height,
                              width: crop.width * size.width, height: crop.height * size.height)

            ZStack(alignment: .topLeading) {
                // 枠の外を暗くする
                Path { p in
                    p.addRect(CGRect(origin: .zero, size: size))
                    p.addRect(rect)
                }
                .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))

                if guides.hasAnythingToDraw {
                    GuideOverlay(display: guides,
                                 aspect: crop.width / max(crop.height, 1e-6) * imageAspect)
                        .frame(width: rect.width, height: rect.height)
                        .offset(x: rect.minX, y: rect.minY)
                } else {
                    // ガイド非表示のときは標準の三分割グリッド
                    Path { p in
                        for i in 1...2 {
                            let fx = rect.minX + rect.width * CGFloat(i) / 3
                            let fy = rect.minY + rect.height * CGFloat(i) / 3
                            p.move(to: CGPoint(x: fx, y: rect.minY)); p.addLine(to: CGPoint(x: fx, y: rect.maxY))
                            p.move(to: CGPoint(x: rect.minX, y: fy)); p.addLine(to: CGPoint(x: rect.maxX, y: fy))
                        }
                    }
                    .stroke(Color.white.opacity(0.45), lineWidth: 0.5)
                }

                Path { $0.addRect(rect) }
                    .stroke(Color.white, lineWidth: 1.5)

                // 移動用の透明な面
                Color.white.opacity(0.001)
                    .frame(width: rect.width, height: rect.height)
                    .offset(x: rect.minX, y: rect.minY)
                    .gesture(moveGesture(in: size))

                ForEach(Corner.allCases, id: \.self) { corner in
                    handle
                        .position(point(of: corner, in: rect))
                        .gesture(resizeGesture(corner, in: size))
                }
            }
        }
    }

    private var handle: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(Color.white)
            .frame(width: 14, height: 14)
            .shadow(radius: 1)
    }

    private func point(of corner: Corner, in r: CGRect) -> CGPoint {
        switch corner {
        case .topLeft: return CGPoint(x: r.minX, y: r.minY)
        case .topRight: return CGPoint(x: r.maxX, y: r.minY)
        case .bottomLeft: return CGPoint(x: r.minX, y: r.maxY)
        case .bottomRight: return CGPoint(x: r.maxX, y: r.maxY)
        }
    }

    private func moveGesture(in size: CGSize) -> some Gesture {
        DragGesture()
            .onChanged { g in
                let start = beginDrag()
                // 回転後の画像からはみ出す位置へは動かさず、縁に沿って滑らせる
                crop = start.moved(dx: Double(g.translation.width / size.width),
                                   dy: Double(g.translation.height / size.height),
                                   imageAspect: imageAspect)
            }
            .onEnded { _ in dragStart = nil }
    }

    private func resizeGesture(_ corner: Corner, in size: CGSize) -> some Gesture {
        DragGesture()
            .onChanged { g in
                let start = beginDrag()
                let dx = Double(g.translation.width / size.width)
                let dy = Double(g.translation.height / size.height)
                let minSize = 0.05

                // 動かさない側の角を固定点にする
                let left = corner == .topLeft || corner == .bottomLeft
                let top = corner == .topLeft || corner == .topRight
                let anchorX = left ? start.x + start.width : start.x
                let anchorY = top ? start.y + start.height : start.y

                var w = max(minSize, start.width + (left ? -dx : dx))
                var h = max(minSize, start.height + (top ? -dy : dy))
                // 画像の外に出ない最大値
                let maxW = left ? anchorX : 1 - anchorX
                let maxH = top ? anchorY : 1 - anchorY
                w = min(w, maxW)
                h = min(h, maxH)

                // 比率固定: 正規化座標での 高さ = 幅 × 画像比 / 目標比
                if let ratio = start.aspect.value(imageAspect: imageAspect) {
                    let k = imageAspect / ratio
                    if w * k > h { w = h / k } else { h = w * k }
                    if h > maxH { h = maxH; w = h / k }
                    if w > maxW { w = maxW; h = w * k }
                }

                var c = start
                c.width = w
                c.height = h
                c.x = left ? anchorX - w : anchorX
                c.y = top ? anchorY - h : anchorY

                // 回転後の画像からはみ出さないところで止める(動かさない側の角はそのまま)
                var limited = CropSettings.limited(from: start, toward: c, imageAspect: imageAspect)
                if start.aspect.value(imageAspect: imageAspect) == nil {
                    // 比率が自由なら、幅と高さを別々に伸ばせるところまで伸ばす(縁に沿って滑らせる)
                    var wide = limited
                    wide.width = c.width; wide.x = c.x
                    limited = CropSettings.limited(from: limited, toward: wide, imageAspect: imageAspect)
                    var tall = limited
                    tall.height = c.height; tall.y = c.y
                    limited = CropSettings.limited(from: limited, toward: tall, imageAspect: imageAspect)
                }
                crop = limited
            }
            .onEnded { _ in dragStart = nil }
    }

    /// ドラッグ開始時の枠を覚えて返す。はみ出している枠(以前の版で保存したもの等)は、ここで内側に収める
    private func beginDrag() -> CropSettings {
        if let dragStart { return dragStart }
        let start = crop.fitted(imageAspect: imageAspect)
        dragStart = start
        return start
    }
}
