import Foundation
import RAWCore
import OperationSurface
import RawgenzoSurface

/// AI の操作の、画面に出す知らせ
struct AgentActivity: Equatable {
    var message: String
    var date: Date
}

/// 操作面のキュー(メインではない)から呼ばれる、編集中の写真への口。
/// EditorModel はメインアクターなので、ここでメインスレッドに移ってから触る。
/// メインスレッドは操作面のキューを待たない(人の変更の記録は queue.async で渡す)ので、main.sync でも行き詰まらない
final class AgentLiveLink: LiveEditing {
    weak var model: EditorModel?

    func liveSettings(for url: URL) -> DevelopSettings? {
        onMain { $0.liveSettingsForAgent(url) }
    }

    func applyLive(_ settings: DevelopSettings, for url: URL, origin: ChangeOrigin?) -> Bool {
        onMain { $0.applyAgentSettings(settings, for: url, origin: origin) } ?? false
    }

    private func onMain<T>(_ body: @MainActor (EditorModel) -> T?) -> T? {
        if Thread.isMainThread {
            return MainActor.assumeIsolated { model.flatMap { body($0) } }
        }
        return DispatchQueue.main.sync {
            MainActor.assumeIsolated { model.flatMap { body($0) } }
        }
    }
}
