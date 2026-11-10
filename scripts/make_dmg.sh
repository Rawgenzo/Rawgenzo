#!/bin/bash
# 見た目を整えた DMG を作る(署名はしない。scripts/release.sh が続けて行う)。
#   scripts/make_dmg.sh <アプリ.app> <出力.dmg> <ボリューム名>
#
# Resources/DMG の画像を使う(作り方は scripts/make_dmg_art.sh)。
#   - 開いたウインドウ: 540×380、背景に矢印、左にアプリ・右に Applications、ツールバーなし
#   - マウントしたときのアイコン: VolumeIcon.icns
# ウインドウの設定は Finder に AppleScript でさせ、DMG の中の .DS_Store に残す。
# そのため画面のある Mac で実行する。初回は「Finder を操作しようとしています」の許可を求められる。
set -euo pipefail

APP="$1"; OUT="$2"; VOLNAME="$3"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ART="$ROOT/Resources/DMG"
APP_NAME="$(basename "$APP")"
MOUNT="/Volumes/$VOLNAME"

if [[ -e "$MOUNT" ]]; then
    echo "✗ $MOUNT が使われています。取り出してから実行してください。" >&2
    exit 1
fi

WORK="$(mktemp -d)"
cleanup() {
    [[ -d "$MOUNT" ]] && hdiutil detach "$MOUNT" -quiet -force || true
    rm -rf "$WORK"
}
trap cleanup EXIT

STAGING="$WORK/staging"
mkdir -p "$STAGING/.background"
ditto "$APP" "$STAGING/$APP_NAME"
ln -s /Applications "$STAGING/Applications"
cp "$ART/background.tiff" "$STAGING/.background/background.tiff"
cp "$ART/VolumeIcon.icns" "$STAGING/.VolumeIcon.icns"

# 書き込める形で作ってマウントし、Finder に見た目を設定させる。.DS_Store を書く余白を足しておく
SIZE_MB=$(( $(du -sm "$STAGING" | cut -f1) + 20 ))
hdiutil create -volname "$VOLNAME" -srcfolder "$STAGING" -fs HFS+ -format UDRW -size "${SIZE_MB}m" -ov "$WORK/rw.dmg" >/dev/null
hdiutil attach "$WORK/rw.dmg" -readwrite -noverify -noautoopen -quiet
SetFile -a C "$MOUNT"   # ボリュームに .VolumeIcon.icns を使わせる

osascript <<APPLESCRIPT
tell application "Finder"
    tell disk "$VOLNAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        -- 窓の枠の座標。中身が 540×380 になるよう、高さにタイトルバーの分を足す
        set the bounds of container window to {200, 120, 740, 528}
        set opts to the icon view options of container window
        set arrangement of opts to not arranged
        set icon size of opts to 128
        set text size of opts to 13
        set background picture of opts to file ".background:background.tiff"
        set position of item "$APP_NAME" of container window to {140, 180}
        set position of item "Applications" of container window to {400, 180}
        close
        open
        update without registering applications
        delay 2
        close
    end tell
end tell
APPLESCRIPT

# Finder が .DS_Store を書き終えるのを待つ
for _ in $(seq 1 20); do [[ -f "$MOUNT/.DS_Store" ]] && break; sleep 0.5; done
[[ -f "$MOUNT/.DS_Store" ]] || { echo "✗ Finder が .DS_Store を書きませんでした" >&2; exit 1; }
sync
hdiutil detach "$MOUNT" -quiet

rm -f "$OUT"
hdiutil convert "$WORK/rw.dmg" -format UDZO -imagekey zlib-level=9 -o "$OUT" >/dev/null
echo "✓ $OUT"
