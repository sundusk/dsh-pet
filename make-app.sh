#!/bin/bash
# 构建并打包成 .app（LSUIElement 纯菜单栏应用），然后启动
set -euo pipefail
cd "$(dirname "$0")"

EXEC_NAME="MoodBall"
APP_NAME="DSH Pet"
BUNDLE_EXEC_NAME="DSHPet"
BUNDLE_ID="com.sundusk.moodball"
BUILD_DIR=".build/release"
APP_DIR="dist/${APP_NAME}.app"
ICON_SOURCE="Resources/moodball-icon-1024.png"
ICONSET_DIR=".build/MoodBall.iconset"

echo "==> swift build -c release --disable-sandbox"
# --disable-sandbox：项目位于受限工作区（如 DSH 会话目录）时，
# SwiftPM 的 sandbox-exec 会被外层沙箱拦截，需禁用内层沙箱
swift build -c release --disable-sandbox

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

cp "$BUILD_DIR/$EXEC_NAME" "$APP_DIR/Contents/MacOS/$BUNDLE_EXEC_NAME"

echo "==> 复制宠物图集"
for pet_resource in Resources/Pet/Xiaoyu/XiaoyuSprites.png Resources/Pet/Xiaoyu/XiaoyuDragSprites.png Resources/Pet/Xinzhizhu/XinzhizhuSprites.webp Resources/Pet/Jingyuniang/JingyuniangSprites.png; do
	if [ ! -f "$pet_resource" ]; then
		echo "未找到宠物资源：$pet_resource" >&2
		exit 1
	fi
	cp "$pet_resource" "$APP_DIR/Contents/Resources/"
done

if [ ! -f "$ICON_SOURCE" ]; then
	 echo "未找到应用图标源文件：$ICON_SOURCE" >&2
	 exit 1
fi

echo "==> 生成应用图标"
rm -rf "$ICONSET_DIR"
mkdir -p "$ICONSET_DIR"

sips -z 16 16 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_16x16.png" >/dev/null
sips -z 32 32 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_16x16@2x.png" >/dev/null
sips -z 32 32 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_32x32.png" >/dev/null
sips -z 64 64 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_32x32@2x.png" >/dev/null
sips -z 128 128 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_128x128.png" >/dev/null
sips -z 256 256 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_128x128@2x.png" >/dev/null
sips -z 256 256 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_256x256.png" >/dev/null
sips -z 512 512 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_256x256@2x.png" >/dev/null
sips -z 512 512 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_512x512.png" >/dev/null
sips -z 1024 1024 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_512x512@2x.png" >/dev/null

iconutil -c icns "$ICONSET_DIR" -o "$APP_DIR/Contents/Resources/DSHPet.icns"
cp Resources/ThirdPartyNotices.txt "$APP_DIR/Contents/Resources/ThirdPartyNotices.txt"

cat > "$APP_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key>
	<string>DSH Pet</string>
	<key>CFBundleDisplayName</key>
	<string>DSH Pet</string>
	<key>CFBundleIdentifier</key>
	<string>com.sundusk.moodball</string>
	<key>CFBundleExecutable</key>
	<string>DSHPet</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleIconFile</key>
	<string>DSHPet</string>
	<key>CFBundleShortVersionString</key>
	<string>0.8.0</string>
	<key>CFBundleVersion</key>
	<string>14</string>
	<key>LSMinimumSystemVersion</key>
	<string>14.0</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSHighResolutionCapable</key>
	<true/>
</dict>
</plist>
PLIST

# 本地 ad-hoc 签名（未签名二进制在 arm64 上也能跑，签名更稳）
codesign --force --sign - "$APP_DIR" 2>/dev/null || true

if [ "${MOODBALL_SKIP_OPEN:-0}" != "1" ]; then
	echo "==> 打开 $APP_DIR"
	open "$APP_DIR"
fi

echo "✅ 完成"
