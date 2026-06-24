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
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIconName</key><string>AppIcon</string>
    <key>NSMicrophoneUsageDescription</key><string>Resound 需要麦克风来录制你的语音。</string>
    <key>NSAppleEventsUsageDescription</key><string>Resound 需要控制 Google Chrome 来检测 Google Meet。</string>
</dict>
</plist>
PLIST

# App 图标：assets/AppIcon.png → AppIcon.icns（多尺寸 iconset）
ICON_SRC="$REPO/assets/AppIcon.png"
if [ -f "$ICON_SRC" ]; then
    TMP_ICONSET="$(mktemp -d)/AppIcon.iconset"
    mkdir -p "$TMP_ICONSET"
    for size in 16 32 128 256 512; do
        sips -z "$size" "$size" "$ICON_SRC" --out "$TMP_ICONSET/icon_${size}x${size}.png" >/dev/null
        d2=$((size * 2))
        sips -z "$d2" "$d2" "$ICON_SRC" --out "$TMP_ICONSET/icon_${size}x${size}@2x.png" >/dev/null
    done
    iconutil -c icns "$TMP_ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
    rm -rf "$(dirname "$TMP_ICONSET")"
    cp "$ICON_SRC" "$APP/Contents/Resources/AppIcon.png"   # 应用内 BrandIcon 直接读这张
    echo "  🎨 已生成 AppIcon.icns + AppIcon.png"
else
    echo "  ⚠️ 无 assets/AppIcon.png，跳过图标"
fi

# 签名。关键：屏幕录制权限(TCC)对 **ad-hoc** 应用是按 cdhash(可执行哈希)记的，每次重新打包
# cdhash 都变 → 之前授的「屏幕录制」失效、录在线会议报「用户拒绝 TCC」。
# 解法：设环境变量 RESOUND_SIGN_ID 为一个**稳定的代码签名证书**(自签名即可，见 README/DECISIONS)，
# 用它签 → Designated Requirement 稳定 → 屏幕录制授权一次后所有重新打包都长期有效。
# 未设/签名失败则回退 ad-hoc（功能正常，只是每次重打需重授屏幕录制）。资源 bundle 纯数据，无需 --deep。
SIGN_OK=0
# RESOUND_SIGN_ID 未显式设置时，自动探测本机现成的自签名证书「Resound Dev」并用它——
# 这样无需每次 export 或改 shell profile，重打包就长期保持同一签名身份、TCC 授权不掉。
if [ -z "${RESOUND_SIGN_ID:-}" ] && security find-identity -p codesigning 2>/dev/null | grep -qF "Resound Dev"; then
    RESOUND_SIGN_ID="Resound Dev"
fi
# 注意：用 `find-identity -p`（不带 -v）——自签名证书未受信会被 -v 过滤掉，但本地签名/ TCC 用途不需要受信。
if [ -n "${RESOUND_SIGN_ID:-}" ] && security find-identity -p codesigning 2>/dev/null | grep -qF "$RESOUND_SIGN_ID"; then
    echo "▶︎ 稳定身份签名：$RESOUND_SIGN_ID"
    if codesign --force --identifier com.wynne.resound --sign "$RESOUND_SIGN_ID" "$APP"; then
        SIGN_OK=1
    else
        echo "  ⚠️ 稳定身份签名失败，回退 ad-hoc"
    fi
fi
if [ "$SIGN_OK" != 1 ]; then
    codesign --force --sign - "$APP"
    echo "  ℹ️ ad-hoc 签名：重新打包后需在「系统设置 › 隐私与安全性 › 屏幕录制」重新勾选 Resound。"
    echo "     想一劳永逸：创建一个自签名「代码签名」证书后 export RESOUND_SIGN_ID=\"证书名\" 再打包。"
fi

echo "✅ 打包完成：$APP"
echo "   运行：open \"$APP\"   （首次会请求麦克风/屏幕录制/自动化权限）"
echo "   提示：把仓库 .env 复制到 ~/Library/Application Support/Resound/.env，App 才能读到密钥"
