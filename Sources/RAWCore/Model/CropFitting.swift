import Foundation

/// 傾き補正をしたとき、クロップ枠を「回転後の画像」の内側に収めるための幾何計算。
///
/// CropStage は画像を中心で回転させ、元の大きさの枠で切る。回転した画像は枠の四隅を埋めきれないので、
/// クロップ枠がその隙間にかかると透明になる。ここでは枠が
///   1. 元の枠(正規化座標 0...1)の内側
///   2. 回転した画像の内側
/// の両方に入るように、大きさや位置を合わせる。
extension CropSettings {
    /// 枠が回転後の画像の内側に収まっているか(四隅が透明にならないか)
    public func isInsideImage(imageAspect: Double) -> Bool {
        let g = CropGeometry(self, imageAspect: imageAspect)
        return g.maxScale(center: g.center) >= 1 - CropGeometry.tolerance
    }

    /// 中心と縦横比を保ったまま、内側に収まるまで縮める。収まっていればそのまま返す(広げない)。
    /// 中心が画像の外側にあって縮めるだけでは収まらないときは、中心を画像の中心側へ寄せる。
    public func fitted(imageAspect: Double, minSize: Double = 0.05) -> CropSettings {
        let g = CropGeometry(self, imageAspect: imageAspect)
        if g.maxScale(center: g.center) >= 1 - CropGeometry.tolerance { return self }
        // 短い辺が minSize を下回らない倍率
        let minScale = min(1, minSize / max(min(width, height), 1e-9))
        var center = g.center
        if g.maxScale(center: center) < minScale {
            if g.maxScale(center: .zero) < minScale {
                center = .zero   // 画像の中心に置いても無理なら、中心に置いて収まるだけ縮める
            } else {
                // 中心を画像の中心へ近づけていき、minScale の枠が収まる最初の位置で止める。
                // 収まる中心の範囲は凸なので、画像の中心へ向かう線分上で「収まらない→収まる」は一度だけ切り替わる。
                var lo = 0.0, hi = 1.0   // 寄せる割合。lo: 収まらない、hi: 収まる
                for _ in 0..<60 {
                    let mid = (lo + hi) / 2
                    if g.maxScale(center: center * (1 - mid)) >= minScale { hi = mid } else { lo = mid }
                }
                center = center * (1 - hi)
            }
        }
        let s = max(0, min(1, g.maxScale(center: center)))
        return g.settings(center: center, half: g.half * s, from: self)
    }

    /// 縦横比を保ったまま、内側に収まる最大の大きさにする(広げることも縮めることもある)。
    /// 位置は、その大きさで収まる位置のうち今の位置に一番近いところ(構図をなるべく崩さない)。
    ///
    /// 元の枠も回転した画像も、画像の中心について点対称な凸形なので、「ある大きさの枠が収まる中心の範囲」も
    /// 点対称な凸形になる。収まる位置が一つでもあれば画像の中心にも収まるので、最大の大きさは
    /// 画像の中心に置いたときの値で決まる。
    public func maximized(imageAspect: Double) -> CropSettings {
        let g = CropGeometry(self, imageAspect: imageAspect)
        // 収まる範囲が線や点に潰れて誤差ではみ出さないよう、ほんの少しだけ小さくする
        let s = g.maxScale(center: .zero) * (1 - 1e-9)
        guard s > 0 else { return fitted(imageAspect: imageAspect) }
        let centered = g.settings(center: .zero, half: g.half * s, from: self)
        let big = CropGeometry(centered, imageAspect: imageAspect)
        let result = big.settings(center: big.project(g.center), half: big.half, from: self)
        return result.isInsideImage(imageAspect: imageAspect) ? result : centered
    }

    /// 大きさを保ったまま (dx, dy)(正規化座標)だけ動かす。はみ出す場合は、収まる位置のうち
    /// 動かしたい位置に一番近いところで止める(縁に沿って滑るように動く)。
    /// 元の枠が大きすぎてどこにも収まらないときは、先に fitted で縮める。
    public func moved(dx: Double, dy: Double, imageAspect: Double) -> CropSettings {
        let base = fitted(imageAspect: imageAspect)
        let g = CropGeometry(base, imageAspect: imageAspect)
        let target = g.center + SIMD2(dx * imageAspect, dy)
        let moved = g.settings(center: g.project(target), half: g.half, from: base)
        // 交互射影は反復計算なので、万一収まらない結果になったら動かさない
        return moved.isInsideImage(imageAspect: imageAspect) ? moved : base
    }

    /// start(収まっている枠)から target へ x/y/幅/高さを直線的に動かしたとき、収まっている範囲で
    /// 一番 target に近い枠を返す。四隅のハンドルで大きさを変えるときに使う
    /// (start と target が同じ角を共有していれば、その角は動かない)。
    public static func limited(from start: CropSettings, toward target: CropSettings,
                               imageAspect: Double) -> CropSettings {
        func lerp(_ t: Double) -> CropSettings {
            var c = target
            c.x = start.x + (target.x - start.x) * t
            c.y = start.y + (target.y - start.y) * t
            c.width = start.width + (target.width - start.width) * t
            c.height = start.height + (target.height - start.height) * t
            return c
        }
        if target.isInsideImage(imageAspect: imageAspect) { return target }
        guard start.isInsideImage(imageAspect: imageAspect) else { return start }
        var lo = 0.0, hi = 1.0   // lo: 収まる側、hi: 収まらない側
        for _ in 0..<60 where hi - lo > 1e-12 {
            let mid = (lo + hi) / 2
            if lerp(mid).isInsideImage(imageAspect: imageAspect) { lo = mid } else { hi = mid }
        }
        return lerp(lo)
    }
}

/// ピクセル比の座標での計算。画像の高さを 1、幅を imageAspect とし、画像の中心を原点、y は下向き。
/// 正規化座標(0...1)のまま回転を扱うと、縦横比が 1 でない画像で結果が歪むので、必ずこの座標で計算する。
struct CropGeometry {
    /// 「収まっている」とみなす誤差
    static let tolerance = 1e-9

    let aspect: Double
    let cosA: Double
    let sinA: Double
    /// 枠の中心
    let center: SIMD2<Double>
    /// 枠の幅・高さの半分
    let half: SIMD2<Double>

    init(_ c: CropSettings, imageAspect: Double) {
        aspect = imageAspect
        let t = c.angle * .pi / 180
        cosA = cos(t)
        sinA = sin(t)
        center = SIMD2((c.x + c.width / 2 - 0.5) * imageAspect, c.y + c.height / 2 - 0.5)
        half = SIMD2(c.width * imageAspect / 2, c.height / 2)
    }

    /// 画面上の点を、回転する前の画像の座標に戻す。
    /// 角度が正 = 画面上で時計回り(CropStage と同じ)。y が下向きなので、この式で時計回りの逆回転になる。
    func unrotate(_ p: SIMD2<Double>) -> SIMD2<Double> {
        SIMD2(cosA * p.x + sinA * p.y, -sinA * p.x + cosA * p.y)
    }

    /// 中心を center に置き、半分の大きさを half × s にした枠が収まる最大の s(負なら中心が外)。
    /// 各角が満たすべき条件は s について一次式なので、式で直接求まる。
    func maxScale(center c: SIMD2<Double>) -> Double {
        let a = half.x, b = half.y
        let q = unrotate(c)
        let ac = abs(cosA), as_ = abs(sinA)
        var s = Double.infinity
        // 1. 元の枠の内側
        if a > 0 { s = min(s, (aspect / 2 - abs(c.x)) / a) }
        if b > 0 { s = min(s, (0.5 - abs(c.y)) / b) }
        // 2. 回転した画像の内側(四隅を逆回転して、回転前の画像に入っているか)
        let kx = a * ac + b * as_
        let ky = a * as_ + b * ac
        if kx > 0 { s = min(s, (aspect / 2 - abs(q.x)) / kx) }
        if ky > 0 { s = min(s, (0.5 - abs(q.y)) / ky) }
        return s
    }

    /// 大きさを half のまま動かせる中心の範囲(凸な多角形)の中で、p に一番近い点。
    /// 範囲は「軸に平行な長方形」と「回転した長方形」の重なりなので、Dykstra の交互射影で求める。
    func project(_ p: SIMD2<Double>) -> SIMD2<Double> {
        let a = half.x, b = half.y
        // 元の枠の内側に収まる中心の範囲
        let boxX = max(0, aspect / 2 - a), boxY = max(0, 0.5 - b)
        // 回転した画像の内側に収まる中心の範囲(回転前の座標で)
        let rotX = max(0, aspect / 2 - (a * abs(cosA) + b * abs(sinA)))
        let rotY = max(0, 0.5 - (a * abs(sinA) + b * abs(cosA)))

        func projectBox(_ v: SIMD2<Double>) -> SIMD2<Double> {
            SIMD2(min(max(v.x, -boxX), boxX), min(max(v.y, -boxY), boxY))
        }
        func projectRotated(_ v: SIMD2<Double>) -> SIMD2<Double> {
            let q = unrotate(v)
            let r = SIMD2(min(max(q.x, -rotX), rotX), min(max(q.y, -rotY), rotY))
            // 回転前の座標 → 画面の座標(unrotate の逆)
            return SIMD2(cosA * r.x - sinA * r.y, sinA * r.x + cosA * r.y)
        }

        var x = p
        var p1 = SIMD2<Double>.zero, p2 = SIMD2<Double>.zero
        for _ in 0..<200 {
            let y = projectBox(x + p1)
            p1 = x + p1 - y
            let next = projectRotated(y + p2)
            p2 = y + p2 - next
            let d = next - x
            x = next
            if (d * d).sum() < 1e-26 { break }
        }
        return x
    }

    /// ピクセル比の座標から CropSettings に戻す(角度・比率の設定は from から引き継ぐ)
    func settings(center c: SIMD2<Double>, half h: SIMD2<Double>, from base: CropSettings) -> CropSettings {
        var out = base
        out.width = 2 * h.x / aspect
        out.height = 2 * h.y
        out.x = (c.x - h.x) / aspect + 0.5
        out.y = c.y - h.y + 0.5
        return out
    }
}
