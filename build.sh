#!/bin/zsh
# Build Dictate.app from Sources/ — no Xcode project, just swiftc + a bundle.
# Bundles the static whisper-server and the q5_0 model from vendor/ when present,
# so the app is self-contained on a Mac with no Homebrew.
set -euo pipefail
cd "$(dirname "$0")"
APP=build.noindex/Dictate.app
SERVER=vendor/whisper.cpp/build/bin/whisper-server
MODEL=vendor/models/ggml-large-v3-turbo-q5_0.bin
rm -rf build.noindex && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -target arm64-apple-macos13.0 \
  -framework AppKit -framework AVFoundation -framework ServiceManagement \
  -framework SwiftUI -framework Translation -framework NaturalLanguage -framework CoreAudio -framework AudioToolbox \
  Sources/*.swift -o "$APP/Contents/MacOS/Dictate"
cp Resources/Info.plist "$APP/Contents/"
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"
if [[ -f $SERVER && -f $MODEL ]]; then
  cp "$SERVER" "$APP/Contents/MacOS/whisper-server"
  cp "$MODEL" "$APP/Contents/Resources/"
  echo "bundled built-in speech engine ($(du -h "$MODEL" | cut -f1) model)"
else
  echo "NOTE: vendor/ server or model missing — app will rely on an external whisper-server"
fi
# Sign with the local "Dictate Dev" identity when present: a stable certificate keeps the
# Accessibility/Microphone grants across rebuilds. Ad-hoc otherwise (grants reset each build).
if security find-identity -v -p codesigning | grep -q '"Dictate Dev"'; then
  codesign --force --deep --sign "Dictate Dev" "$APP" && echo "signed: Dictate Dev"
else
  codesign --force --deep --sign - "$APP" && echo "signed: ad-hoc"
fi
echo "built $APP"
