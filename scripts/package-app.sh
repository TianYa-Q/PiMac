#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h:h}"
APP_DIR="$ROOT_DIR/dist/Pi Mac.app"
APP_VERSION="${APP_VERSION:-0.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"

if [[ ! "$APP_VERSION" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]]; then
  echo "APP_VERSION 必须是 x.y.z 格式，当前值：$APP_VERSION" >&2
  exit 1
fi
if [[ ! "$BUILD_NUMBER" =~ '^[0-9]+$' ]]; then
  echo "BUILD_NUMBER 必须是整数，当前值：$BUILD_NUMBER" >&2
  exit 1
fi

(cd "$ROOT_DIR" && swift build -c release)
BINARY_DIR="$(cd "$ROOT_DIR" && swift build -c release --show-bin-path)"

if [[ -e "$APP_DIR" ]]; then
  command -v trash >/dev/null || { echo "需要安装 trash，拒绝直接删除旧应用" >&2; exit 1; }
  trash "$APP_DIR"
fi

mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BINARY_DIR/PiMac" "$APP_DIR/Contents/MacOS/PiMac"
cp "$ROOT_DIR/Sources/PiMacApp/Resources/AppIcon.icns" \
  "$APP_DIR/Contents/Resources/AppIcon.icns"
cp -R "$BINARY_DIR/PiMac_PiMacApp.bundle" "$APP_DIR/Contents/Resources/"
cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDisplayName</key><string>Pi Mac</string>
  <key>CFBundleExecutable</key><string>PiMac</string>
  <key>CFBundleIdentifier</key><string>com.jianfeng.pi-mac</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleName</key><string>Pi Mac</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$APP_VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP_DIR"
echo "已生成：$APP_DIR"
