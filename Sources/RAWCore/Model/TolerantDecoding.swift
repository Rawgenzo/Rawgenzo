import Foundation

/// 設定ファイルを寛容に読む。項目が無い・形が違うときは既定値にして、ほかの項目は読み続ける。
/// 合成された Codable は項目が 1 つ欠けるだけで全体の読み込みに失敗し、写真の設定や環境設定がまるごと消える
extension KeyedDecodingContainer {
    public func tolerant<T: Decodable>(_ key: Key, as type: T.Type = T.self) -> T? {
        (try? decodeIfPresent(type, forKey: key)) ?? nil
    }

    public func tolerant<T: Decodable>(_ key: Key, as type: T.Type = T.self, default value: T) -> T {
        tolerant(key, as: type) ?? value
    }
}
