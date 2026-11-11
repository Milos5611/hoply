#!/usr/bin/env bash
# Usage: scripts/build-app.sh
#   Release build → build/Hoply.app (Info.plist, compiled icon, signature). Prints the app's path on stdout.
#   Used by install.sh (local install) and package.sh (release DMG).
# Env: HOPLY_SIGN_IDENTITY  codesign identity; default "-" = ad-hoc
#      HOPLY_HARDENED=1     hardened runtime + secure timestamp (required for notarization)
#      HOPLY_UNIVERSAL=1    arm64 + x86_64 instead of this Mac's architecture
#      HOPLY_VERSION, HOPLY_BUILD  CFBundleShortVersionString / CFBundleVersion of the bundle
#      HOPLY_FEED_URL, HOPLY_ED_PUBLIC_KEY  Sparkle's SUFeedURL / SUPublicEDKey; both or neither (package.sh sets
#        them for release builds). Without them the app never checks for updates.
set -euo pipefail
cd "$(dirname "$0")/.."

SIGN_IDENTITY="${HOPLY_SIGN_IDENTITY:--}"
ARCHS=()
[ "${HOPLY_UNIVERSAL:-0}" = 1 ] && ARCHS=(--arch arm64 --arch x86_64)

swift build -c release --product Hoply ${ARCHS[@]+"${ARCHS[@]}"} >&2
bin="$(swift build -c release --show-bin-path ${ARCHS[@]+"${ARCHS[@]}"})/Hoply"

app=build/Hoply.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/Frameworks"
cp "$bin" "$app/Contents/MacOS/Hoply"
cp Sources/Hoply/Info.plist "$app/Contents/Info.plist"

# otool lists a universal binary's rpaths once per architecture; /usr/lib/swift is the OS's Swift runtime.
otool -l "$app/Contents/MacOS/Hoply" | awk '$1 == "cmd" { rpath = ($2 == "LC_RPATH") } rpath && $1 == "path" { print $2 }' |
  sort -u | while read -r path; do
    case "$path" in /usr/lib/swift) ;; /*) install_name_tool -delete_rpath "$path" "$app/Contents/MacOS/Hoply" ;; esac
  done

sparkle="$app/Contents/Frameworks/Sparkle.framework"
ditto "$(dirname "$bin")/Sparkle.framework" "$sparkle"
for part in XPCServices Headers PrivateHeaders Modules; do rm -rf "${sparkle:?}/$part" "$sparkle/Versions/B/$part"; done

if [ -n "${HOPLY_FEED_URL:-}${HOPLY_ED_PUBLIC_KEY:-}" ]; then
  [ -n "${HOPLY_FEED_URL:-}" ] && [ -n "${HOPLY_ED_PUBLIC_KEY:-}" ] ||
    { echo "Set both HOPLY_FEED_URL and HOPLY_ED_PUBLIC_KEY, or neither" >&2; exit 1; }
  plutil -replace SUFeedURL -string "$HOPLY_FEED_URL" "$app/Contents/Info.plist"
  plutil -replace SUPublicEDKey -string "$HOPLY_ED_PUBLIC_KEY" "$app/Contents/Info.plist"
fi
if [ -n "${HOPLY_VERSION:-}" ]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $HOPLY_VERSION" "$app/Contents/Info.plist"
fi
if [ -n "${HOPLY_BUILD:-}" ]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $HOPLY_BUILD" "$app/Contents/Info.plist"
fi

# Hoply.icon (Icon Composer) → Assets.car (Liquid Glass) + Hoply.icns; actool ships with Xcode.
if xcrun --find actool >/dev/null 2>&1; then
  xcrun actool Sources/Hoply/Hoply.icon --compile "$app/Contents/Resources" --platform macosx \
    --minimum-deployment-target 14.0 --app-icon Hoply \
    --output-partial-info-plist "$(mktemp -t hoply-icon)" --output-format human-readable-text >/dev/null
else
  echo "Hoply: actool not found (needs Xcode), building without an app icon" >&2
fi

sign() {
  if [ "${HOPLY_HARDENED:-0}" = 1 ]; then
    codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$1" >&2
  else
    codesign --force --timestamp=none --sign "$SIGN_IDENTITY" "$1" >&2
  fi
}

sign "$sparkle/Versions/B/Autoupdate"
sign "$sparkle/Versions/B/Updater.app"
sign "$sparkle"
sign "$app"
echo "$app"
