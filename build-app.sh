#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/dist/Codex Dictation Console.app"
CONTENTS="$APP/Contents"
HELPER="$CONTENTS/Library/LoginItems/Codex Dictation Capture Helper.app"
IDENTITY="${CODE_SIGN_IDENTITY:--}"

if [[ -e "$APP" || -L "$APP" ]]; then
  echo "A bundle already exists at $APP. Move or remove it before rebuilding." >&2
  exit 1
fi
cd "$ROOT"
SDK_PATH="$(xcrun --show-sdk-path)"
SDK_VERSION="$(xcrun --show-sdk-version)"
swift build --build-system native --sdk "$SDK_PATH" -c release --product CodexDictationLab
swift build --build-system native --sdk "$SDK_PATH" -c release --product CodexDictationCaptureHelper
python3 scripts/verify-build-sdk.py --sdk "$SDK_VERSION" \
  .build/release/CodexDictationLab .build/release/CodexDictationCaptureHelper

mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources" "$HELPER/Contents/MacOS"
cp .build/release/CodexDictationLab "$CONTENTS/MacOS/CodexDictationConsole"
cp .build/release/CodexDictationCaptureHelper "$HELPER/Contents/MacOS/CodexDictationCaptureHelper"
cp Resources/Info.plist "$CONTENTS/Info.plist"
cp Resources/AppIcon.icns "$CONTENTS/Resources/AppIcon.icns"
cp Resources/CaptureHelper-Info.plist "$HELPER/Contents/Info.plist"
if [[ "$IDENTITY" == "-" ]]; then
  codesign --force --sign - "$HELPER"
  codesign --force --sign - "$APP"
else
  codesign --force --options runtime --timestamp --sign "$IDENTITY" "$HELPER"
  codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
fi
codesign --verify --deep --strict "$APP"
printf 'Built: %s\n' "$APP"
