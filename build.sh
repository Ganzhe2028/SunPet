#!/bin/bash
# Build SunPet.app from source. No Xcode project, no dependencies.
set -euo pipefail
cd "$(dirname "$0")"

if ! command -v swiftc >/dev/null 2>&1; then
  echo "找不到 swiftc。请先安装 Xcode Command Line Tools：xcode-select --install" >&2
  exit 1
fi

APP="build/SunPet.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O -target arm64-apple-macosx14.0 \
  -framework AppKit -framework AVFoundation -framework IOKit -framework Network \
  Sources/main.swift Sources/Motion.swift -o "$APP/Contents/MacOS/SunPet"

cp -R Assets/. "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>SunPet</string>
<key>CFBundleIdentifier</key><string>com.ganzhe2028.sunpet</string>
<key>CFBundleName</key><string>SunPet</string>
<key>CFBundleDisplayName</key><string>太对了</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.1</string>
<key>CFBundleVersion</key><string>2</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>CFBundleIconFile</key><string>AppIcon</string>
</dict></plist>
PLIST

codesign --force --sign - "$APP" >/dev/null 2>&1 || codesign --force --sign - "$APP"
printf 'Built: %s\n' "$APP"
printf '打开它：open %s\n' "$APP"
