import Foundation
import ImageIO

/// RAWに埋め込まれたプレビュー画像からサムネイルを作ってキャッシュする。
/// RAWを現像しないので高速(1枚あたり数ミリ秒〜十数ミリ秒程度)。
final class ThumbnailCache {
    static let shared = ThumbnailCache()

    private let cache = NSCache<NSString, CGImage>()
    /// 同時に読み込む枚数を制限して、スクロール時にディスクI/Oが詰まらないようにする
    private let queue = OperationQueue()

    private init() {
        cache.countLimit = 1000
        queue.maxConcurrentOperationCount = 4
        queue.qualityOfService = .utility
    }

    private func key(_ url: URL, _ maxPixel: Int) -> NSString {
        "\(url.path)#\(maxPixel)" as NSString
    }

    func cached(_ url: URL, maxPixel: Int) -> CGImage? {
        cache.object(forKey: key(url, maxPixel))
    }

    func thumbnail(for url: URL, maxPixel: Int) async -> CGImage? {
        if let hit = cached(url, maxPixel: maxPixel) { return hit }
        let image: CGImage? = await withCheckedContinuation { continuation in
            queue.addOperation {
                continuation.resume(returning: Self.make(url: url, maxPixel: maxPixel))
            }
        }
        if let image { cache.setObject(image, forKey: key(url, maxPixel)) }
        return image
    }

    private static func make(url: URL, maxPixel: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            // 埋め込みプレビューがあればそれを使い、無いときだけRAWから作る
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            // 縦位置の写真を正しい向きにする
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
