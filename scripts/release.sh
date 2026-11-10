#!/bin/bash
# 配布用の DMG を作る。署名・公証・staple・確かめまでを行う。GitHub Releases への公開はしない。
#   ./scripts/release.sh                → build/Rawgenzo-<版>.dmg を作り、Apple の公証を通す
#   ./scripts/release.sh --no-notarize  → 署名した DMG を作るところまで(Apple には何も送らない)
#
# 前もって要るもの(どちらもログインキーチェーンに置く):
#   - Developer ID Application の証明書と秘密鍵
#   - notarytool の認証情報(xcrun notarytool store-credentials で保存したもの)
# 別のものを使うときは、環境変数 SIGN_IDENTITY・NOTARY_PROFILE で渡す。
set -euo pipefail

APP_NAME="Rawgenzo"
SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application: Yukimitsu Izawa (FJYY683YHH)}"
NOTARY_PROFILE="${NOTARY_PROFILE:-developer-id-notary}"

NOTARIZE=1
case "${1:-}" in
    "") ;;
    --no-notarize) NOTARIZE=0 ;;
    *) echo "使い方: $0 [--no-notarize]" >&2; exit 2 ;;
esac

cd "$(dirname "$0")/.."
ROOT="$(pwd)"

# ビルド番号はコミット数なので、手元の変更が混じると、同じ番号で中身の違う DMG ができてしまう
if [[ -n "$(git status --porcelain)" ]]; then
    echo "✗ コミットしていない変更があります。コミットしてから実行してください。" >&2
    exit 1
fi

SIGN_IDENTITY="$SIGN_IDENTITY" ./scripts/make-app.sh

APP="$ROOT/build/$APP_NAME.app"
VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")"
DMG="$ROOT/build/$APP_NAME-$VERSION.dmg"

echo "▶ $DMG を作成"
scripts/make_dmg.sh "$APP" "$DMG" "$APP_NAME $VERSION"
codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"
codesign --verify --verbose=2 "$DMG"

if [[ $NOTARIZE == 0 ]]; then
    echo "✓ 署名した DMG を作りました(公証はしていません): $DMG"
    exit 0
fi

echo "▶ 公証を申請(数分かかる)"
# 通らなかったときも理由のログを出せるよう、notarytool の失敗でここでは止めない
RESULT="$(xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait 2>&1)" || true
echo "$RESULT"
if ! grep -q "status: Accepted" <<<"$RESULT"; then
    ID="$(awk '/^ *id:/ { print $2; exit }' <<<"$RESULT")"
    echo "✗ 公証が通りませんでした。理由は次のログを見てください。" >&2
    [[ -n "$ID" ]] && xcrun notarytool log "$ID" --keychain-profile "$NOTARY_PROFILE" >&2
    exit 1
fi

echo "▶ 公証の結果を DMG に付ける"
xcrun stapler staple "$DMG"

echo "▶ 確かめ"
xcrun stapler validate "$DMG"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
shasum -a 256 "$DMG"
echo "✓ 配布できる DMG ができました: $DMG"
