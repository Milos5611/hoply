#!/usr/bin/env bash
# Usage: scripts/build-app.sh
#   Release build → build/Hoply.app (Info.plist, compiled icon, signature). Prints the app's path on stdout.
#   Used by install.sh (local install) and package.sh (release DMG).
# Env: HOPLY_SIGN_IDENTITY  codesign identity; default "-" = ad-hoc
#      HOPLY_HARDENED=1     hardened runtime + secure timestamp (required for notarization)
#      HOPLY_UNIVERSAL=1    arm64 + x86_64 instead of this Mac's architecture
#      HOPLY_VERSION, HOPLY_BUILD  CFBundleShortVersionString / CFBundleVersion of the bundle
set -euo pipefail
cd "$(dirname "$0")/.."

SIGN_IDENTITY="${HOPLY_SIGN_IDENTITY:--}"
ARCHS=()
[ "${HOPLY_UNIVERSAL:-0}" = 1 ] && ARCHS=(--arch arm64 --arch x86_64)

# ${ARCHS[@]+...}: macOS's bash 3.2 treats an empty array as unbound under `set -u`.
swift build -c release --product Hoply ${ARCHS[@]+"${ARCHS[@]}"} >&2
bin="$(swift build -c release --show-bin-path ${ARCHS[@]+"${ARCHS[@]}"})/Hoply"

app=build/Hoply.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin" "$app/Contents/MacOS/Hoply"
cp Sources/Hoply/Info.plist "$app/Contents/Info.plist"
if [ -n "${HOPLY_VERSION:-}" ]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $HOPLY_VERSION" "$app/Contents/Info.plist"
fi
if [ -n "${HOPLY_BUILD:-}" ]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $HOPLY_BUILD" "$app/Contents/Info.plist"
fi

# Hoply.icon (Icon Composer) → Assets.car (Liquid Glass) + Hoply.icns; actool ships with Xcode.
if xcrun --find actool >/dev/null 2>&1; then
  xcrun actool Sources/Hoply/Hoply.icon --compile "$app/Contents/Resources" --platform macosx \
    --minimum-deployment-target 26.0 --app-icon Hoply \
    --output-partial-info-plist "$(mktemp -t hoply-icon)" --output-format human-readable-text >/dev/null
else
  echo "Hoply: actool not found (needs Xcode), building without an app icon" >&2
fi

if [ "${HOPLY_HARDENED:-0}" = 1 ]; then
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$app" >&2
else
  codesign --force --timestamp=none --sign "$SIGN_IDENTITY" "$app" >&2
fi
echo "$app"
