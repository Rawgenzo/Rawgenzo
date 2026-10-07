import Foundation

/// 現像設定を RAWの隣に `<ファイル名>.rawgenzo.json` として保存する(非破壊編集)。
/// Dropbox上に置いてもRAWと一緒に同期される。
public struct SidecarStore {
    public struct Record: Codable, Equatable {
        public var cameraProfileID: String
        public var settings: DevelopSettings
    }

    public init() {}

    public func sidecarURL(for raw: URL) -> URL {
        raw.appendingPathExtension("rawgenzo.json")
    }

    public func load(for raw: URL) -> Record? {
        guard let data = try? Data(contentsOf: sidecarURL(for: raw)) else { return nil }
        return try? JSONDecoder().decode(Record.self, from: data)
    }

    public func save(_ record: Record, for raw: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(record).write(to: sidecarURL(for: raw), options: .atomic)
    }
}
