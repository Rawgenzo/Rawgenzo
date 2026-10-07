import SwiftUI
import AppKit
import CoreImage
import RAWCore

/// 最新の描画要求だけを処理するための世代番号(スレッドセーフ。値は NSLock で守っている)
private final class Generation: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int { lock.lock(); defer { lock.unlock() }; value += 1; return value }
    func isCurrent(_ v: Int) -> Bool { lock.lock(); defer { lock.unlock() }; return v == value }
}

/// renderQueue に渡す写真とパイプライン。
/// Photo(中の CIRAWFilter)はスレッドセーフではないので Sendable ではないが、
/// RAWSource に触るのは直列の renderQueue だけという決まりで守っているため、ここでだけ受け渡しを許す。
/// photo.settings はメインで書き換わるので、renderQueue 側では読まず、必ず settings を引数で渡すこと。
private struct RenderJob: @unchecked Sendable {
    let photo: Photo
    let pipeline: DevelopPipeline
}

@MainActor
final class EditorModel: ObservableObject {
    let engine = RAWEngine()

    @Published var folder: URL?
    @Published var files: [URL] = []
    @Published var selection: URL?
    @Published private(set) var photo: Photo?
    @Published private(set) var preview: CGImage?
    /// preview を描いたときの RenderOptions.scale(写真の等倍に対する比)
    @Published private(set) var previewRenderScale: Double = 1
    @Published private(set) var isRendering = false
    @Published var errorMessage: String?

    /// 編集中の設定。変更されると自動でプレビュー更新とサイドカー保存を行う
    @Published var settings = DevelopSettings() {
        didSet {
            guard settings != oldValue, photo != nil else { return }
            requestRender()
            scheduleSave()
        }
    }

    /// クロップ編集中は全体を表示して枠を重ねる
    @Published var isCropping = false {
        didSet {
            if isCropping && settings.crop == nil { settings.crop = .full }
            requestRender()
        }
    }

    // MARK: - 傾き補正とクロップ枠

    /// 傾き補正を始める前の枠(保存しない)。傾きを変えるたびにこの枠から合わせ直すので、
    /// 傾けてから戻すと元の大きさに戻る(縮めた結果を積み重ねると往復のたびに小さくなるため)。
    /// produced は直前に傾き補正で作った枠。今の枠がそれと違えば(枠を手で動かした・写真を切り替えた等)
    /// この記憶は使わず、今の枠を新しい基準にする。
    private var tiltBase: (url: URL, base: CropSettings, produced: CropSettings)?

    /// 傾き補正の角度を変える。枠は回転後の画像からはみ出す分だけ縮める(中心と比率は保つ)。
    func setTiltAngle(_ angle: Double) {
        guard let photo else { return }
        let base: CropSettings
        if let t = tiltBase, t.url == photo.url, t.produced == settings.crop {
            base = t.base
        } else {
            base = settings.crop ?? .full
        }
        var c = base
        c.angle = angle
        let fitted = c.fitted(imageAspect: photo.imageAspect)
        settings.crop = fitted
        tiltBase = (photo.url, base, fitted)
    }

    /// 比率を保ったまま、回転後の画像に収まる最大の大きさに広げる(位置はなるべく動かさない)
    func maximizeCrop() {
        guard let photo, let crop = settings.crop else { return }
        settings.crop = crop.maximized(imageAspect: photo.imageAspect)
    }

    // MARK: - 表示倍率

    /// 表示のしかた(ウインドウに合わせる / 決まった倍率)。写真を切り替えても保つ
    @Published var zoomMode: PreviewZoom.Mode = .fit
    /// 実際に表示している倍率(1 = 等倍)と、ウインドウに合わせたときの倍率。表示側が知らせる。0 = まだ分からない
    @Published private(set) var displayZoom: Double = 0
    @Published private(set) var fitZoom: Double = 0

    /// 拡大・縮小できる状態か(クロップ枠の調整中は「ウインドウに合わせる」に固定)
    var canZoom: Bool { photo != nil && !isCropping }

    func zoomToFit() { zoomMode = .fit }
    func zoomToActualSize() { zoomMode = .scale(1) }
    func zoomIn() { zoomMode = .scale(PreviewZoom.zoomedIn(from: displayZoom > 0 ? displayZoom : fitZoom)) }
    func zoomOut() { zoomMode = PreviewZoom.zoomedOut(from: displayZoom, fitScale: fitZoom) }

    /// 表示側から、今の倍率を知らせてもらう。必要な描画解像度が変わったら描き直す
    func reportZoom(display: Double, fit: Double) {
        if displayZoom != display { displayZoom = display }
        if fitZoom != fit { fitZoom = fit }
        if photo != nil, !isCropping, targetRenderScale != requestedRenderScale { requestRender() }
    }

    /// 写真全体を表示するときの描画解像度(長辺 previewLongEdge ピクセル)
    private var basePreviewScale: Double {
        guard let size = photo?.source.nativeSize else { return 1 }
        return Double(min(1, previewLongEdge / max(size.width, size.height, 1)))
    }

    /// 今の表示に必要な描画解像度。拡大して画面の解像度がプレビューを超えたら等倍で描く
    private var targetRenderScale: Double {
        isCropping ? basePreviewScale
                   : PreviewZoom.renderScale(zoom: displayZoom, previewScale: basePreviewScale)
    }

    /// 最後に描画を頼んだ解像度
    private var requestedRenderScale: Double = 0

    /// プレビューの長辺ピクセル数(写真全体を表示するとき。大きいほど精細・遅い)
    private let previewLongEdge: CGFloat = 2400
    private let renderQueue = DispatchQueue(label: "Rawgenzo.render", qos: .userInitiated)
    private let ciContext = CIContext(options: [.cacheIntermediates: true])
    private let generation = Generation()
    private var saveTask: Task<Void, Never>?

    // MARK: - フォルダとファイル

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "開く"
        panel.message = "RAWファイルのあるフォルダを選んでください"
        if let folder { panel.directoryURL = folder }
        if panel.runModal() == .OK, let url = panel.url {
            load(folder: url)
        }
    }

    init() {
        // 前回開いていたフォルダを開き直す
        if let path = AppConfigStore.shared.config.lastFolder {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
                load(folder: URL(fileURLWithPath: path, isDirectory: true))
            }
        }
    }

    func load(folder url: URL) {
        do {
            files = try engine.listCandidates(in: url)
            folder = url
            AppConfigStore.shared.config.lastFolder = url.path
            selection = files.first
            open(selection)   // 起動直後は onChange が呼ばれないので直接開く
        } catch {
            errorMessage = "フォルダを読めません: \(error.localizedDescription)"
        }
    }

    func open(_ url: URL?) {
        if let url, photo?.url == url { return }   // 同じ写真を開き直さない
        flushSave()
        guard let url else { photo = nil; preview = nil; return }
        do {
            let p = try engine.open(url)
            isCropping = false
            photo = p
            settings = p.settings
            requestRender()
        } catch {
            photo = nil
            preview = nil
            errorMessage = "\(error)"
        }
    }

    // MARK: - 描画

    func requestRender() {
        guard let photo else { return }
        let gen = generation.next()
        let scale = targetRenderScale
        requestedRenderScale = scale
        let options = RenderOptions(scale: scale, draft: false,
                                    cropMode: isCropping ? .rotateOnly : .apply)
        let settings = self.settings
        let job = RenderJob(photo: photo, pipeline: engine.pipeline)
        let context = ciContext
        let generation = self.generation
        isRendering = true

        renderQueue.async { [weak self] in
            // 描画待ちの間に新しい要求が来ていたら、この要求は捨てる
            guard generation.isCurrent(gen) else { return }
            var result: Result<CGImage, Error>
            do {
                let image = try job.pipeline.process(job.photo, settings: settings, options: options)
                let cs = CGColorSpace(name: CGColorSpace.displayP3)!
                guard let cg = context.createCGImage(image, from: image.extent,
                                                     format: .RGBA8, colorSpace: cs) else {
                    throw RAWError.renderFailed("プレビュー画像を作れません")
                }
                result = .success(cg)
            } catch {
                result = .failure(error)
            }
            Task { @MainActor [weak self] in
                guard let self, generation.isCurrent(gen) else { return }
                self.isRendering = false
                switch result {
                case .success(let cg):
                    self.previewRenderScale = scale
                    self.preview = cg
                case .failure(let error): self.errorMessage = "\(error)"
                }
            }
        }
    }

    // MARK: - 保存

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            self?.flushSave()
        }
    }

    func flushSave() {
        saveTask?.cancel()
        guard let photo, photo.settings != settings else { return }
        photo.settings = settings
        do { try engine.save(photo) }
        catch { errorMessage = "設定を保存できません: \(error.localizedDescription)" }
    }

    func resetAll() {
        guard let photo else { return }
        settings = photo.profile.initialSettings(for: photo.metadata)
    }

    // MARK: - 書き出し

    /// 直前に書き出したファイル(プレビュー下部に知らせを出す)
    @Published private(set) var lastExported: URL?
    @Published private(set) var isExporting = false

    /// 設定に従って書き出す。
    /// - forceDialog: 設定に関わらず保存ダイアログを出す(⇧⌘E)
    func exportCurrent(forceDialog: Bool = false) {
        guard let photo, !isExporting else { return }
        flushSave()

        let prefs = AppConfigStore.shared.config.export
        let template = prefs.template
        if let error = template.validate() {
            errorMessage = "ファイル名テンプレートに誤りがあります: \(error)\n設定の「書き出し」で直してください。"
            return
        }

        let settings = self.settings
        let format: Exporter.Format = settings.hdr.extendedOutput ? .heifHDR : prefs.exportFormat
        let lookName = settings.look.flatMap { engine.looks.look(id: $0.id)?.displayName }
        let sequence = prefs.nextSequence
        let job = RenderJob(photo: photo, pipeline: engine.pipeline)
        isExporting = true

        // 画像の組み立て(デコーダはプレビューと同じキューでしか触らない)
        renderQueue.async { [weak self] in
            let photo = job.photo
            do {
                let image = try job.pipeline.process(photo, settings: settings, options: RenderOptions())
                let context = FileNameTemplate.Context(
                    sourceURL: photo.url, metadata: photo.metadata, exportDate: Date(),
                    sequence: sequence, lookName: lookName, outputSize: image.extent.size)
                let baseName = try template.render(context)
                Task { @MainActor [weak self] in
                    self?.chooseDestinationAndWrite(photo: photo, image: image, baseName: baseName,
                                                    format: format, prefs: prefs, sequence: sequence,
                                                    forceDialog: forceDialog)
                }
            } catch {
                let message = "書き出しに失敗しました: \(error)"
                Task { @MainActor [weak self] in
                    self?.isExporting = false
                    self?.errorMessage = message
                }
            }
        }
    }

    private func chooseDestinationAndWrite(photo: Photo, image: CIImage, baseName: String,
                                           format: Exporter.Format, prefs: ExportPreferences,
                                           sequence: Int, forceDialog: Bool) {
        let directory = prefs.directory(for: photo.url)
        let destination: URL

        if prefs.showDialog || forceDialog {
            let panel = NSSavePanel()
            panel.canCreateDirectories = true
            panel.nameFieldStringValue = baseName + "." + format.fileExtension
            // まだ無いサブフォルダは作らず、一番近い既存のフォルダを開く
            var dir = directory
            while !FileManager.default.fileExists(atPath: dir.path), dir.pathComponents.count > 1 {
                dir = dir.deletingLastPathComponent()
            }
            panel.directoryURL = dir
            panel.message = format == .heifHDR
                ? "HDR出力がオンなので10bit HEIF (HLG) で書き出します"
                : "\(format.fileExtension.uppercased()) で書き出します"
            guard panel.runModal() == .OK, let url = panel.url else {
                isExporting = false
                return
            }
            destination = url
        } else {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            } catch {
                isExporting = false
                errorMessage = "書き出し先のフォルダを作れません: \(directory.path)\n\(error.localizedDescription)"
                return
            }
            destination = ExportPreferences.resolve(directory: directory, baseName: baseName,
                                                    fileExtension: format.fileExtension,
                                                    policy: prefs.conflictPolicy)
        }

        // 保存先と連番を記憶(config.json に保存される)
        let store = AppConfigStore.shared
        store.config.export.lastDirectory = destination.deletingLastPathComponent().path
        if prefs.template.usesSequence {
            store.config.export.nextSequence = sequence + 1
        }

        let colorSpace = prefs.outputColorSpace
        let quality = prefs.quality
        renderQueue.async { [weak self] in
            do {
                try Exporter().write(image, to: destination, format: format,
                                     colorSpace: colorSpace, quality: quality)
                Task { @MainActor [weak self] in
                    self?.isExporting = false
                    self?.lastExported = destination
                }
            } catch {
                let message = "書き出しに失敗しました: \(error)"
                Task { @MainActor [weak self] in
                    self?.isExporting = false
                    self?.errorMessage = message
                }
            }
        }
    }

    func dismissExportNotice() { lastExported = nil }
}
