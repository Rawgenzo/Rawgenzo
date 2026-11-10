# リリースの手順

公証済みの DMG を作り、GitHub Releases で配布する手順。管理者向け。
同じ証明書と認証情報を HanaLima でも使っている(HanaLima の `docs/13-release.md`)。

## 前もって要るもの

どれもリリースを作る Mac のログインキーチェーンに置く。

| もの | 中身 | 確かめ方 |
|---|---|---|
| 署名の ID | `Developer ID Application: Yukimitsu Izawa (FJYY683YHH)` の証明書と秘密鍵 | `security find-identity -v -p codesigning` に出る |
| 公証の認証情報 | プロファイル名 `developer-id-notary`(Apple ID と App 用パスワードとチーム ID) | `xcrun notarytool history --keychain-profile developer-id-notary` が終了コード 0 |

- 証明書と秘密鍵の控えは、パスワード付きの `.p12` として、この Mac の外に保管してある。
- App 用パスワードは、Apple ID のアカウント管理(account.apple.com)の「サインインとセキュリティ」で作る。アプリごとではなく、使う場所(Mac・CI)ごとに 1 つ。
- 別の ID やプロファイルを使うときは、環境変数 `SIGN_IDENTITY`・`NOTARY_PROFILE` で `scripts/release.sh` に渡す。

## 手順

1. **バージョンを上げる。** `scripts/make-app.sh` の `VERSION` を書き換えてコミットする。
   機能を足したら `0.x` を 1 つ上げ、不具合を直しただけなら `0.x.y` の `y` を上げる。書き換えだけなら上げない。
   ビルド番号はコミット数から自動で決まる。
2. **ビルドとテストを通す。** `RAW_SAMPLE_DIR=RAWsample swift test` の終了コードが 0 であること。
3. **DMG を作る。** 作業ツリーにコミットしていない変更があると止まる。
   ```sh
   ./scripts/release.sh
   ```
   ビルド・署名(Hardened Runtime とタイムスタンプ付き)・DMG の作成と署名・公証・staple・確かめを順に行う。
   DMG の見た目(開いたウインドウの背景と配置、マウントしたときのアイコン)は `scripts/make_dmg.sh` が Finder に設定させる。
   画面のある Mac で、ほかに同じ名前の DMG をマウントしていない状態で実行する。初回は「Finder を操作しようとしています」の許可が要る。
   背景やアイコンの絵は `Resources/DMG/*.svg` が元で、直したら `scripts/make_dmg_art.sh` で画像を作り直してコミットする。
   公証は数分かかる。終わると `build/Rawgenzo-<版>.dmg` と、その SHA-256 が表示される。
   Apple に送らずに署名までを試すときは `--no-notarize` を付ける。
4. **タグを付けて push する。** タグは DMG を作ったコミットに付ける。
   ```sh
   git tag -a v<版> -m "Rawgenzo <版>"
   git push origin main v<版>
   ```
5. **リリースを下書きで作る。**
   ```sh
   gh release create v<版> build/Rawgenzo-<版>.dmg --draft --verify-tag --title "Rawgenzo <版>" --notes-file <本文のファイル>
   ```
   下書きの URL(`…/releases/tag/untagged-…`)は、本文を書き換えるたびに変わる。見つからないときは Releases の一覧から開く。
6. **見てから公開する。** GitHub の画面で「Publish release」を押すか、次を実行する。
   ```sh
   gh release edit v<版> --draft=false --latest
   ```
7. **公開したものを確かめる。** ダウンロードし直して、次の 3 つを見る。
   ```sh
   shasum -a 256 Rawgenzo-<版>.dmg              # 本文の値と同じ
   xcrun stapler validate Rawgenzo-<版>.dmg     # The validate action worked!
   spctl -a -t open --context context:primary-signature -v Rawgenzo-<版>.dmg   # source=Notarized Developer ID
   ```
   ブラウザでダウンロードした DMG を開き、警告なしに起動することも確かめる(curl で落とすと隔離属性が付かないので、この確かめにならない)。

## リリース本文のひな形

````markdown
<この版で変わったこと。最初の版なら、何をするアプリか>

## 動作環境

- Apple Silicon の Mac
- macOS 13 以降
- 対応カメラ: SONY α7S III(ILCE-7SM3)の ARW のみ

## インストール

1. `Rawgenzo-<版>.dmg` をダウンロードして開く
2. 開いた窓の `Rawgenzo` を `Applications` へドラッグする
3. アプリケーションフォルダから Rawgenzo を起動する

## ダウンロードしたファイルの確認

`Rawgenzo-<版>.dmg` の SHA-256 は次のとおりです。

```
<release.sh が表示した値>
```

ターミナルで次のコマンドを実行し、表示される値が上と一致することを確認してください。

```sh
shasum -a 256 ~/Downloads/Rawgenzo-<版>.dmg
```
````

## うまくいかないとき

- **公証が通らない。** `release.sh` が理由のログ(`notarytool log`)を出す。多いのは、署名に Hardened Runtime かタイムスタンプが無いこと、中の実行ファイルが署名されていないこと。
- **署名で「キーチェーンの鍵を使おうとしています」と聞かれる。** ログインパスワードを入れて「常に許可」を押す。
- **`hdiutil create` が非推奨だという警告が出る。** 2026-11 の時点では動くので、そのままにしている。

## 証明書の期限

いまの証明書は **2027-12-10** に切れる。切れる前に作り直す。

**G2 の発行元から出る証明書は、毎年切れる。** Apple の告知(2026-10-01「Upcoming expiration of Developer ID Certification Authority (Sub-CA)」)に、
G2 の発行元は 2031 年まで有効だが、そこから発行される証明書は毎年切れるので毎年更新が要る、とある。
2026-11-10 に発行した証明書の期限は 13 か月後だった(ちょうど 1 年でない理由は分かっていない)。
期限の 1 か月ほど前に作り直す。

- 署名にタイムスタンプを付けているので、配布済みの DMG とアプリは、証明書が切れても開ける。
- 作り直すと、Developer ID Application の発行枠(有効なもの 5 枚まで)を 1 つ使う。古い発行元(無印の Sub-CA)ではなく、必ず **G2 Sub-CA** を選ぶ。古い発行元は 2027-02-01 に切れる。
- 作り直しの流れ:
  1. キーチェーンアクセスで「ログイン」キーチェーンを選ぶ。
  2. 一覧で何も選んでいない状態にして、「証明書アシスタント → 認証局に証明書を要求…」で CSR を作る。
     一覧で証明書を選んだままだと、その鍵で CSR が作られる。「ログイン」以外のキーチェーンを選んでいると、「指定された項目がキーチェーン内に見つかりませんでした」で止まる。
  3. developer.apple.com の「Certificates」で、Developer ID Application(G2 Sub-CA)を発行する。
  4. 発行された `.cer` を取り込み、`.p12` の控えを作り直す。
  5. このページの期限の日付を書き換える。
  6. 古い証明書をキーチェーンから外す(.p12 の控えは残してよい)。
     新旧どちらも名前が `Developer ID Application: Yukimitsu Izawa (FJYY683YHH)` なので、両方がキーチェーンにあると codesign が「ambiguous」で止まる。
     外さずに使い分けるときは、`security find-identity -v -p codesigning` に出る 40 桁のハッシュを `SIGN_IDENTITY` に渡す。
- Apple Developer Program の会員が切れると、新しい公証はできなくなる。
