import Foundation
import Metal

/// 実行時にコンパイルした Metal の計算カーネルを、GPU ごとに使い回す。
/// Core Image の組み込みフィルターでできない処理(レンズ補正・コントラスト)を CIImageProcessorKernel で組み込むのに使う。
/// 実行時にコンパイルするのは、SwiftPM のコマンドラインビルドでは Core Image 用の Metal ライブラリを作れないため。
enum MetalKernels {
    private static let cache = LockedCache<String, MTLComputePipelineState>()

    /// - name: カーネル関数の名前。source の中で一意であること
    static func pipeline(name: String, source: String, device: MTLDevice) throws -> MTLComputePipelineState {
        let key = "\(name)#\(device.registryID)"
        if let p = cache.value(for: key) { return p }
        do {
            let library = try device.makeLibrary(source: source, options: nil)
            guard let function = library.makeFunction(name: name) else {
                throw RAWError.renderFailed("GPU のカーネル \(name) が見つかりません")
            }
            let p = try device.makeComputePipelineState(function: function)
            cache.set(p, for: key)
            return p
        } catch let e as RAWError {
            throw e
        } catch {
            throw RAWError.renderFailed("GPU のカーネル \(name) を準備できません: \(error.localizedDescription)")
        }
    }

    /// 出力テクスチャ全体に 16×16 ずつスレッドを割り当てて実行する
    static func dispatch(_ encoder: MTLComputeCommandEncoder, over texture: MTLTexture) {
        let group = MTLSize(width: 16, height: 16, depth: 1)
        let groups = MTLSize(width: (texture.width + 15) / 16, height: (texture.height + 15) / 16, depth: 1)
        encoder.dispatchThreadgroups(groups, threadsPerThreadgroup: group)
    }
}

/// 複数のスレッドから使える小さなキャッシュ
final class LockedCache<Key: Hashable, Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Key: Value] = [:]

    func value(for key: Key) -> Value? {
        lock.lock(); defer { lock.unlock() }
        return storage[key]
    }

    func set(_ value: Value, for key: Key) {
        lock.lock(); defer { lock.unlock() }
        storage[key] = value
    }

    func value(for key: Key, make: () -> Value) -> Value {
        if let v = value(for: key) { return v }
        let v = make()
        set(v, for: key)
        return v
    }
}
