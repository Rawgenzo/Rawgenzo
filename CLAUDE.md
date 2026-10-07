# CLAUDE.md — Rawgenzo 引継書

Apple Silicon ネイティブの個人用 RAW 現像ソフト。SILKYPIX が Apple Silicon にネイティブ対応しないため自作した。
対象カメラは当面 **SONY α7S III (ILCE-7SM3) の ARW のみ**。ただし機種を後から増やせる設計にしてある。

2026-10-07 に RAWprocessor から改名し、**Rawgenzo** として公開した(MIT License)。
ソースは https://github.com/Rawgenzo/Rawgenzo 、公式ページは https://rawgenzo.github.io
(ローカルでは `../Rawgenzo.github.io` に並べて置いている)。README.md は利用者向けの公開文書として書くこと。

これまでの開発は claude.ai 上の Claude が行った。その環境では macOS のフレームワークが無く **一度もビルドできなかった**ため、
動作確認はすべてオーナーが手元の Mac で行ってきた。Claude Code ではビルドとテストを自分で回せるので、必ずそうすること。

## オーナーとのやり取り

- 会話・コメント・UI 文言・コミットメッセージは **日本語**
- オーナーはこのプロジェクトを Anthropic の AI の実力を測る個人的なベンチマークとしても見ている。
  できないこと・確認していないことは正直に伝え、推測で「動きます」と言わない
- 不具合の原因が自分の過去の設計判断にあるときは、そう説明してから直す
- 大きな方針変更(依存ライブラリの追加、保存形式の変更、対応カメラの拡大など)は事前に相談する

## よく使うコマンド

```sh
swift build                                  # デバッグビルド
swift test                                   # ユニットテスト
RAW_SAMPLE_DIR=RAWsample swift test          # 実サンプルを使うテストも含める
swift run RawgenzoApp                        # アプリを起動(開発用)
./scripts/make-app.sh --install              # リリースビルド → .app 化 → /Applications に入れる

swift run rawdev check                       # Core Image が α7S III に対応しているか
swift run rawdev info RAWsample              # メタデータ・カメラ判定・デコーダの対応状況
swift run rawdev develop RAWsample --hdr 0.5 --look builtin.film
swift run rawdev name "{date}_{seq:3}" RAWsample   # ファイル名テンプレートの確認(書き出さない)
swift run rawdev config                      # 設定ファイルの書き出し設定を表示
swift run rawdev looks                       # ルック一覧
```

- サンプル RAW は `RAWsample/`(α7S III の ARW)。`.gitignore` 済みなのでコミットしない
- 要件: macOS 13 以降、Swift 6.4 (Xcode 27 以降)。外部依存パッケージは無し。古い環境は意識しない(オーナーの決定)
- **変更したら `swift build` と `swift test` を通してから報告する。** UI の変更はビルドが通っても見た目を確認できないので、
  オーナーに確認してほしい点を具体的に伝える

## 構成

```
Package.swift
Sources/RAWCore/            現像エンジン。UI 非依存(SwiftUI を import しない)
  Camera/                   CameraProfile(機種定義)、CameraRegistry、Sony/SonyA7S3Profile、Sony/SonyLensCorrection
  Decode/                   RAWSource(デコーダの抽象)、CoreImageRAWSource(CIRAWFilter)
  Pipeline/                 DevelopStage、DevelopPipeline、Stages(HDRトーン・色・クロップ・ルック)、
                            ContrastStage(自前のトーンカーブ)、MetalKernels(実行時にコンパイルする GPU のカーネル)
  Lens/                     レンズ補正: LensCorrection(補正データと換算)、LensCorrector(Metal のカーネル)、TIFFReader
  Look/                     Look、LookRegistry、BuiltInLooks、ColorCubeLook、CubeFileLook(.cube)
  Composition/              構図ガイドの幾何計算(CompositionGuide)
  Config/                   RawgenzoPaths、ExportPreferences、FileNameTemplate、SharedConfig
  Model/                    DevelopSettings(現像パラメータ)、CropFitting(枠を回転後の画像に収める計算)、
                            PreviewZoom(表示倍率の計算)、RAWMetadata、RAWError
  Sidecar/                  SidecarStore(<RAW名>.rawgenzo.json)
  Export/                   Exporter(JPEG / HEIF / 16bit TIFF / HDR HEIF)
  Photo.swift               Photo と RAWEngine(アプリ・CLI の窓口)
Sources/RawgenzoApp/        SwiftUI アプリ
  RawgenzoApp.swift         App、メニュー、AppDelegate
  EditorModel.swift         編集状態・プレビュー描画・書き出しの流れ
  AppConfig.swift           AppConfig と AppConfigStore(~/.Rawgenzo/config.json)
  ContentView.swift         ファイル一覧(サムネイル)・プレビュー・書き出し通知
  InspectorView.swift       右側の調整パネル、AdjustSlider
  CropOverlay.swift         クロップ枠のドラッグ操作
  ZoomableImageView.swift   拡大・縮小できるプレビュー(NSScrollView を NSViewRepresentable で包む)
  CompositionGuideUI.swift  ガイドの表示設定・描画・メニュー
  ExportSettingsView.swift  設定の「書き出し」タブ(テンプレート編集)
  Preferences.swift         設定ウインドウ(一般タブ)、ThumbnailSize
  ThumbnailCache.swift      埋め込みプレビューからのサムネイル
Sources/rawdev/main.swift   CLI
Tests/RAWCoreTests/         RAWCore のテスト(1ファイル)
scripts/make-app.sh         .app 化・アドホック署名・インストール
scripts/make_icon.py        アイコン生成(Pillow + numpy)
Resources/AppIcon.png       アプリアイコン(1024px)
```

### 処理の流れ

```
ARW → CameraRegistry が機種判定 → CameraProfile.makeSource → RAWSource.render
      (露出・WB・NR・シャープネス・EDR はデコーダ段。CIRAWFilter のレンズ補正は ARW 非対応なので切ってある)
    → レンズ補正(LensCorrector。Photo.lensCorrection が要るのでステージではなく DevelopPipeline.process で直接)
    → DevelopPipeline: phase 順にステージを適用
      tone(HDRToneStage → ContrastStage) → color(ColorStage) → camera(機種固有) → geometry(CropStage) → look(LookStage)
    → Exporter
```

クロップをルックより前に置いているのは、周辺減光などのルックを切り抜き後の枠に合わせるため。順序を変えないこと。

### 保存されるもの

| 場所 | 内容 | 書く側 |
|---|---|---|
| `<RAW>.rawgenzo.json` | その写真の現像設定(DevelopSettings) | アプリ(自動保存)、CLI(`--save` 時) |
| `~/.Rawgenzo/config.json` | アプリ設定(AppConfig) | アプリのみ |
| `~/.Rawgenzo/Looks/*.cube` | ユーザーのルック | オーナーが手で置く |

- `config.json` の `"export"` は CLI も `SharedConfig` で**読む**(書かない)

## 守るべき決まり

### 互換性

- サイドカーと config.json は**古いファイルも新しいファイルも読めること**。Codable は `init(from:)` を手書きし、
  全項目 `decodeIfPresent` で既定値に落とす。列挙型の未知の値も `try?` で既定値に戻す。この方針を崩さない
- 次の ID は保存ファイルに書かれるので**変更しない**: `CameraProfile.id`(例 `sony.ilce-7sm3`)、
  `Look.id`(`builtin.film` など、`.cube` は `cube:<ファイル名>`)、構図ガイドの `id`(`halves` `thirds` `golden`
  `silver` `spiral` `diagonal` `triangle`)、調整パネルのセクションの `InspectorSectionID`(`basic` `lens` `hdr` `color`
  `detail` `crop` `look`。config.json の `inspector.collapsed` に折りたたみ状態として保存される)
- 保存形式を変えるときは `schemaVersion` を上げ、古い形式の読み込みテストを足す

### 並行処理

- `CIRAWFilter` はスレッドセーフではない。**RAWSource に触るのは EditorModel の `renderQueue`(直列)だけ**。
  書き出しも同じキューで画像を組み立てている
- プレビューは世代番号(`Generation`)で最新の要求だけを描く。キューに溜まった古い要求は捨てる
- UI 状態の更新は `Task { @MainActor in ... }` で戻す
- RAWSource の `url` `metadata` `asShot` `nativeSize` は開いた時点で決まる変わらない値にする(UI が描画中に読むため)。
  `nativeSize` を CIRAWFilter に毎回問い合わせる実装にしていたら、露出・色温度・色かぶりのドラッグ中に
  「CIRAWFilterの出力が空です」が頻発した(再現試験で 300 回中 171 回失敗)
- `swift-tools-version: 5.9` のまま(言語モードは Swift 5 で、厳格な並行性チェックは無効)。要件は Swift 6.4 だが、
  tools-version を 6 以上に上げると言語モードが Swift 6 になり厳格なチェックが有効になるので、上げるのは Swift 6 モードへの
  移行(未着手)と一緒に行う

### はまりどころ(過去に実際に起きたもの・起きかけたもの)

- **CIRAWFilter の `localToneMapAmount` は ARW では効かない**(`isLocalToneMapSupported` が false)。
  最初はこれに HDR を任せていて「HDR の強さが効かない」不具合になった。現在は HDRToneStage で自前実装し、
  デコーダ側は常に 0。`rawdev info` の「デコーダ対応」で機能ごとの対応を確認できる。
  デコーダの機能に頼る前に、対象機種で `isXxxSupported` を確認すること
- **CIRAWFilter の `contrastAmount` は ARW では効かない。しかも `isContrastSupported` は true を返す**
  (2026-10-07、macOS 27.0.1 で確認)。−1〜2 のどの値でも出力がまったく同じで、デコーダ内部のトーンカーブ
  (`boost_v7` の係数)も変わらない。デコーダの contrastAmount は常に既定値のまま渡している。
  コントラストは自前のトーンカーブ(`ContrastStage`)にし、`DevelopSettings.contrast` を −1.2...1.2(オーナーの希望で ±1 から 2 割広げた)として使い直した
  (schemaVersion 3)。`boostAmount`(基本トーンカーブの強さ。既定 1)は効く。
  **`isXxxSupported` が true でも効くとは限らない**ので、デコーダの機能は実際に値を変えて出力を比べてから使うこと
- **CIRAWFilter のシャープネスは等倍で描くときだけ効く**(scaleFactor 0.5 では 0〜3 のどれでも出力が同じ)。
  プレビューは長辺 2400(約 0.57 倍)で描くので、拡大表示で等倍描画に切り替わるまで効果が見えない(UI に注記)。
  ノイズ除去は縮小しても効く。**輝度ノイズ除去は ISO に応じた既定値をデコーダが持つ**(ISO 100 以下 0、8000 で 0.302、
  12800 で 0.605)。低感度ではノイズが無く効果が見えない。**1 を超えると効き方が逆になる**(細部が戻り、3 では補正なしより
  粗い)ので `DetailRanges` で 0...1 に制限。以前 SonyA7S3Profile.initialSettings が ISO 3200 以上に独自の初期値を
  入れていたが、デコーダの値と二重になり ↶ の戻り先とずれるのでやめた。範囲はオーナーの希望で広げてある
  (シャープネス 0...6、色ノイズ除去 0...2)
- **CIRAWFilter のレンズ補正も ARW では効かない**(`isLensCorrectionSupported` が false)。
  ARW に記録された補正値で自前で補正している(`Lens/`、調査メモ: `docs/sony-lens-correction.md`)。
  換算の式は darktable のもの(GPL なのでコードは写さず式だけ)。歪曲は lensfun と照合済み、周辺減光の強さは未検証
  (ARW の埋め込みプレビューはカメラの補正が掛かっていないので、比較に使えない)
- **`DevelopSettings.lens` は Optional**。nil = 撮影時のカメラ設定に従う(オーナーの決定。旧サイドカーも同じ扱い)。
  「全部切る」を `.none` と名付けたら `s.lens = .none` が nil(カメラ設定)になる取り違えが起きたので `.off` にした
- **Metal のカーネル(CIImageProcessorKernel)に渡るテクスチャは 1 行目が上端**(Core Image の座標で y が大きい側)。
  カーネルの式は CPU の計算と GPU の結果を比べるテストで確かめてある(向きを逆にすると失敗する)。
  カーネルは実行時にコンパイルする(SwiftPM のコマンドラインビルドでは Core Image 用の metallib を作れない)
- **Codable と RawRepresentable(String) を両方持つ型**(GuideDisplay)は、標準実装が rawValue 経由になり無限再帰する。
  Codable を明示的に実装してある
- **キーボードショートカットはメニューバー側だけ**に付ける。ツールバーのメニューにも付けると二重登録になり、
  トグルが打ち消し合う恐れがある(`GuideMenuItems(withShortcuts:)`)
- **座標系**: クロップ・ガイドの正規化座標は左上原点(0...1)。Core Image は左下原点なので変換は
  `CropStage.pixelRect` に集約してある
- **傾き補正と枠**: 枠は常に回転後の画像の内側に収める(オーナーの決定。オン/オフは付けない)。
  計算は `CropFitting.swift`(ピクセル比の座標で行う)。傾きを変えたときは「はみ出す分だけ縮める」で、自動では広げない。
  広げるのは「収まる最大まで広げる」ボタンだけ(比率を保った最大の大きさにし、位置は今の位置に一番近い収まる場所。
  中心固定だと1つの角が縁に当たった所で止まり「最大」にならない、とオーナーの指摘で変更)。傾ける前の枠は `EditorModel.tiltBase` に覚えて、傾きを戻すと元に戻る。
  サイドカーから読んだだけの枠は書き換えない(触ったときに合わせる)。CLI も `--crop` `--aspect` `--angle` を指定したときだけ合わせる
- **回転した画像の縁のピクセルは補間で半透明**になる。`CropStage.pixelRect` は傾きがあるとき内側へ丸めて
  1 ピクセル内側に寄せている。これを外すと枠が縁に接したとき半透明の線が出る(テストで検出される)
- **表示倍率**は「写真の1ピクセル = 画面の物理ピクセル何個分か」(オーナーの決定。Retina でもポイントではなく物理ピクセル)。
  文書ビューを「等倍ピクセル数 ÷ backingScaleFactor」ポイントにして、NSScrollView の magnification = 倍率にしている。
  画面の解像度がプレビュー(長辺 2400)を超えたら写真全体を等倍で描く(範囲を絞らない。α7S III なら 2 回目以降 約 35ms と
  測って決めた。高画素機に対応するなら見えている範囲だけ描く方式を検討)。倍率と位置は写真を切り替えても保つ(オーナーの決定)。
  クロップ枠の調整中は拡大しない(従来の SwiftUI 表示に切り替わる)
- **NSScrollView の倍率を変えている途中で layout() → update() が割り込む**。最初の版はこれで、
  「ウインドウに合わせる表示なのに倍率がずれた」と判断して元に戻し、全体表示からのダブルクリックが効かなかった。
  ユーザー操作で倍率を変えるときは `isApplying` で update() を止め、表示のしかた(SwiftUI の状態)はその場で書き換える
  (マウス・通知の処理中はビューの更新中ではないので安全)。ピンチ中も update() から倍率を触らない
- **構図ガイドの Canvas を写真の大きさにしない**。拡大中は写真がビューより何倍も大きくなり、Canvas が巨大な描画領域になる。
  `GuideOverlay(imageFrame:)` でビューの大きさのまま写真の位置に描く
- **黄金三角形の垂線**は画面上(ピクセル比)で直角になるよう、比率込みで計算する。正規化座標で垂線を計算すると斜めになる
- 起動時にフォルダを復元するとき、`onChange(of: selection)` は初回に発火しないので `load(folder:)` から直接 `open` している。
  `open` は同じ URL なら何もしない
- ルックの並びは「組み込みは登録順、ユーザーのルックは `localizedStandardCompare` で名前順」。区切り線で分けて表示
- CLI の `{seq}` は実行ごとに 1(または `--seq-start`)から。アプリの連番は進めない(設定ファイルの同時書き込みを避けるため)

## 拡張のしかた

- **カメラ**: `Camera/<メーカー>/` に `CameraProfile` 準拠の型を作り、`CameraRegistry.makeDefault()` に追加。
  Core Image が未対応の機種は `RAWSource` を実装した別デコーダ(LibRaw 等)を `makeSource` から返す。
  先に `rawdev check` でその機種の対応を確認する
- **ルック**: `BuiltInLooks` に `ColorCubeLook`(sRGB ガンマの RGB→RGB 関数)を足す。色以外の処理は `finish:` か
  `Look` を直接実装。強さの混合は LookStage が共通で行う
- **構図ガイド**: `CompositionGuide` 準拠の型を作り `CompositionGuides.all` に追加、`GuidePalette` に色を足す。
  向きを変えられるガイドは `GuideOptions` にフラグを足し(現在は螺旋用の `flipHorizontal` / `flipVertical` と
  黄金三角形用の `flipTriangle`)、アプリ側の `GuideDisplay`(保存項目)とメニューにも追加する
- **処理段**: `DevelopStage` を実装し、適切な `phase` を付けて `DevelopPipeline.makeDefault` に追加。
  パラメータは `DevelopSettings` に足す(互換性の決まりに従う)
- **テンプレート変数**: `FileNameTemplate.variables` と `value(_:_:_:)` の両方に追加し、README の表も更新

新しい機能には RAWCore 側のテストを付ける。幾何計算や文字列処理のように見た目で確かめにくいものほど数値で検証する。
README.md(利用者向けの説明)も合わせて更新する。

## 現状の制約と今後の候補

オーナーから要望が出たら着手する。勝手に始めない。

- 対応カメラが α7S III のみ
- レンズ補正は ARW に補正値があるレンズだけ。周辺減光の補正の強さが実際のレンズと合っているかは未検証
  (均一に照らされた被写体の写真か、カメラが記録した JPEG と比べれば確かめられる)
- アプリで一括現像ができない(CLI はフォルダ単位で可能)
- HDR 出力時もプレビューは SDR 表示(EDR 表示には Metal ビューが必要)
- 強い HDR で明暗差の大きい輪郭にハローが出ることがある(マスクがガウスぼかしのため。エッジ保存型にすると改善)
- サムネイルは埋め込み JPEG なので現像結果を反映しない
- Finder の「このアプリで開く」に未対応
- 配布用の Developer ID 署名・公証が無い(アドホック署名のみ。他人の Mac ではそのまま起動できない)
- ルックはアプリ起動時に読み込むだけで、`.cube` を追加したら再起動が必要
- `config.json` を外部で編集した場合は手動で「ファイルから読み直す」が必要(ファイル監視なし)
- スライダーを初期値に戻すのは右端の「↶」ボタンだけ。Lightroom のように名前のダブルクリックで戻す操作は無い
  (2026-10-07 にオーナーが「今は見送り」と判断)
