import CoreGraphics
import Foundation

/// 撮影情報の表示(調整パネルの「撮影情報」・AI の get_photo)
public enum ExifLabels {
    public static func exposureProgram(_ v: Int?) -> String? {
        switch v {
        case 1: return "マニュアル"
        case 2: return "プログラム"
        case 3: return "絞り優先"
        case 4: return "シャッター優先"
        case 5: return "クリエイティブ"
        case 6: return "アクション"
        case 7: return "ポートレート"
        case 8: return "風景"
        default: return nil
        }
    }

    public static func meteringMode(_ v: Int?) -> String? {
        switch v {
        case 1: return "平均"
        case 2: return "中央重点"
        case 3: return "スポット"
        case 4: return "マルチスポット"
        case 5: return "マルチ(分割)"
        case 6: return "部分"
        default: return nil
        }
    }

    public static func flash(_ v: Int?) -> String? {
        guard let v else { return nil }
        return v & 1 == 1 ? "発光" : "発光なし"
    }

    public static func whiteBalance(_ v: Int?) -> String? {
        switch v {
        case 0: return "オート"
        case 1: return "マニュアル"
        default: return nil
        }
    }

    public static func shutter(_ t: Double?) -> String? {
        guard let t, t > 0 else { return nil }
        return t < 1 ? "1/\(Int((1 / t).rounded()))" : String(format: "%.1f\"", t)
    }
}

/// 撮影時のピントの位置を、見えている画像の位置に直す
public enum FocusPointMapping {
    /// カメラの記録の向き(横長)の位置 → 写真を正しい向きにしたときの位置(EXIF の Orientation)
    public static func upright(_ p: CGPoint, orientation: Int?) -> CGPoint {
        switch orientation {
        case 6: return CGPoint(x: 1 - p.y, y: p.x)       // 90° 時計回りに回して見る
        case 8: return CGPoint(x: p.y, y: 1 - p.x)       // 90° 反時計回りに回して見る
        case 3: return CGPoint(x: 1 - p.x, y: 1 - p.y)   // 180°
        default: return p
        }
    }

    /// 正しい向きの位置 → 傾き補正と切り抜きの後の、見えている画像の位置(比率、左上原点)。枠の外なら nil。
    /// - imageAspect: 傾き補正前の画像の 幅/高さ(Photo.imageAspect)
    public static func displayed(_ p: CGPoint, crop: CropSettings?, imageAspect a: Double) -> CGPoint? {
        guard let c = crop else { return p }
        // CropStage と同じく、画像の中心で時計回りに回す(ピクセル比の座標で計算する)
        let t = c.angle * .pi / 180
        let dx = (Double(p.x) - 0.5) * a, dy = Double(p.y) - 0.5
        let rx = 0.5 * a + dx * cos(t) - dy * sin(t)
        let ry = 0.5 + dx * sin(t) + dy * cos(t)
        let x = (rx / a - c.x) / c.width, y = (ry - c.y) / c.height
        guard (0...1).contains(x), (0...1).contains(y) else { return nil }
        return CGPoint(x: x, y: y)
    }
}
