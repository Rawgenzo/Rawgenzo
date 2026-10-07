#!/bin/bash
# Rawgenzo.app を作る。
#   ./scripts/make-app.sh            → build/Rawgenzo.app を作成
#   ./scripts/make-app.sh --install  → さらに /Applications にコピー
#
# アイコンを付けたい場合は、1024×1024 の PNG を Resources/AppIcon.png に置く。
set -euo pipefail

APP_NAME="Rawgenzo"
PRODUCT="RawgenzoApp"                        # Package.swift の実行ターゲット名
BUNDLE_ID="io.github.rawgenzo.Rawgenzo"      # 好きな逆ドメイン形式に変えてよい
VERSION="0.1.0"
MIN_MACOS="13.0"

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"

echo "▶ リリースビルド"
swift build -c release --arch arm64 --product "$PRODUCT"
BIN_DIR="$(swift build -c release --arch arm64 --show-bin-path)"

APP="$ROOT/build/$APP_NAME.app"
echo "▶ $APP を組み立て"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/$PRODUCT" "$APP/Contents/MacOS/$APP_NAME"
printf "APPL????" > "$APP/Contents/PkgInfo"

ICON_KEY=""
if [[ -f "$ROOT/Resources/AppIcon.png" ]]; then
    echo "▶ アイコンを生成"
    ICONSET="$(mktemp -d)/AppIcon.iconset"
    mkdir -p "$ICONSET"
    for size in 16 32 128 256 512; do
        sips -z $size $size "$ROOT/Resources/AppIcon.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
        double=$((size * 2))
        sips -z $double $double "$ROOT/Resources/AppIcon.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
    done
    iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
    ICON_KEY="<key>CFBundleIconFile</key><string>AppIcon</string>"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
    <key>CFBundleDevelopmentRegion</key><string>ja</string>
    <key>LSMinimumSystemVersion</key><string>$MIN_MACOS</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.photography</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
    $ICON_KEY
</dict>
</plist>
PLIST

echo "▶ 署名(自分のMac用のアドホック署名)"
codesign --force --deep --sign - "$APP"
codesign --verify --verbose "$APP"

if [[ "${1:-}" == "--install" ]]; then
    DEST="/Applications/$APP_NAME.app"
    echo "▶ $DEST にインストール"
    osascript -e "tell application \"$APP_NAME\" to quit" 2>/dev/null || true
    rm -rf "$DEST"
    ditto "$APP" "$DEST"
    echo "✓ インストールしました。Launchpad または Spotlight から起動できます。"
else
    echo "✓ 作成しました: $APP"
    echo "  /Applications に入れるには: ./scripts/make-app.sh --install"
fi
