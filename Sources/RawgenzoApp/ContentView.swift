import SwiftUI
import AppKit
import RAWCore

struct ContentView: View {
    @EnvironmentObject private var model: EditorModel
    @EnvironmentObject private var prefs: AppConfigStore

    var body: some View {
        NavigationSplitView {
            FileListView()
                .navigationSplitViewColumnWidth(min: 180, ideal: 220)
        } detail: {
            HStack(spacing: 0) {
                PreviewView()
                Divider()
                InspectorView()
                    .frame(width: 300)
            }
        }
        .toolbar {
            ToolbarItemGroup {
                ZoomToolbarMenu()
                Menu {
                    GuideMenuItems(display: $prefs.config.guides)
                } label: {
                    Label("構図ガイド", systemImage: prefs.config.guides.isVisible
                          ? "squareshape.split.3x3" : "square.dashed")
                }
                .help("構図ガイド (⌥⌘G で表示/非表示)")
                Button { model.chooseFolder() } label: {
                    Label("フォルダを開く", systemImage: "folder")
                }
                Button { model.exportCurrent() } label: {
                    Label("書き出し", systemImage: "square.and.arrow.up")
                }
                .disabled(model.photo == nil)
            }
        }
        .onChange(of: model.selection) { url in
            model.open(url)
        }
        .alert("エラー", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

struct FileListView: View {
    @EnvironmentObject private var model: EditorModel
    @EnvironmentObject private var prefs: AppConfigStore

    var body: some View {
        if model.folder == nil {
            VStack(spacing: 12) {
                Text("RAWファイルのあるフォルダを開いてください")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                Button("フォルダを開く…") { model.chooseFolder() }
            }
            .padding()
        } else if model.files.isEmpty {
            Text("このフォルダに対応するRAWファイルがありません")
                .foregroundStyle(.secondary)
                .padding()
        } else {
            List(model.files, id: \.self, selection: $model.selection) { url in
                FileRow(url: url, thumbnailSize: prefs.config.thumbnails.show ? prefs.config.thumbnails.size : nil)
            }
        }
    }
}

struct FileRow: View {
    let url: URL
    /// nil = サムネイル非表示
    let thumbnailSize: ThumbnailSize?

    var body: some View {
        if let size = thumbnailSize {
            if size == .large {
                // 大: 画像を上、ファイル名を下に
                VStack(alignment: .leading, spacing: 4) {
                    ThumbnailView(url: url, side: size.points)
                    name
                }
                .padding(.vertical, 4)
            } else {
                HStack(spacing: 10) {
                    ThumbnailView(url: url, side: size.points)
                    name
                }
                .padding(.vertical, 2)
            }
        } else {
            name
        }
    }

    private var name: some View {
        Text(url.lastPathComponent)
            .lineLimit(1)
            .truncationMode(.middle)
    }
}

struct ThumbnailView: View {
    let url: URL
    /// 枠の長辺(ポイント)
    let side: CGFloat

    @Environment(\.displayScale) private var displayScale
    @State private var image: CGImage?

    private var maxPixel: Int { Int(side * max(displayScale, 1)) }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 3)
                .fill(Color.secondary.opacity(0.15))
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.medium)
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            }
        }
        // 3:2 の枠。縦位置の写真は枠の中に収まる
        .frame(width: side, height: side * 2 / 3)
        .task(id: "\(url.path)#\(maxPixel)") {
            image = ThumbnailCache.shared.cached(url, maxPixel: maxPixel)
            if image == nil {
                image = await ThumbnailCache.shared.thumbnail(for: url, maxPixel: maxPixel)
            }
        }
    }
}

struct PreviewView: View {
    @EnvironmentObject private var model: EditorModel
    @EnvironmentObject private var prefs: AppConfigStore
    private var guides: GuideDisplay { prefs.config.guides }
    /// 拡大表示中の写真の位置(構図ガイドを重ねるため)
    @State private var imageFrame: CGRect?

    var body: some View {
        ZStack {
            Color(nsColor: .underPageBackgroundColor)
            if let cg = model.preview {
                if model.isCropping, let photo = model.photo {
                    // クロップ枠の調整中は「ウインドウに合わせる」に固定(枠の操作は全体表示が前提)
                    Image(decorative: cg, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .overlay {
                            // クロップ中はガイドを枠の中に描く
                            CropOverlay(crop: Binding(
                                get: { model.settings.crop ?? .full },
                                set: { model.settings.crop = $0 }),
                                imageAspect: photo.imageAspect,
                                guides: guides)
                        }
                        .padding(24)
                } else {
                    ZoomableImageView(
                        image: cg,
                        imagePixels: CGSize(width: Double(cg.width) / model.previewRenderScale,
                                            height: Double(cg.height) / model.previewRenderScale),
                        mode: $model.zoomMode,
                        onZoom: { model.reportZoom(display: $0, fit: $1) },
                        onImageFrame: { imageFrame = $0 })
                    .overlay {
                        if guides.hasAnythingToDraw, let f = imageFrame, f.height > 0 {
                            GuideOverlay(display: guides, aspect: f.width / f.height, imageFrame: f)
                        }
                    }
                    .clipped()
                }
            } else if model.photo == nil {
                Text("左の一覧から写真を選んでください")
                    .foregroundStyle(.secondary)
            }
            if model.isRendering {
                VStack {
                    HStack {
                        Spacer()
                        ProgressView().controlSize(.small).padding(10)
                    }
                    Spacer()
                }
                .allowsHitTesting(false)
            }
            ExportNotice()
        }
    }
}

/// 書き出し中・書き出し完了の知らせ(プレビュー下部)
struct ExportNotice: View {
    @EnvironmentObject private var model: EditorModel

    var body: some View {
        VStack {
            Spacer()
            if model.isExporting {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("書き出し中…")
                }
                .modifier(NoticeStyle())
            } else if let url = model.lastExported {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("書き出しました: \(url.lastPathComponent)")
                        .lineLimit(1).truncationMode(.middle)
                    Button("Finderで表示") {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                    Button { model.dismissExportNotice() } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.borderless)
                    .help("閉じる")
                }
                .modifier(NoticeStyle())
                .task(id: url) {
                    try? await Task.sleep(nanoseconds: 6_000_000_000)
                    if model.lastExported == url { model.dismissExportNotice() }
                }
            }
        }
        .animation(.easeOut(duration: 0.2), value: model.lastExported)
        .animation(.easeOut(duration: 0.2), value: model.isExporting)
    }
}

private struct NoticeStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.callout)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())
            .shadow(radius: 4, y: 1)
            .padding(.bottom, 16)
            .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

/// ツールバーの倍率表示。押すと倍率を選べる(ショートカットはメニューバー側だけに付ける)
struct ZoomToolbarMenu: View {
    @EnvironmentObject private var model: EditorModel

    var body: some View {
        Menu {
            Button("ウインドウに合わせる") { model.zoomToFit() }
            Divider()
            ForEach(PreviewZoom.steps, id: \.self) { z in
                Button(PreviewZoom.percentText(z)) { model.zoomMode = .scale(z) }
            }
        } label: {
            Text(model.displayZoom > 0 ? PreviewZoom.percentText(model.displayZoom) : "—")
                .monospacedDigit()
                .frame(minWidth: 44)
        }
        .disabled(!model.canZoom)
        .help("表示倍率 (⌘9 ウインドウに合わせる、⌘0 実際のサイズ、⌘+ / ⌘− 拡大・縮小)")
    }
}
