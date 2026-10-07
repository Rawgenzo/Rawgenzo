import Foundation

/// プレビューの表示倍率の計算(UI に依存しない部分)。
///
/// 倍率は「写真の1ピクセルが、画面の物理ピクセル何個分か」で表す。1 = 等倍(実際のサイズ)。
/// Retina ディスプレイでは 1 ポイント = 2 物理ピクセルなので、等倍の写真はポイントで見ると半分の大きさになる
/// (Lightroom の 1:1 と同じ考え方。プレビュー.app の「実際のサイズ」はポイント基準なので 2 倍に見える)。
public enum PreviewZoom {
    /// 表示のしかた
    public enum Mode: Equatable, Sendable {
        /// ウインドウに合わせる(ウインドウの大きさが変われば倍率も変わる)
        case fit
        /// 決まった倍率
        case scale(Double)
    }

    /// ⌘+ / ⌘− で順に切り替わる倍率
    public static let steps: [Double] = [0.25, 0.5, 1, 2, 4]
    public static var maximum: Double { steps.last ?? 4 }

    /// 倍率の比較に使う誤差(ピンチで 0.9999 倍のように端数が出るため)
    static let tolerance = 1e-3

    /// ウインドウに合わせたときの倍率
    /// - imagePixels: 写真の等倍のピクセル数
    /// - viewPoints: 表示領域の大きさ(ポイント)
    /// - backingScale: 1 ポイントあたりの物理ピクセル数(Retina なら 2)
    /// - padding: 周りに空ける余白(ポイント)
    public static func fitScale(imagePixels: CGSize, viewPoints: CGSize,
                                backingScale: Double, padding: Double = 0) -> Double {
        guard imagePixels.width > 0, imagePixels.height > 0 else { return 1 }
        let w = max(1, Double(viewPoints.width) - 2 * padding) * backingScale
        let h = max(1, Double(viewPoints.height) - 2 * padding) * backingScale
        return min(w / Double(imagePixels.width), h / Double(imagePixels.height))
    }

    /// 今の倍率から一段拡大した倍率(最大で止まる)
    public static func zoomedIn(from zoom: Double) -> Double {
        steps.first { $0 > zoom * (1 + tolerance) } ?? maximum
    }

    /// 今の倍率から一段縮小した表示。ウインドウに合わせた倍率以下になるなら .fit
    public static func zoomedOut(from zoom: Double, fitScale fit: Double) -> Mode {
        guard let next = steps.last(where: { $0 < zoom * (1 - tolerance) }),
              next > fit * (1 + tolerance) else { return .fit }
        return .scale(next)
    }

    /// 表示中の倍率に必要な描画解像度(RenderOptions.scale)。
    /// 画面に出す解像度がプレビュー用の解像度(previewScale)以下ならそれで足り、超えたら等倍で描く。
    /// 細かく段階を分けないのは、倍率を少し変えるたびに描き直さないため。
    public static func renderScale(zoom: Double, previewScale: Double) -> Double {
        let preview = min(1, previewScale)
        return zoom <= preview * (1 + tolerance) ? preview : 1
    }

    /// 倍率の表示用の文字列(例: 100%、33%)
    public static func percentText(_ zoom: Double) -> String {
        "\(Int((zoom * 100).rounded()))%"
    }
}
