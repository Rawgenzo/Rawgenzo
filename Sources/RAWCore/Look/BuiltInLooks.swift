import CoreImage
import CoreImage.CIFilterBuiltins
import simd

/// 組み込みの「〜風」ルック。
/// 追加するときは ColorCubeLook を1つ書いて all に足すだけ。
public enum BuiltInLooks {
    public static var all: [Look] { [film, cinema, mono, nostalgic] }

    /// フィルム風: 黒が少し浮いた柔らかいコントラスト、わずかに暖色、彩度控えめ
    public static let film = ColorCubeLook(id: "builtin.film", displayName: "フィルム風") { c in
        var o = ColorMath.sCurve(c, 0.35)
        o = ColorMath.fade(o, black: 0.04, white: 0.97)
        o *= SIMD3(1.03, 1.0, 0.95)
        return ColorMath.saturate(o, 0.88)
    }

    /// シネマ風: 暗部を青緑、明部をオレンジに寄せる (ティール&オレンジ)
    public static let cinema = ColorCubeLook(id: "builtin.cinema", displayName: "シネマ風") { c in
        let l = ColorMath.luminance(c)
        var o = c
        o += SIMD3(-0.05, 0.015, 0.06) * (1 - l)   // 暗部 → ティール
        o += SIMD3(0.06, 0.015, -0.05) * l         // 明部 → オレンジ
        o = ColorMath.sCurve(o, 0.3)
        return ColorMath.saturate(o, 0.92)
    }

    /// モノクロ: 赤フィルター寄りの白黒(空が締まり、肌が明るい)
    public static let mono = ColorCubeLook(id: "builtin.mono", displayName: "モノクロ") { c in
        let l = simd_dot(c, SIMD3<Float>(0.45, 0.42, 0.13))
        return SIMD3(repeating: ColorMath.sCurve(l, 0.4))
    }

    /// ノスタルジック: 暖色で色褪せた雰囲気 + 周辺減光
    public static let nostalgic = ColorCubeLook(
        id: "builtin.nostalgic", displayName: "ノスタルジック",
        transform: { c in
            var o = c * SIMD3(1.06, 1.0, 0.86)
            o = ColorMath.fade(o, black: 0.07, white: 0.94)
            return ColorMath.saturate(o, 0.75)
        },
        finish: { image in
            let v = CIFilter.vignette()
            v.inputImage = image
            v.intensity = 0.8
            v.radius = 1.5   // CIVignetteの半径は画像サイズに対する相対値 (0...2)
            return v.outputImage ?? image
        }
    )
}
