#!/usr/bin/env bash
# 把 SwiftPM 的 ResoundApp 可执行打包成可运行的 Resound.app（含权限声明 + ad-hoc 签名）。
# 用法：scripts/bundle-app.sh [debug|release]   默认 release
# 产物：build/Resound.app   （build/ 已 gitignored）
set -euo pipefail
CONFIG="${1:-release}"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO"

echo "▶︎ swift build -c $CONFIG --product ResoundApp"
swift build -c "$CONFIG" --product ResoundApp
BIN_DIR="$REPO/.build/$CONFIG"
EXE="$BIN_DIR/ResoundApp"
[ -f "$EXE" ] || { echo "找不到可执行：$EXE"; exit 1; }

APP="$REPO/build/Resound.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$EXE" "$APP/Contents/MacOS/Resound"

# SwiftPM 资源 bundle(如 ResoundCore 的 TSCharacters)放 Resources，Bundle.module 经 Bundle.main.resourceURL 能找到
for b in "$BIN_DIR"/*.bundle; do
    [ -e "$b" ] && cp -R "$b" "$APP/Contents/Resources/"
done

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Resound</string>
    <key>CFBundleDisplayName</key><string>Resound</string>
    <key>CFBundleIdentifier</key><string>com.wynne.resound</string>
    <key>CFBundleExecutable</key><string>Resound</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
    <key>NSMicrophoneUsageDescription</key><string>Resound 需要麦克风来录制你的语音。</string>
    <key>NSAppleEventsUsageDescription</key><string>Resound 需要控制 Google Chrome 来检测 Google Meet。</string>
</dict>
</plist>
PLIST

# ad-hoc 签名(本地自用足够；TCC 按 bundle id 记权限)。资源 bundle 是纯数据，无需 --deep
codesign --force --sign - "$APP"

echo "✅ 打包完成：$APP"
echo "   运行：open \"$APP\"   （首次会请求麦克风/屏幕录制/自动化权限）"
echo "   提示：把仓库 .env 复制到 ~/Library/Application Support/Resound/.env，App 才能读到密钥"
