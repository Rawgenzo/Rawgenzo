import Foundation
import RAWCore

/// AI に操作させるときの作業場所: 1 つのフォルダと、その中の写真。
/// 写真はフォルダの中のファイル名(ID)で指す。フォルダの外のファイルには触らない。
///
/// スレッドについての約束: Surface と同じく 1 つのスレッドからだけ使う(Photo の中の CIRAWFilter はスレッドセーフでないため)
public final class RawgenzoWorkspace {
    public enum WorkspaceError: Error, CustomStringConvertible {
        case invalidID(String)
        case notFound(String)

        public var description: String {
            switch self {
            case .invalidID(let id): return "写真の ID が正しくありません: \(id)(list_photos が返すファイル名を使ってください)"
            case .notFound(let id): return "写真が見つかりません: \(id)"
            }
        }
    }

    public let folder: URL
    public let engine: RAWEngine

    /// 開いた写真を少しだけ覚えておく(ARW を開くのは 1 枚 0.1 秒以上かかるため)
    private var cache: [URL: Photo] = [:]
    private var cacheOrder: [URL] = []
    private let cacheLimit = 8
    private var metadataCache: [URL: RAWMetadata] = [:]

    public init(folder: URL, engine: RAWEngine = RAWEngine()) {
        self.folder = folder.standardizedFileURL
        self.engine = engine
    }

    /// フォルダ内の写真の ID(ファイル名)。名前順
    public func photoIDs() throws -> [String] {
        try engine.listCandidates(in: folder).map(\.lastPathComponent)
    }

    /// ID → ファイルの場所。フォルダの外を指す ID(/ や .. を含むもの)は受け付けない
    public func url(for id: String) throws -> URL {
        guard !id.isEmpty, !id.contains("/"), !id.contains("\\"), id != ".", id != "..", !id.hasPrefix(".") else {
            throw WorkspaceError.invalidID(id)
        }
        let url = folder.appendingPathComponent(id)
        guard engine.registry.isCandidate(url) else { throw WorkspaceError.invalidID(id) }
        guard FileManager.default.fileExists(atPath: url.path) else { throw WorkspaceError.notFound(id) }
        return url
    }

    public func metadata(_ id: String) throws -> RAWMetadata {
        let url = try url(for: id)
        if let m = metadataCache[url] { return m }
        let m = try RAWMetadata.read(from: url)
        metadataCache[url] = m
        return m
    }

    /// 写真を開く。設定は毎回サイドカーから読み直す(アプリや CLI が書き換えているかもしれないため)
    public func photo(_ id: String) throws -> Photo {
        let url = try url(for: id)
        let photo: Photo
        if let cached = cache[url] {
            photo = cached
            cacheOrder.removeAll { $0 == url }
        } else {
            photo = try engine.open(url)
            cache[url] = photo
        }
        cacheOrder.append(url)
        if cacheOrder.count > cacheLimit {
            cache[cacheOrder.removeFirst()] = nil
        }
        photo.settings = engine.sidecars.load(for: url)?.settings ?? photo.profile.initialSettings(for: photo.metadata)
        return photo
    }

    public func hasSidecar(_ id: String) -> Bool {
        guard let url = try? url(for: id) else { return false }
        return FileManager.default.fileExists(atPath: engine.sidecars.sidecarURL(for: url).path)
    }

    /// 設定をサイドカーに保存する
    public func save(_ photo: Photo, settings: DevelopSettings) throws {
        photo.settings = settings
        try engine.save(photo)
    }

    /// サイドカーを消す(サイドカーが無かった写真への変更を取り消すとき。元の「未編集」の状態に戻す)
    public func removeSidecar(_ photo: Photo) throws {
        let url = engine.sidecars.sidecarURL(for: photo.url)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        photo.settings = photo.profile.initialSettings(for: photo.metadata)
    }
}
