#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h:h}"
APP_DIR="$ROOT_DIR/dist/Pi Mac.app"
BINARY_DIR="$(cd "$ROOT_DIR" && swift build -c release --show-bin-path)"

if [[ -e "$APP_DIR" ]]; then
  command -v trash >/dev/null || { echo "需要安装 trash，拒绝直接删除旧应用" >&2; exit 1; }
  trash "$APP_DIR"
fi

mkdir -p "$APP_DIR/Contents/MacOS"
cp "$BINARY_DIR/PiMac" "$APP_DIR/Contents/MacOS/PiMac"
cat > "$APP_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDisplayName</key><string>Pi Mac</string>
  <key>CFBundleExecutable</key><string>PiMac</string>
  <key>CFBundleIdentifier</key><string>com.jianfeng.pi-mac</string>
  <key>CFBundleName</key><string>Pi Mac</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP_DIR"
echo "已生成：$APP_DIR"
