import CoreImage

/// 〜風フィルター1つ。画像を受け取って画像を返すだけの部品。
/// 強さ(0...1)の調整は LookStage が元画像との混合で行うので、実装は「強さ1」の結果だけ返せばよい。
public protocol Look {
    /// 安定した識別子。サイドカーに保存されるので変更しないこと。
    var id: String { get }
    var displayName: String { get }
    func apply(to image: CIImage) -> CIImage
}

/// 登録済みルックの一覧。
/// 組み込みルックは登録した順のまま先頭に、ユーザーのルック(.cubeなど)は名前順でその後に並ぶ。
public final class LookRegistry {
    /// 組み込みルック(並び順は登録順)
    public private(set) var builtIns: [Look]
    /// ユーザーのルック(常に名前順)
    public private(set) var userLooks: [Look] = []

    /// メニューに出す順の全ルック
    public var all: [Look] { builtIns + userLooks }

    public init(looks: [Look]) { self.builtIns = looks }

    /// 組み込みルック + ユーザーの .cube ファイル
    public static func makeDefault() -> LookRegistry {
        let registry = LookRegistry(looks: BuiltInLooks.all)
        registry.loadCubeFiles(from: userLooksDirectory)
        return registry
    }

    /// ~/.Rawgenzo/Looks
    /// ここに .cube を置くとルックとして読み込まれる
    public static var userLooksDirectory: URL { RawgenzoPaths.looksDirectory }

    /// ユーザーのルックを追加する。同じIDがあれば置き換える。
    public func register(_ look: Look) {
        userLooks.removeAll { $0.id == look.id }
        userLooks.append(look)
        userLooks.sort(by: Self.isOrderedBefore)
    }

    /// Finderと同じ並べ方(数字は数値として比較、大文字小文字は区別しない)。
    /// 同じ名前のときはIDで決めて、並びが毎回変わらないようにする。
    static func isOrderedBefore(_ a: Look, _ b: Look) -> Bool {
        switch a.displayName.localizedStandardCompare(b.displayName) {
        case .orderedAscending: return true
        case .orderedDescending: return false
        case .orderedSame: return a.id < b.id
        }
    }

    public func look(id: String) -> Look? {
        all.first { $0.id == id }
    }

    /// 読み込めなかったファイルはスキップし、その理由を返す
    @discardableResult
    public func loadCubeFiles(from directory: URL) -> [(URL, Error)] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        var failures: [(URL, Error)] = []
        for url in files where url.pathExtension.lowercased() == "cube" {
            do { register(try CubeFileLook(url: url)) }
            catch { failures.append((url, error)) }
        }
        return failures
    }
}
