#!/bin/zsh
# Package build.noindex/Dictate.app + README into a compressed DMG in ~/Downloads/Dictate/.
set -euo pipefail
cd "$(dirname "$0")"
[[ -d build.noindex/Dictate.app ]] || ./build.sh
VER=$(defaults read "$PWD/build.noindex/Dictate.app/Contents/Info.plist" CFBundleShortVersionString)
OUT=~/Downloads/Dictate
STAGE=build.noindex/dmg
rm -rf "$STAGE" && mkdir -p "$STAGE" "$OUT"
cp -R build.noindex/Dictate.app "$STAGE/"
cp Resources/README.ru.txt "$STAGE/Прочитай меня.txt"
ln -s /Applications "$STAGE/Applications"
rm -f "$OUT/Dictate-$VER.dmg"
hdiutil create -volname "Dictate" -srcfolder "$STAGE" -ov -format UDZO -quiet "$OUT/Dictate-$VER.dmg"
cp Resources/README.ru.txt "$OUT/Прочитай меня.txt"
rm -rf "$STAGE"
echo "→ $OUT/Dictate-$VER.dmg ($(du -h "$OUT/Dictate-$VER.dmg" | cut -f1))"
