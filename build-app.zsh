#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
SOURCE_FILE="$SCRIPT_DIR/app/OpenAIDictateApp.swift"
ENTITLEMENTS_FILE="$SCRIPT_DIR/app/OpenAIDictateApp.entitlements"
APP_DIR="$SCRIPT_DIR/build/OpenAI Dictate.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
TARGET_TRIPLE="arm64-apple-macos26.0"

mkdir -p "$MACOS_DIR"

swiftc "$SOURCE_FILE" \
  -target "$TARGET_TRIPLE" \
  -framework AVFoundation \
  -framework AppKit \
  -framework ApplicationServices \
  -framework Carbon \
  -framework Foundation \
  -framework Security \
  -o "$MACOS_DIR/OpenAIDictate"

cat > "$CONTENTS_DIR/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>OpenAIDictate</string>
  <key>CFBundleIdentifier</key>
  <string>local.openai-dictate.app</string>
  <key>CFBundleName</key>
  <string>OpenAI Dictate</string>
  <key>CFBundleDisplayName</key>
  <string>OpenAI Dictate</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSMicrophoneUsageDescription</key>
  <string>Records your dictation audio so it can be transcribed by OpenAI.</string>
</dict>
</plist>
PLIST

chmod +x "$MACOS_DIR/OpenAIDictate"
if command -v codesign >/dev/null 2>&1; then
  SIGN_IDENTITY="${OPENAI_DICTATE_SIGN_IDENTITY:--}"
  codesign --force --deep --sign "$SIGN_IDENTITY" --entitlements "$ENTITLEMENTS_FILE" "$APP_DIR" >/dev/null
fi

echo "$APP_DIR"
