#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
OUT="$ROOT/build"
VERSION="1.0.0-beta.2"
APP="$OUT/NetworkSwitch.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$OUT/AppIcon.iconset"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
for ARCH in arm64 x86_64; do
  xcrun swiftc -swift-version 5 -O -sdk "$SDK" -target "$ARCH-apple-macos13.0" \
    -framework AppKit -framework SystemConfiguration \
    "$ROOT/Core.swift" "$ROOT/MacNetwork.swift" "$ROOT/App.swift" -o "$OUT/NetworkSwitch-$ARCH"
done
xcrun lipo -create "$OUT/NetworkSwitch-arm64" "$OUT/NetworkSwitch-x86_64" -output "$APP/Contents/MacOS/NetworkSwitch"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/../source/NetworkSwitch-logo.png" "$APP/Contents/Resources/NetworkSwitch-logo.png"
for SIZE in 16 32 128 256 512; do
  sips -z "$SIZE" "$SIZE" "$ROOT/../source/NetworkSwitch-logo.png" --out "$OUT/AppIcon.iconset/icon_${SIZE}x${SIZE}.png" >/dev/null
  DOUBLE=$((SIZE * 2))
  sips -z "$DOUBLE" "$DOUBLE" "$ROOT/../source/NetworkSwitch-logo.png" --out "$OUT/AppIcon.iconset/icon_${SIZE}x${SIZE}@2x.png" >/dev/null
done
iconutil -c icns "$OUT/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
# Ad-hoc signing validates bundle integrity; it is NOT Developer ID notarization.
codesign --force --sign - --timestamp=none "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
plutil -lint "$APP/Contents/Info.plist"
lipo -archs "$APP/Contents/MacOS/NetworkSwitch"
xcrun swiftc -swift-version 5 "$ROOT/Core.swift" "$ROOT/Tests.swift" -o "$OUT/CoreTests"
"$OUT/CoreTests" | tee "$OUT/TEST-RESULTS.txt"
"$APP/Contents/MacOS/NetworkSwitch" --inspect-json > "$OUT/READ-ONLY-SMOKE.json"
"$APP/Contents/MacOS/NetworkSwitch" --render-preview "$OUT/preview-macOS.png"
printf '\nBuild: arm64 + x86_64; bundle signature verified; read-only macOS inspection passed.\nReal network switching, sleep/wake and reboot: NOT tested.\n' >> "$OUT/TEST-RESULTS.txt"
cp "$ROOT/README.md" "$OUT/README-macOS.md"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUT/NetworkSwitch-macOS-$VERSION-universal.zip"
(cd "$OUT" && shasum -a 256 "NetworkSwitch-macOS-$VERSION-universal.zip" > SHA256SUMS-macOS.txt)
echo "Built: $OUT/NetworkSwitch-macOS-$VERSION-universal.zip"
