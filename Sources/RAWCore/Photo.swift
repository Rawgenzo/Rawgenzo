import Foundation

/// 開いた写真1枚: デコーダ + 判定されたカメラ + 保存済みの現像設定
public final class Photo {
    public let source: RAWSource
    public let profile: CameraProfile
    public var settings: DevelopSettings
    /// RAW に記録されたレンズ補正データ(無ければ nil)。開いた時点で読んだ固定値
    public let lensCorrection: LensCorrectionData?

    public var url: URL { source.url }
    public var metadata: RAWMetadata { source.metadata }

    /// 傾き補正前の画像の 幅/高さ
    public var imageAspect: Double {
        let s = source.nativeSize
        return s.height > 0 ? Double(s.width / s.height) : 1.5
    }

    init(source: RAWSource, profile: CameraProfile, settings: DevelopSettings,
         lensCorrection: LensCorrectionData? = nil) {
        self.source = source
        self.profile = profile
        self.settings = settings
        self.lensCorrection = lensCorrection
    }

    /// 今の設定で掛けるレンズ補正(サイドカーで指定が無ければ撮影時のカメラ設定)。補正データが無ければ nil
    public func effectiveLensSettings(_ settings: DevelopSettings) -> LensCorrectionSettings? {
        guard let lens = lensCorrection else { return nil }
        return settings.lens ?? lens.cameraSettings
    }
}

/// アプリやCLIから使う窓口。
public final class RAWEngine {
    public let registry: CameraRegistry
    public let looks: LookRegistry
    public var pipeline: DevelopPipeline
    public let sidecars: SidecarStore

    public init(registry: CameraRegistry = .makeDefault(),
                looks: LookRegistry = .makeDefault(),
                sidecars: SidecarStore = SidecarStore()) {
        self.registry = registry
        self.looks = looks
        self.pipeline = .makeDefault(looks: looks)
        self.sidecars = sidecars
    }

    /// RAWを開く。対応カメラでなければ RAWError.unsupportedCamera を投げる。
    /// サイドカーがあれば前回の設定を復元し、なければ機種の初期値を使う。
    public func open(_ url: URL) throws -> Photo {
        let metadata = try RAWMetadata.read(from: url)
        guard let profile = registry.profile(for: metadata) else {
            throw RAWError.unsupportedCamera(make: metadata.make, model: metadata.model)
        }
        let source = try profile.makeSource(url: url, metadata: metadata)
        let settings = sidecars.load(for: url)?.settings ?? profile.initialSettings(for: metadata)
        return Photo(source: source, profile: profile, settings: settings,
                     lensCorrection: profile.lensCorrection(url: url, metadata: metadata))
    }

    public func save(_ photo: Photo) throws {
        try sidecars.save(SidecarStore.Record(cameraProfileID: photo.profile.id,
                                              settings: photo.settings), for: photo.url)
    }

    /// フォルダ内の候補RAWを列挙(拡張子のみで判定、名前順)
    public func listCandidates(in directory: URL) throws -> [URL] {
        try FileManager.default
            .contentsOfDirectory(at: directory, includingPropertiesForKeys: nil,
                                 options: [.skipsHiddenFiles])
            .filter(registry.isCandidate)
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
