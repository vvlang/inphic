#!/bin/bash
# 把 InphicHub.app 打包成分发用 DMG。
#
#   ./Scripts/make-dmg.sh [path/to/InphicHub.app]
#
# 产物：dist/InphicHub-<version>.dmg
# 布局：应用图标 + 拖到「应用程序」的软链，这是 macOS 的惯例。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
NAME="Inphic Hub"
DIST="$ROOT/dist"
APP="${1:-$HOME/Applications/InphicHub.app}"

if [ ! -d "$APP" ]; then
    echo "❌ 找不到 $APP —— 先跑 Scripts/build-app.sh" >&2
    exit 1
fi

DMG="$DIST/InphicHub-${VERSION}.dmg"
STAGE="$(mktemp -d)"
VOLUME="$STAGE/dmg"
VOLNAME="${NAME} ${VERSION}"
mkdir -p "$VOLUME" "$DIST"

cp -R "$APP" "$VOLUME/"
ln -s /Applications "$VOLUME/Applications"

echo "▸ 生成 DMG: $DMG"
diskutil image create from "$VOLUME" --volumeName "$VOLNAME" --format UDZO "$DMG" >/dev/null

# 设置窗口布局：应用在左，Applications 在右。
# 这一步是纯装饰 —— 挂载失败（CI 沙箱、无桌面会话）时跳过，不影响 DMG 可用。
MOUNTED=0
if diskutil image attach "$DMG" -readwrite -noverify -noautoopen -mountPoint "$STAGE/mnt" >/dev/null 2>&1; then
    MOUNTED=1
else
    echo "  ⚠️  无法挂载镜像（沙箱或无桌面会话），跳过窗口布局"
fi

osascript <<OSA >/dev/null 2>&1 || true
tell application "Finder"
    tell disk "$VOLNAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 140, 760, 480}
        set viewOptions to the icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 96
        set position of item "${NAME}.app" of container window to {180, 220}
        set position of item "Applications" of container window to {480, 220}
        close
        open
        update without registering applications
        delay 1
    end tell
end tell
OSA

if [ "$MOUNTED" = "1" ]; then
    diskutil detach "$STAGE/mnt" >/dev/null 2>&1 || true
fi
rm -rf "$STAGE"

echo "▸ 完成"
ls -lh "$DMG"
echo "  安装：打开 DMG，把应用拖进「应用程序」文件夹"
