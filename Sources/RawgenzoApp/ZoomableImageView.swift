import SwiftUI
import AppKit
import RAWCore

/// 拡大・縮小・スクロールできるプレビュー。AppKit の NSScrollView を使う
/// (macOS 13 の SwiftUI の ScrollView には拡大の機能が無いため)。
///
/// 倍率は「写真の1ピクセル = 画面の物理ピクセル何個分か」(PreviewZoom)。
/// 文書ビューの大きさを「写真の等倍ピクセル数 ÷ 画面の倍率(Retina なら 2)」ポイントにしておくと、
/// NSScrollView の magnification がそのまま倍率になる。
///
/// 操作: ピンチ、⌘+スクロール、ダブルクリック(合わせる ⇔ 等倍)はどれも、カーソルの下の点を動かさずに拡大する。
/// 拡大中はドラッグで移動(カーソルは手の形)。
/// 写真を切り替えても倍率と表示位置(写真に対する割合)を保つ。
struct ZoomableImageView: NSViewRepresentable {
    let image: CGImage
    /// 写真の等倍のピクセル数(image は縮小して描いたものの場合がある)
    let imagePixels: CGSize
    @Binding var mode: PreviewZoom.Mode
    /// ウインドウに合わせたときの周りの余白(ポイント)
    var padding: CGFloat = 12
    /// 実際の倍率と、ウインドウに合わせたときの倍率を知らせる
    var onZoom: (_ display: Double, _ fit: Double) -> Void
    /// 写真の位置(このビューの座標、左上原点)。構図ガイドを重ねるのに使う
    var onImageFrame: (CGRect) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> ZoomScrollView {
        let scrollView = ZoomScrollView()
        let clip = CenteringClipView()
        clip.drawsBackground = false
        clip.postsBoundsChangedNotifications = true
        scrollView.contentView = clip
        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.allowsMagnification = true
        scrollView.maxMagnification = PreviewZoom.maximum

        let document = ImageDocumentView()
        scrollView.documentView = document
        context.coordinator.attach(scrollView: scrollView, document: document)
        return scrollView
    }

    func updateNSView(_ scrollView: ZoomScrollView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.update()
    }

    @MainActor
    final class Coordinator: NSObject {
        var parent: ZoomableImageView
        private weak var scrollView: ZoomScrollView?
        private weak var document: ImageDocumentView?
        /// 最後に反映した表示のしかた(同じなら倍率を触らない。ユーザーのピンチを打ち消さないため)
        private var appliedMode: PreviewZoom.Mode?
        /// 倍率を変えている最中。setMagnification の途中でレイアウト → update() が割り込み、
        /// 「ウインドウに合わせる表示なのに倍率がずれた」と判断して元に戻してしまうのを防ぐ
        private var isApplying = false
        /// ピンチの最中(指を離すまでは update() から倍率を触らない)
        private var isLiveMagnifying = false
        private var lastReported: (display: Double, fit: Double)?
        private var lastFrame: CGRect?

        init(_ parent: ZoomableImageView) { self.parent = parent }

        func attach(scrollView: ZoomScrollView, document: ImageDocumentView) {
            self.scrollView = scrollView
            self.document = document
            let center = NotificationCenter.default
            center.addObserver(self, selector: #selector(liveMagnifyStarted),
                               name: NSScrollView.willStartLiveMagnifyNotification, object: scrollView)
            center.addObserver(self, selector: #selector(liveMagnifyEnded),
                               name: NSScrollView.didEndLiveMagnifyNotification, object: scrollView)
            center.addObserver(self, selector: #selector(boundsChanged),
                               name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
            scrollView.onLayout = { [weak self] in self?.update() }
            scrollView.onCommandScrollZoom = { [weak self] magnification, point in
                self?.userZoom { $0.setMagnification(magnification, centeredAt: point) }
            }
            document.onDoubleClick = { [weak self] point in self?.toggleFitAndActual(at: point) }
            document.onBackingChange = { [weak self] in self?.update() }
        }

        private var backingScale: CGFloat {
            scrollView?.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        }

        private var fitScale: Double {
            guard let scrollView else { return 1 }
            return PreviewZoom.fitScale(imagePixels: parent.imagePixels,
                                        viewPoints: scrollView.contentSize,
                                        backingScale: Double(backingScale),
                                        padding: Double(parent.padding))
        }

        /// SwiftUI の状態や大きさが変わったときに呼ぶ
        func update() {
            guard let scrollView, let document, !isApplying, !isLiveMagnifying else { return }
            isApplying = true
            defer { isApplying = false }

            document.image = parent.image
            document.magnifiesWithNearestNeighbor = scrollView.magnification > 1.001

            // 文書ビューの大きさ = 等倍ピクセル数 ÷ 画面の倍率。写真が変わったら、写真に対する表示位置を保つ
            let b = backingScale
            let docSize = CGSize(width: parent.imagePixels.width / b, height: parent.imagePixels.height / b)
            var keepCenter: CGPoint?
            // 縮小して描いた画像から逆算した等倍のピクセル数は端数が出るので、1 ピクセル未満の違いは無視する
            // (描画解像度を切り替えただけで位置を合わせ直さないように)
            if abs(document.frame.width - docSize.width) * b >= 1 || abs(document.frame.height - docSize.height) * b >= 1 {
                if document.frame.width > 0, document.frame.height > 0 {
                    keepCenter = normalizedVisibleCenter()
                }
                document.frame = CGRect(origin: .zero, size: docSize)
            }

            let fit = fitScale
            scrollView.minMagnification = min(fit, PreviewZoom.maximum)
            scrollView.maxMagnification = max(fit, PreviewZoom.maximum)

            let target: Double
            switch parent.mode {
            case .fit: target = fit
            case .scale(let z): target = min(max(z, Double(scrollView.minMagnification)), Double(scrollView.maxMagnification))
            }
            let modeChanged = appliedMode != parent.mode
            let fitDrifted = parent.mode == .fit && abs(Double(scrollView.magnification) - fit) > 1e-6
            if modeChanged || fitDrifted || keepCenter != nil {
                // ⌘+/⌘− などで倍率が変わったときは、今見ている所を中心に拡大・縮小する
                let center = keepCenter == nil ? visibleCenterInDocument() : nil
                if let center {
                    scrollView.setMagnification(CGFloat(target), centeredAt: center)
                } else {
                    scrollView.magnification = CGFloat(target)
                }
                if let keepCenter { scroll(toNormalizedCenter: keepCenter) }
                appliedMode = parent.mode
            }
            document.updatePanCursor()
            report()
        }

        // MARK: ユーザー操作

        @objc private func liveMagnifyStarted() { isLiveMagnifying = true }

        @objc private func liveMagnifyEnded() {
            isLiveMagnifying = false
            userZoom { _ in }   // 倍率はピンチで変わり済み。表示のしかたを合わせる
        }

        @objc private func boundsChanged() {
            reportFrame()
            document?.updatePanCursor()
        }

        /// ユーザー操作で倍率を変える。変えている間は update() を割り込ませず、終わったら表示のしかたを
        /// その倍率に合わせる(ウインドウに合わせた倍率とほぼ同じなら「合わせる」)。
        /// マウスや通知の処理の中なので、SwiftUI の状態をその場で書き換えてよい(ビューの更新中ではない)
        private func userZoom(_ change: (NSScrollView) -> Void) {
            guard let scrollView else { return }
            isApplying = true
            change(scrollView)
            isApplying = false
            let m = Double(scrollView.magnification)
            let fit = fitScale
            setMode(abs(m - fit) <= fit * 0.005 ? .fit : .scale(m))
        }

        /// ダブルクリック: ウインドウに合わせた表示なら、クリックした所がカーソルの下に残るように等倍へ。
        /// それ以外なら合わせる(setMagnification(centeredAt:) は「その点の画面上の位置を保つ」拡大)
        private func toggleFitAndActual(at point: CGPoint) {
            guard let scrollView else { return }
            isApplying = true
            let mode: PreviewZoom.Mode
            if parent.mode == .fit {
                mode = .scale(1)
                scrollView.setMagnification(1, centeredAt: point)
            } else {
                mode = .fit
                scrollView.magnification = CGFloat(fitScale)
            }
            isApplying = false
            setMode(mode)
        }

        private func setMode(_ mode: PreviewZoom.Mode) {
            appliedMode = mode
            document?.magnifiesWithNearestNeighbor = (scrollView?.magnification ?? 1) > 1.001
            document?.updatePanCursor()
            if parent.mode != mode { parent.mode = mode }
            report()
        }

        // MARK: 座標

        private func visibleCenterInDocument() -> CGPoint? {
            guard let clip = scrollView?.contentView else { return nil }
            let r = clip.bounds
            return CGPoint(x: r.midX, y: r.midY)
        }

        /// 見えている範囲の中心(写真の幅・高さに対する割合)
        private func normalizedVisibleCenter() -> CGPoint? {
            guard let document, let c = visibleCenterInDocument(),
                  document.frame.width > 0, document.frame.height > 0 else { return nil }
            return CGPoint(x: min(max(c.x / document.frame.width, 0), 1),
                           y: min(max(c.y / document.frame.height, 0), 1))
        }

        private func scroll(toNormalizedCenter n: CGPoint) {
            guard let scrollView, let document else { return }
            let clip = scrollView.contentView
            let size = clip.bounds.size
            let origin = CGPoint(x: n.x * document.frame.width - size.width / 2,
                                 y: n.y * document.frame.height - size.height / 2)
            let constrained = clip.constrainBoundsRect(CGRect(origin: origin, size: size))
            clip.scroll(to: constrained.origin)
            scrollView.reflectScrolledClipView(clip)
        }

        // MARK: 知らせる

        private func report() {
            guard let scrollView else { return }
            let now = (Double(scrollView.magnification), fitScale)
            if lastReported.map({ $0.display != now.0 || $0.fit != now.1 }) ?? true {
                lastReported = now
                let onZoom = parent.onZoom
                DispatchQueue.main.async { onZoom(now.0, now.1) }
            }
            reportFrame()
        }

        private func reportFrame() {
            guard let scrollView, let document else { return }
            var r = scrollView.convert(document.bounds, from: document)
            if !scrollView.isFlipped { r.origin.y = scrollView.bounds.height - r.maxY }
            guard r != lastFrame else { return }
            lastFrame = r
            let onImageFrame = parent.onImageFrame
            DispatchQueue.main.async { onImageFrame(r) }
        }
    }
}

/// ⌘+スクロールで拡大・縮小する NSScrollView
final class ZoomScrollView: NSScrollView {
    var onLayout: (() -> Void)?
    /// ⌘+スクロールでの拡大・縮小(新しい倍率と、中心にする点)。倍率の変更は受け取った側で行う
    var onCommandScrollZoom: ((CGFloat, CGPoint) -> Void)?

    override func scrollWheel(with event: NSEvent) {
        guard event.modifierFlags.contains(.command), allowsMagnification else {
            super.scrollWheel(with: event)
            return
        }
        // トラックパッドは細かい量、マウスのホイールは1段ずつ来る
        let step = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY * 0.01 : event.scrollingDeltaY * 0.1
        let m = min(max(magnification * exp(step), minMagnification), maxMagnification)
        let point = contentView.convert(event.locationInWindow, from: nil)
        if let onCommandScrollZoom {
            onCommandScrollZoom(m, point)
        } else {
            setMagnification(m, centeredAt: point)
        }
    }

    override func layout() {
        super.layout()
        onLayout?()
    }
}

/// 写真が表示領域より小さいとき、中央に置くクリップビュー(既定では隅に寄る)
final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var r = super.constrainBoundsRect(proposedBounds)
        guard let document = documentView else { return r }
        let f = document.frame
        if r.width > f.width { r.origin.x = (f.width - r.width) / 2 }
        if r.height > f.height { r.origin.y = (f.height - r.height) / 2 }
        return r
    }
}

/// 写真を描く文書ビュー。左上原点。ダブルクリックとドラッグでの移動を受け持つ
final class ImageDocumentView: NSView {
    var onDoubleClick: ((CGPoint) -> Void)?
    var onBackingChange: (() -> Void)?

    var image: CGImage? {
        didSet { if image !== oldValue { needsDisplay = true } }
    }
    /// 等倍より大きく表示するときは、ピクセルをぼかさずにそのまま拡大する(ピント・ノイズの確認用)
    var magnifiesWithNearestNeighbor = false {
        didSet { if magnifiesWithNearestNeighbor != oldValue { needsDisplay = true } }
    }

    private var lastDragPoint: CGPoint?
    /// ドラッグ中の手のカーソルを出したか(出した分だけ戻す)
    private var pushedCursor = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        guard let layer else { return }
        layer.contents = image
        layer.contentsGravity = .resize
        layer.minificationFilter = .trilinear
        layer.magnificationFilter = magnifiesWithNearestNeighbor ? .nearest : .linear
    }

    /// 拡大して写真がはみ出しているときは、ドラッグで動かせることを手の形のカーソルで示す
    override func resetCursorRects() {
        super.resetCursorRects()
        if canPan { addCursorRect(visibleRect, cursor: .openHand) }
    }

    /// 倍率や表示位置が変わったら、カーソルの範囲を作り直す
    func updatePanCursor() {
        window?.invalidateCursorRects(for: self)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        onBackingChange?()
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onDoubleClick?(convert(event.locationInWindow, from: nil))
            return
        }
        lastDragPoint = event.locationInWindow
        if canPan {
            NSCursor.closedHand.push()
            pushedCursor = true
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard canPan, let last = lastDragPoint,
              let scrollView = enclosingScrollView else { return }
        let p = event.locationInWindow
        lastDragPoint = p
        let clip = scrollView.contentView
        let m = scrollView.magnification
        var origin = clip.bounds.origin
        // ウインドウ座標は上向き、この文書ビューは下向き。写真を指の動きに合わせて動かす
        origin.x -= (p.x - last.x) / m
        origin.y += (p.y - last.y) / m
        let constrained = clip.constrainBoundsRect(CGRect(origin: origin, size: clip.bounds.size))
        clip.scroll(to: constrained.origin)
        scrollView.reflectScrolledClipView(clip)
    }

    override func mouseUp(with event: NSEvent) {
        if pushedCursor { NSCursor.pop() }
        pushedCursor = false
        lastDragPoint = nil
    }

    /// 写真が表示領域からはみ出しているとき(=動かす意味があるとき)だけドラッグで動かす
    private var canPan: Bool {
        guard let clip = enclosingScrollView?.contentView else { return false }
        return frame.width > clip.bounds.width + 0.5 || frame.height > clip.bounds.height + 0.5
    }
}
