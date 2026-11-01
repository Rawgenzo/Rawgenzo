# AGENTS.md

Rawgenzo(Apple Silicon 向けの RAW 現像ソフト。Swift Package)で作業する AI エージェント向けの案内。

## 最初に読むもの

- [docs/coding-guidelines.md](docs/coding-guidelines.md) — コーディング規約。コードを書く前に読み、書き終えたら末尾の「書き終えたら確かめること」を確かめる
- [docs/ai-mcp-architecture.md](docs/ai-mcp-architecture.md) — AI の道具(MCP)の仕組み

## ビルドとテスト

```bash
swift build
swift test
RAW_SAMPLE_DIR=RAWsample swift test   # 実サンプルを使うテストも含める(サンプルがあるとき)
./scripts/make-app.sh                 # .app を作る(rawdev も同梱)
```

報告の前に、ビルドとテストを通して終了コードを確かめる。

## 決まり

- コメント・UI の文言・エラーの文・コミットメッセージは日本語で書く
- 元の RAW ファイルは書き換えない。設定は写真ごとのサイドカー(`<RAW>.rawgenzo.json`)に保存する
- 設定ファイルの形を変えるときは、古いファイルも読めるようにする(規約の「10. エラー処理と堅牢性」)
- AI が読む道具の名前・説明・入力の形を変えるつもりのない変更では、MCP の tools/list の出力が変わっていないことを確かめる
