import Foundation

public enum RAWError: Error, CustomStringConvertible {
    case unreadable(URL)
    case unsupportedCamera(make: String?, model: String?)
    case decoderUnavailable(URL)
    case renderFailed(String)

    public var description: String {
        switch self {
        case .unreadable(let url):
            return "ファイルを読み込めません: \(url.lastPathComponent)"
        case .unsupportedCamera(let make, let model):
            return "未対応のカメラです: \(make ?? "?") \(model ?? "?")"
        case .decoderUnavailable(let url):
            return "RAWデコーダを初期化できません: \(url.lastPathComponent)"
        case .renderFailed(let reason):
            return "現像に失敗しました: \(reason)"
        }
    }
}
