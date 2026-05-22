#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
APP_DIR="$SCRIPT_DIR/build/OpenAI Dictate.app"
DMG_PATH="$SCRIPT_DIR/build/OpenAI Dictate.dmg"
VOLUME_NAME="OpenAI Dictate"
STAGING_DIR="$(mktemp -d "${TMPDIR%/}/openai-dictate-dmg.XXXXXX")"

cleanup() {
  rm -rf "$STAGING_DIR"
}

trap cleanup EXIT INT TERM

"$SCRIPT_DIR/build-app.zsh" >/dev/null

ditto "$APP_DIR" "$STAGING_DIR/OpenAI Dictate.app"
ln -s /Applications "$STAGING_DIR/Applications"

cat > "$STAGING_DIR/How to Open.txt" <<'EOF'
OpenAI Dictate

1. Drag "OpenAI Dictate.app" into Applications.
2. Open it from /Applications.
3. If macOS blocks the first launch, right click the app and choose Open.
4. Grant Microphone permission to record.
5. Grant Accessibility permission to auto-paste.
6. Open the menu bar app and save your OpenAI API key.

Requirements:
- Apple Silicon Mac
- macOS 26 or newer
EOF

rm -f "$DMG_PATH"
hdiutil create \
  -volname "$VOLUME_NAME" \
  -srcfolder "$STAGING_DIR" \
  -fs HFS+ \
  -format UDZO \
  -imagekey zlib-level=9 \
  -ov "$DMG_PATH" >/dev/null

echo "$DMG_PATH"
