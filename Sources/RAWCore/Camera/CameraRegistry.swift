import Foundation

/// 対応カメラの一覧。ここに登録されていないカメラのファイルは開かない。
public final class CameraRegistry {
    public private(set) var profiles: [CameraProfile]

    public init(profiles: [CameraProfile]) {
        self.profiles = profiles
    }

    /// 既定の対応機種。カメラを増やすときはここに追加する。
    public static func makeDefault() -> CameraRegistry {
        CameraRegistry(profiles: [
            SonyA7S3Profile(),
        ])
    }

    public func register(_ profile: CameraProfile) {
        profiles.append(profile)
    }

    public var supportedExtensions: Set<String> {
        profiles.reduce(into: []) { $0.formUnion($1.fileExtensions) }
    }

    public func profile(for metadata: RAWMetadata) -> CameraProfile? {
        profiles.first { $0.matches(metadata) }
    }

    public func profile(id: String) -> CameraProfile? {
        profiles.first { $0.id == id }
    }

    /// 拡張子だけで候補になりうるか(フォルダ一覧の絞り込み用)
    public func isCandidate(_ url: URL) -> Bool {
        supportedExtensions.contains(url.pathExtension.lowercased())
    }
}
