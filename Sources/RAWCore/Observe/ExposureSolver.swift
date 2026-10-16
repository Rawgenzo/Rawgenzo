import Foundation

/// 明るさの目標(平均輝度・白飛びの上限など)を満たす露出とハイライト回復を探す。
///
/// 人はスライダーを動かしては見る、を繰り返して合わせるが、その往復を AI にさせると道具の呼び出しが増える
/// (2026-10-16 の試験では、明るさを揃える指示に統計の取得が 17 回かかった)。目標だけを受け取り、ここで探す。
///
/// 探索は二分法。次の単調性を前提にしている(実サンプルのテストで確かめてある):
/// - 露出を上げると、平均・中央の輝度も白飛びの割合も増える
/// - ハイライト回復を上げると、白飛びの割合は減る
public struct ExposureSolver {
    public struct Target: Equatable, Sendable {
        /// 目標の平均輝度(出力の sRGB、0...1)。中央値と両方は指定しない
        public var meanLuminance: Double?
        /// 目標の輝度の中央値
        public var medianLuminance: Double?
        /// 白飛びの割合の上限(0...1。0.01 = 1%)
        public var maxHighlightClipping: Double?
        /// 白飛びを抑えるのにハイライト回復を使ってよいか(使えないか足りなければ露出を下げる)
        public var allowHighlightRecovery: Bool
        /// 輝度の目標の許容差
        public var tolerance: Double

        public init(meanLuminance: Double? = nil, medianLuminance: Double? = nil,
                    maxHighlightClipping: Double? = nil, allowHighlightRecovery: Bool = true,
                    tolerance: Double = 0.01) {
            self.meanLuminance = meanLuminance
            self.medianLuminance = medianLuminance
            self.maxHighlightClipping = maxHighlightClipping
            self.allowHighlightRecovery = allowHighlightRecovery
            self.tolerance = tolerance
        }

        func luminance(_ s: ImageStats) -> Double? {
            if let m = meanLuminance { return s.meanLuminance - m }
            if let m = medianLuminance { return s.medianLuminance - m }
            return nil
        }
    }

    public struct Result {
        public var settings: DevelopSettings
        /// 探索に使った解像度での最後の統計
        public var stats: ImageStats
        public var luminanceMet: Bool
        public var clippingMet: Bool
        /// 目標を満たせなかった理由など
        public var notes: [String]
        /// 現像して統計を取った回数
        public var evaluations: Int
    }

    public static let exposureRange = ParameterCatalog["exposure"].range
    public static let highlightsRange = ParameterCatalog["hdr.highlights"].range

    /// 粗い解像度で探してから、細かい解像度で仕上げる。白飛びの割合は解像度で変わる(縮小すると小さな白飛びが
    /// 平均されて消える)ので、結果は AI が get_stats で見るのと同じ解像度(fine)で目標を満たすようにする
    public static func solve(from start: DevelopSettings, target: Target,
                             coarse: (DevelopSettings) throws -> ImageStats,
                             fine: (DevelopSettings) throws -> ImageStats) throws -> Result {
        let first = try solve(from: start, target: target, evaluate: coarse)
        var second = try solve(from: first.settings, target: target, evaluate: fine)
        second.evaluations += first.evaluations
        return second
    }

    /// - evaluate: 設定で現像して統計を返す(呼ぶたびに現像するので重い)
    public static func solve(from start: DevelopSettings, target: Target,
                             evaluate: (DevelopSettings) throws -> ImageStats) throws -> Result {
        var evaluations = 0
        // 探索で変えるのは露出とハイライト回復だけなので、その 2 つで同じ設定の現像を省く
        struct Key: Hashable { var exposure: Double; var highlights: Double }
        var cache: [Key: ImageStats] = [:]
        func stats(_ s: DevelopSettings) throws -> ImageStats {
            let key = Key(exposure: s.exposure, highlights: s.hdr.highlights)
            if let c = cache[key] { return c }
            evaluations += 1
            let r = try evaluate(s)
            cache[key] = r
            return r
        }
        func with(exposure e: Double? = nil, highlights h: Double? = nil, _ base: DevelopSettings) -> DevelopSettings {
            var s = base
            if let e { s.exposure = (e * 1000).rounded() / 1000 }
            if let h { s.hdr.highlights = (h * 1000).rounded() / 1000 }
            return s
        }

        var settings = start
        var notes: [String] = []
        let maxClip = target.maxHighlightClipping
        let wantsLuminance = target.meanLuminance != nil || target.medianLuminance != nil

        /// 輝度の目標に合う露出を探す(上限 upper まで)
        func fitLuminance(upper: Double) throws {
            guard wantsLuminance else { return }
            let current = try stats(settings)
            if abs(target.luminance(current)!) <= target.tolerance { return }
            var lo = exposureRange.lowerBound, hi = upper
            // 今の露出の近くで目標を挟めれば、その範囲だけで探す(粗い探索の結果から仕上げるとき、回数が少なくて済む)
            let e = settings.exposure
            let nearLo = max(lo, e - 0.5), nearHi = min(hi, e + 0.5)
            if nearLo < nearHi,
               try target.luminance(stats(with(exposure: nearLo, settings)))! <= 0,
               try target.luminance(stats(with(exposure: nearHi, settings)))! >= 0 {
                lo = nearLo; hi = nearHi
            }
            if try target.luminance(stats(with(exposure: hi, settings)))! < 0 {
                settings = with(exposure: hi, settings)
                return
            }
            if try target.luminance(stats(with(exposure: lo, settings)))! > 0 {
                settings = with(exposure: lo, settings)
                return
            }
            for _ in 0..<12 {
                let mid = (lo + hi) / 2
                let d = try target.luminance(stats(with(exposure: mid, settings)))!
                if abs(d) <= target.tolerance / 2 { lo = mid; hi = mid; break }
                if d < 0 { lo = mid } else { hi = mid }
                if hi - lo < 0.01 { break }
            }
            settings = with(exposure: (lo + hi) / 2, settings)
        }

        /// 白飛びが上限を超えていれば、ハイライト回復を上げて抑える(足りる最小の値)
        func fitClippingWithRecovery() throws {
            guard let maxClip, target.allowHighlightRecovery else { return }
            if try stats(settings).highlightClipping <= maxClip { return }
            var lo = settings.hdr.highlights, hi = highlightsRange.upperBound
            if try stats(with(highlights: hi, settings)).highlightClipping > maxClip {
                settings = with(highlights: hi, settings)
                return
            }
            for _ in 0..<10 {
                let mid = (lo + hi) / 2
                if try stats(with(highlights: mid, settings)).highlightClipping > maxClip { lo = mid } else { hi = mid }
                if hi - lo < 0.01 { break }
            }
            settings = with(highlights: hi, settings)
        }

        /// 白飛びの上限を満たす最大の露出
        func maxExposureForClipping() throws -> Double {
            guard let maxClip else { return exposureRange.upperBound }
            var lo = exposureRange.lowerBound, hi = settings.exposure
            if try stats(with(exposure: hi, settings)).highlightClipping <= maxClip { return hi }
            if try stats(with(exposure: lo, settings)).highlightClipping > maxClip { return lo }
            for _ in 0..<12 {
                let mid = (lo + hi) / 2
                if try stats(with(exposure: mid, settings)).highlightClipping > maxClip { hi = mid } else { lo = mid }
                if hi - lo < 0.01 { break }
            }
            return lo
        }

        // 1. 明るさを合わせる → 2. 白飛びをハイライト回復で抑える(明るさが下がるので合わせ直す。2 回まで)
        try fitLuminance(upper: exposureRange.upperBound)
        for _ in 0..<2 {
            let before = settings
            try fitClippingWithRecovery()
            try fitLuminance(upper: exposureRange.upperBound)
            if settings == before { break }
        }
        // 3. それでも白飛びが多ければ、露出を下げる(明るさの目標より白飛びの上限を優先する)
        if let maxClip, try stats(settings).highlightClipping > maxClip {
            let limit = try maxExposureForClipping()
            if limit < settings.exposure {
                settings = with(exposure: limit, settings)
                notes.append("白飛びの上限を守るため、露出を明るさの目標より低くした")
            }
        }

        let final = try stats(settings)
        let luminanceMet = !wantsLuminance || abs(target.luminance(final)!) <= target.tolerance
        let clippingMet = maxClip.map { final.highlightClipping <= $0 } ?? true
        if !luminanceMet, notes.isEmpty {
            // 探すのは露出とハイライト回復だけ。それ以外の項目で無理に合わせるかは人が決める(2026-10-16 の試験で、
            // AI が頼まれていない HDR の項目を試し、白飛びを 5% に増やした)。代わりの手段と副作用を伝えて判断を促す
            notes.append(target.luminance(final)! < 0
                         ? "露出を上限まで上げても目標の明るさに届かない。HDR のシャドウ持ち上げ(hdr.shadows)や強さ(hdr.strength)で"
                           + "さらに明るくできるが、白飛びやノイズが増えやすい。使うかどうかは人に確認すること"
                         : "露出を下限まで下げても目標の明るさより明るい。ハイライト回復(hdr.highlights)やコントラストで"
                           + "明るい部分を抑えられるが、見た目が変わる。使うかどうかは人に確認すること")
        }
        if !clippingMet { notes.append("露出を下限まで下げても白飛びが上限を超える") }
        return Result(settings: settings, stats: final, luminanceMet: luminanceMet, clippingMet: clippingMet,
                      notes: notes, evaluations: evaluations)
    }
}
