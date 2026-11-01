import Foundation

/// トーンカーブのチャンネル。rawValue はサイドカーに保存されるので変えない
public enum ToneCurveChannel: String, Codable, CaseIterable, Sendable {
    case luma, red, green, blue

    public var label: String {
        switch self {
        case .luma: return "輝度"
        case .red: return "R"
        case .green: return "G"
        case .blue: return "B"
        }
    }
}

/// カーブの点。x = 入力、y = 出力(どちらも見た目の明るさ = sRGB のガンマを掛けた値の 0...1)。
/// 保存は [x, y] の 2 つの数(サイドカーを短くするため)
public struct CurvePoint: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double

    public init(_ x: Double, _ y: Double) { self.x = x; self.y = y }

    public init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        x = try c.decode(Double.self)
        y = try c.decode(Double.self)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.unkeyedContainer()
        try c.encode(x)
        try c.encode(y)
    }
}

/// トーンカーブ(docs/tone-curve-design.md)。チャンネルごとの点の並びと、輝度のカーブの「彩度の連動」
public struct ToneCurveSettings: Codable, Equatable, Sendable {
    /// 点の数の上限(Lightroom と同じ)
    public static let maxPoints = 16
    /// 隣の点との x の最小の間隔
    public static let minGap = 0.01
    /// 変えていないカーブ
    public static let identity = [CurvePoint(0, 0), CurvePoint(1, 1)]

    public var luma: [CurvePoint] = ToneCurveSettings.identity
    public var red: [CurvePoint] = ToneCurveSettings.identity
    public var green: [CurvePoint] = ToneCurveSettings.identity
    public var blue: [CurvePoint] = ToneCurveSettings.identity
    /// 彩度の連動 0...1。0 = 輝度のカーブは明るさだけ変え、色合いと彩度を保つ(コントラストのスライダーと同じ計算)。
    /// 1 = R・G・B それぞれに輝度のカーブを当てる(S 字なら彩度も上がる)
    public var saturationLink: Double = 0

    public init() {}

    public subscript(_ channel: ToneCurveChannel) -> [CurvePoint] {
        get {
            switch channel {
            case .luma: return luma
            case .red: return red
            case .green: return green
            case .blue: return blue
            }
        }
        set {
            let v = Self.normalized(newValue)
            switch channel {
            case .luma: luma = v
            case .red: red = v
            case .green: green = v
            case .blue: blue = v
            }
        }
    }

    /// どのカーブも画像を変えない(彩度の連動は輝度のカーブが無ければ効かない)。描くときに段を省くかの判断
    public var isNeutral: Bool { ToneCurveChannel.allCases.allSatisfy { Self.isIdentity(self[$0]) } }

    /// 何も設定していない(どのチャンネルも端の 2 点だけで、彩度の連動も 0)。設定ごと消してよいかの判断。
    /// isNeutral で消すと、変えていないカーブの上(斜めの線の上)に足した点が、足したそばから消えた
    /// (選んでいた番号が右上の端の点を指し、点が足されずに 255・255 が出た。2026-10-30、オーナーの確認)
    public var isEmpty: Bool {
        ToneCurveChannel.allCases.allSatisfy { Self.isDefault(self[$0]) } && saturationLink == 0
    }

    /// 端の 2 点だけ(点を足していない)
    public static func isDefault(_ points: [CurvePoint]) -> Bool { points == identity }

    public static func isIdentity(_ points: [CurvePoint]) -> Bool {
        points.allSatisfy { abs($0.x - $0.y) < 1e-9 }
    }

    /// 点の並びを使える形にする: 0...1 に丸め、x の順に並べ、近すぎる点を除き、端(x = 0 と 1)を必ず置き、上限の数に収める
    public static func normalized(_ points: [CurvePoint]) -> [CurvePoint] {
        // 手で壊したサイドカーの NaN などは捨てる(表が NaN になると画像が真っ黒になる)
        var p = points.filter { $0.x.isFinite && $0.y.isFinite }
            .map { CurvePoint(min(max($0.x, 0), 1), min(max($0.y, 0), 1)) }.sorted { $0.x < $1.x }
        guard !p.isEmpty else { return identity }
        if p[0].x > 0 { p.insert(CurvePoint(0, 0), at: 0) }
        if p[p.count - 1].x < 1 { p.append(CurvePoint(1, 1)) }
        var out: [CurvePoint] = []
        for q in p {
            if let last = out.last, q.x - last.x < minGap {
                // 端の点は残す(x = 1 の点は、手前の近すぎる点と入れ替える)
                if q.x == 1 { out[out.count - 1] = q }
                continue
            }
            out.append(q)
        }
        if out.count == 1 { out.append(CurvePoint(1, 1)) }
        if out.count > maxPoints { out = Array(out.prefix(maxPoints - 1)) + [out[out.count - 1]] }
        return out
    }

    private enum CodingKeys: String, CodingKey { case luma, red, green, blue, saturationLink }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        for channel in ToneCurveChannel.allCases {
            let key = CodingKeys(rawValue: channel.rawValue)!
            // 1 つのチャンネルが壊れていても、ほかは読む
            if let v = c.tolerant(key, as: [CurvePoint].self) { self[channel] = v }
        }
        saturationLink = min(max(c.tolerant(.saturationLink, default: 0), 0), 1)
    }

    /// 点を足していないチャンネルは書かない(斜めの線の上に足した点は、画像を変えなくても残す)
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        for channel in ToneCurveChannel.allCases where !Self.isDefault(self[channel]) {
            try c.encode(self[channel], forKey: CodingKeys(rawValue: channel.rawValue)!)
        }
        if saturationLink != 0 { try c.encode(saturationLink, forKey: .saturationLink) }
    }
}

/// 輝度のカーブの決まった形。id は AI の道具で使うので変えない
public enum ToneCurvePreset: String, CaseIterable, Sendable {
    case linear, weak, medium, strong

    public var label: String {
        switch self {
        case .linear: return "リニア"
        case .weak: return "弱いコントラスト"
        case .medium: return "中くらいのコントラスト"
        case .strong: return "強いコントラスト"
        }
    }

    public var points: [CurvePoint] {
        // 1/4 と 3/4 の 2 点で作る S 字(中央は動かさない)
        let d: Double
        switch self {
        case .linear: return ToneCurveSettings.identity
        case .weak: d = 0.025
        case .medium: d = 0.05
        case .strong: d = 0.08
        }
        return [CurvePoint(0, 0), CurvePoint(0.25, 0.25 - d), CurvePoint(0.75, 0.75 + d), CurvePoint(1, 1)]
    }

    /// 点の並びがどれかの形と同じならその形(違えば nil = カスタム)
    public static func matching(_ points: [CurvePoint]) -> ToneCurvePreset? {
        if ToneCurveSettings.isIdentity(points) { return .linear }
        return allCases.first { p in
            p.points.count == points.count
                && zip(p.points, points).allSatisfy { abs($0.x - $1.x) < 1e-6 && abs($0.y - $1.y) < 1e-6 }
        }
    }
}

/// 点を通るカーブ(単調な 3 次エルミート補間 = Fritsch–Carlson)。点の間で行き過ぎない(山や谷を作らない)。
/// 0...1 の外(HDR の 1 超え・負の値)は、端の接線で伸ばす(切らない・段差も折れ目も作らない)。
/// 傾きには下限を付ける(白を平らに寝かせたカーブで、1 を超える明るさが全部同じ値に潰れないように)
public struct ToneCurveFunction: Sendable {
    let xs: [Double]
    let ys: [Double]
    let ms: [Double]
    /// 0 の外・1 の外へ伸ばすときの傾き
    public let lowSlope: Double
    public let highSlope: Double
    /// 伸ばすときの傾きの下限
    public static let minExtensionSlope = 0.2

    public init(_ points: [CurvePoint]) {
        let p = ToneCurveSettings.normalized(points)
        let xs = p.map(\.x), ys = p.map(\.y)
        self.xs = xs; self.ys = ys
        let n = p.count
        let d = (0..<(n - 1)).map { (ys[$0 + 1] - ys[$0]) / (xs[$0 + 1] - xs[$0]) }
        var m = [Double](repeating: 0, count: n)
        m[0] = d[0]; m[n - 1] = d[n - 2]
        for i in stride(from: 1, to: n - 1, by: 1) {
            m[i] = d[i - 1] * d[i] <= 0 ? 0 : (d[i - 1] + d[i]) / 2
        }
        // 行き過ぎないよう傾きを抑える
        for i in 0..<(n - 1) {
            if d[i] == 0 { m[i] = 0; m[i + 1] = 0; continue }
            let a = m[i] / d[i], b = m[i + 1] / d[i]
            let s = a * a + b * b
            if s > 9 {
                let t = 3 / s.squareRoot()
                m[i] = t * a * d[i]; m[i + 1] = t * b * d[i]
            }
        }
        ms = m
        lowSlope = max(m[0], Self.minExtensionSlope)
        highSlope = max(m[n - 1], Self.minExtensionSlope)
    }

    public func callAsFunction(_ x: Double) -> Double {
        if x <= 0 { return ys[0] + x * lowSlope }
        if x >= 1 { return ys[ys.count - 1] + (x - 1) * highSlope }
        var i = 0
        while i < xs.count - 2, xs[i + 1] <= x { i += 1 }
        let h = xs[i + 1] - xs[i]
        let t = (x - xs[i]) / h
        let t2 = t * t, t3 = t2 * t
        return (2 * t3 - 3 * t2 + 1) * ys[i] + (t3 - 2 * t2 + t) * h * ms[i]
            + (-2 * t3 + 3 * t2) * ys[i + 1] + (t3 - t2) * h * ms[i + 1]
    }

    /// 0...1 を n 区間に分けた表(GPU に渡す)
    public func table(_ n: Int) -> [Float] {
        (0..<n).map { Float(self(Double($0) / Double(n - 1))) }
    }
}
