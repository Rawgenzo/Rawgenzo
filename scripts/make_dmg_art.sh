#!/bin/bash
# DMG の見た目に使う画像を、Resources/DMG の SVG から作る。SVG を直したときだけ実行し、できた画像もコミットする
# (scripts/release.sh は、できた画像を使うだけ)。
#   Resources/DMG/VolumeIcon.icns  マウントしたときのアイコン(volume-icon.svg から)
#   Resources/DMG/background.tiff  開いたウインドウの背景。1 倍と 2 倍を 1 つにまとめる(background.svg から)
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
DMG="$ROOT/Resources/DMG"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

swiftc -O -o "$WORK/svg2png" scripts/svg2png.swift
# svg2png は SVG のフォルダしか読めないので、参照するアプリのアイコンを横に置く
cp "$DMG"/*.svg "$ROOT/Resources/AppIcon.png" "$WORK/"

echo "▶ VolumeIcon.icns"
"$WORK/svg2png" --transparent "$WORK/volume-icon.svg" "$WORK/volume-icon.png"   # 512 ポイント → 1024px
ICONSET="$WORK/VolumeIcon.iconset"
mkdir "$ICONSET"
for size in 16 32 128 256 512; do
    sips -z $size $size "$WORK/volume-icon.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    sips -z $((size * 2)) $((size * 2)) "$WORK/volume-icon.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$DMG/VolumeIcon.icns"

echo "▶ background.tiff"
"$WORK/svg2png" "$WORK/background.svg" "$WORK/background@2x.png"                 # 540×380 ポイント → 1080×760px
sips -z 380 540 "$WORK/background@2x.png" --out "$WORK/background.png" >/dev/null
# 2 倍の画像を 144dpi にしておくと、Finder が Retina の画面で 2 倍の方を使う
sips -s dpiWidth 144 -s dpiHeight 144 "$WORK/background@2x.png" >/dev/null
tiffutil -cathidpicheck "$WORK/background.png" "$WORK/background@2x.png" -out "$DMG/background.tiff"
echo "✓ $DMG に作りました"
