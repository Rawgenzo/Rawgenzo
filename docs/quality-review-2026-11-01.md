# ソースコード評価 2026-11-01

[評価基準票](quality-rubric.md) に沿って、advisor(Fable 5.1)が評価した結果。

評価者が読んだのは次のとおり。
- 全文: RawgenzoSurface、SettingsFields、rawdev、Package.swift
- 概要だけ: EditorModel、各ビュー、テスト

RAWCore の処理の中身とビューの本体は読んでいない。そこにかかわる点数は、構造から見た見立てにとどまる。

## 点数

| # | 項目 | 点 | 根拠 | 確からしさ |
|---|---|---|---|---|
| 1 | 構造化 | 4 | モジュールの分け方は Package.swift で守られている。減点は大きすぎるファイル: RawgenzoTools.swift 1022 行(道具 6 群・整形・取り消し)、RAWCoreTests.swift 2126 行、rawdev の main.swift 546 行のトップレベル処理 | 高 |
| 2 | YAGNI | 4 | 先回りの抽象は見当たらない | 中 |
| 3 | DRY | 3 | `uniqueIDs` があるのに、同じ処理が 3 か所に手書きで残る。丸めの関数があちこちにある(round1・round3・round4 と、その場の `*100`・`*1000`)。SettingsFields では、同じ 6 項目を 4 つの switch で並べている。設定を寛容に読む書き方が 5 ファイル以上で繰り返される | 高 |
| 4 | KISS | 4 | 素直な書き方で、日付つきで「なぜ」を書いたコメントが良い。減点は長いハンドラ: get_preview が約 70 行、set_crop が約 80 行 | 高 |
| 5 | 拡張性 | 4 | 数値の項目は ParameterCatalog の 1 か所で足せる。数値でない項目を足すと SettingsFields の 5 か所を直すことになる。道具を足すときは 1000 行のファイルを触る | 高 |
| 6 | 凝集度と単一責任 | 3 | RawgenzoTools が、道具の登録・JSON への整形・統計の要約・取り消し・ID の解決をまとめて抱えている。EditorModel も、拡大縮小・色の選択・切り抜き・描画・保存・書き出し・AI との橋渡し・編集前の表示を持つ | 中 |
| 7 | 結合度と依存の向き | 5 | 依存の向きは Package.swift で強制されている。OperationSurface は Foundation と Darwin だけを使い、RAWCore は AppKit も SwiftUI も読み込まない | 高 |
| 8 | テスト容易性 | 4 | UI を使わないテストの組が 3 つある。減点は 2126 行のテストファイル | 中 |
| 9 | 可読性 | 4 | 名前が良く、コメントは「なぜ」を書いている。減点は長いハンドラ | 高 |
| 10 | エラー処理と堅牢性 | 4 | 道具のエラーの文が揃っている。寛容な読み込みは意図して作られ、テストもある。減点: list_photos は、メタデータを読めない写真を黙って飛ばす | 高 |

## 直す案(効果が大きく手間が小さい順)

1. 手書きの重複を `uniqueIDs` に置き換える。adjust の重複除き(要素ごとに数える)は意図が違うので触らない
2. 丸めの関数を 1 つにまとめる
3. SettingsFields を、項目の表(id・名前・比べ方・写し方・説明)に書き換える
4. RawgenzoTools.swift を、道具の群ごとのファイルに分ける
5. 寛容な読み込みの書き方を、KeyedDecodingContainer の拡張にまとめる
6. RAWCoreTests.swift を話題ごとに分ける
7. rawdev の main.swift を、コマンドごとの関数に分ける
8. (任意)get_preview・set_crop の引数の確かめを、小さな型に切り出す

見送り: EditorModel の分割。UI に近く、動かして確かめられないため。

## 守ること

- AI が読む道具の名前・説明・入力の形を変えない。書き換えの前後で MCP の tools/list の出力を比べ、差が無いことを確かめる。
- 1 段ごとにビルドとテストを通し、1 段ごとにコミットする。

## 直した結果(refactor-quality ブランチ)

案の 1〜7 を、1 段ずつコミットした。どの段でも次の 3 つを確かめている。
- ビルドが通る
- 実サンプルを含むテスト 213 件が通る
- MCP の tools/list の出力が、書き換えの前と 1 バイトも違わない

| 案 | したこと |
|---|---|
| 1 | 写真 ID の重複除き 3 か所を `uniqueIDs` に寄せた |
| 2 | 丸めを `Double.rounded(toPlaces:)`(RAWCore)の 1 つにまとめた |
| 3 | SettingsFields を項目の表にした。数値でない項目は 1 行で足せる |
| 4 | RawgenzoTools.swift(1022 行)を 8 ファイルに分けた。いちばん大きいファイルで 207 行 |
| 5 | 寛容な読み込みを `c.tolerant(.key, default:)` にまとめた |
| 6 | RAWCoreTests.swift(2126 行)を、テストの組ごとの 27 ファイルに分けた |
| 7 | rawdev の main.swift を、コマンドごとの関数に分けた |

残したもの:
- EditorModel の分割。UI に近く、動かして確かめないと危ない
- 案 8(get_preview・set_crop の引数の確かめを型に切り出す)。効果に比べて手間が大きい
- list_photos が、読めない写真を黙って飛ばすこと。結果の形が変わる(動きの変更)ので、この書き換えには入れない
