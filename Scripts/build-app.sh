#!/bin/bash
# 构建 InphicHub.app。
#
#   ./Scripts/build-app.sh [debug|release]
#
# 产物：dist/InphicHub.app
# 说明：SwiftPM 的可执行文件直接跑也能用，但要做成正规 .app 需要 Info.plist、
#       图标和签名，否则菜单栏图标与蓝牙权限请求都不会正常工作。
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# 版本号的唯一真源是仓库根目录的 VERSION 文件
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
BUILD="${BUILD_NUMBER:-$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)}"
AUTHOR="AIYeon"
BUNDLE_ID="cn.inphic.hub.mac"
NAME="Inphic Hub"
# 同步盘里的 .build 会产生 AppleDouble 文件导致 codesign 失败，编译产物放到本地盘。
SCRATCH="${INPHIC_SCRATCH:-/tmp/inphic-build}"
# 产物默认放本地盘：项目所在的飞牛同步盘是 FUSE 文件系统，不支持 exec，
# 从那里启动会报 errno 111。dist/ 只作为归档副本。
LOCAL_DIST="${INPHIC_DIST:-$HOME/Applications}"
ARCHIVE="$ROOT/dist"
APP="$LOCAL_DIST/InphicHub.app"

cd "$ROOT"

echo "▸ $NAME $VERSION ($BUILD) · $AUTHOR"
echo "▸ 编译 ($CONFIG)…"
swift build -c "$CONFIG" --scratch-path "$SCRATCH" --product InphicHub
BIN="$(swift build -c "$CONFIG" --scratch-path "$SCRATCH" --show-bin-path)/InphicHub"

echo "▸ 组装 .app…"
# 先在临时目录里组装，再整体搬过去。已存在的产物改名让位，不直接删除。
STAGE="$(mktemp -d)/InphicHub.app"
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources"
cp "$BIN" "$STAGE/Contents/MacOS/InphicHub"

cat > "$STAGE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>          <string>zh_CN</string>
    <key>CFBundleExecutable</key>                 <string>InphicHub</string>
    <key>CFBundleIdentifier</key>                 <string>$BUNDLE_ID</string>
    <key>CFBundleInfoDictionaryVersion</key>      <string>6.0</string>
    <key>CFBundleName</key>                       <string>$NAME</string>
    <key>CFBundleDisplayName</key>                <string>$NAME</string>
    <key>CFBundlePackageType</key>                <string>APPL</string>
    <key>CFBundleShortVersionString</key>         <string>$VERSION</string>
    <key>CFBundleVersion</key>                    <string>$BUILD</string>
    <key>LSMinimumSystemVersion</key>             <string>14.0</string>
    <key>NSHighResolutionCapable</key>            <true/>
    <key>NSBluetoothAlwaysUsageDescription</key>
    <string>Inphic Hub 需要蓝牙权限才能连接你的鼠标并修改 DPI、灯光和按键设置。</string>
    <key>NSPrincipalClass</key>                   <string>NSApplication</string>
    <key>NSHumanReadableCopyright</key>
    <string>© 2026 $AUTHOR · MIT License</string>
</dict>
</plist>
PLIST

# 图标。来源见 docs/reference/ —— 官方 Inphic_signed.pkg 里的 AppIcon.icns，
# 原始素材只有 256px，Scripts/make-icon.py 补齐到 macOS 需要的全部尺寸。
if [ -f "$ROOT/Scripts/AppIcon.icns" ]; then
    cp "$ROOT/Scripts/AppIcon.icns" "$STAGE/Contents/Resources/AppIcon.icns"
    /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$STAGE/Contents/Info.plist"
else
    echo "  ⚠️  缺少 Scripts/AppIcon.icns，App 将使用默认图标"
fi

# 搬到位：旧产物改名留存，避免误删用户自己的东西。
mkdir -p "$LOCAL_DIST" "$ARCHIVE"
if [ -e "$APP" ]; then
    mv "$APP" "$APP.$(date +%Y%m%d%H%M%S).bak"
fi
mv "$STAGE" "$APP"

# 同步盘（飞牛 / iCloud 等）会丢掉可执行位，搬过去之后必须补回来，
# 否则 launchd 会以 errno 111 启动失败。
chmod +x "$APP/Contents/MacOS/InphicHub"

echo "▸ 临时签名…"
codesign --force --deep --sign - "$APP" 2>&1 | sed 's/^/  /'

# 归档一份到项目里，方便进版本库；它不能直接运行。
cp -R "$APP" "$ARCHIVE/InphicHub.app" 2>/dev/null || true

echo "▸ 完成"
echo "  可运行版本：$APP"
echo "  运行：open \"$APP\""
