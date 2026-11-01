import Foundation

extension Double {
    /// 小数第 places 位までに丸める。AI に渡す JSON や保存する値から、意味のない桁を落とす
    public func rounded(toPlaces places: Int) -> Double {
        var scale = 1.0
        for _ in 0..<places { scale *= 10 }
        return (self * scale).rounded() / scale
    }
}
