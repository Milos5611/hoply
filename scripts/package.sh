#!/usr/bin/env bash
# Usage: scripts/package.sh
#   Universal release build → build/Hoply-<version>.dmg. Prints the DMG's path on stdout.
#   With a Developer ID identity it is signed with the hardened runtime; with a notary key as well it is
#   notarized and stapled, so it opens on any Mac without a Gatekeeper warning. Without either it is ad-hoc
#   signed, which only proves the build: other Macs block it.
# Env: HOPLY_SIGN_IDENTITY  "Developer ID Application: <name> (<team id>)"; unset = ad-hoc
#      NOTARY_KEY_PATH, NOTARY_KEY_ID, NOTARY_ISSUER_ID  App Store Connect API key (.p8) for notarytool
#      HOPLY_VERSION  default: CFBundleShortVersionString in Sources/Hoply/Info.plist
#      HOPLY_BUILD    default: the commit count
set -euo pipefail
cd "$(dirname "$0")/.."

identity="${HOPLY_SIGN_IDENTITY:--}"
version="${HOPLY_VERSION:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Sources/Hoply/Info.plist)}"
build="${HOPLY_BUILD:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
notarize=0
if [ -n "${NOTARY_KEY_PATH:-}" ]; then
  [ "$identity" != "-" ] || { echo "Notarization needs a Developer ID identity (HOPLY_SIGN_IDENTITY)" >&2; exit 1; }
  : "${NOTARY_KEY_ID:?set NOTARY_KEY_ID}" "${NOTARY_ISSUER_ID:?set NOTARY_ISSUER_ID}"
  notarize=1
fi
hardened=0
[ "$identity" != "-" ] && hardened=1

app="$(HOPLY_SIGN_IDENTITY="$identity" HOPLY_HARDENED=$hardened HOPLY_UNIVERSAL=1 \
       HOPLY_VERSION="$version" HOPLY_BUILD="$build" scripts/build-app.sh)"
codesign --verify --strict --verbose=1 "$app" >&2

stage="$(mktemp -d -t hoply-dmg)"
ditto "$app" "$stage/Hoply.app"
ln -s /Applications "$stage/Applications"
dmg="build/Hoply-$version.dmg"
hdiutil create -volname "Hoply $version" -srcfolder "$stage" -format UDZO -ov "$dmg" >&2
[ "$identity" = "-" ] || codesign --force --timestamp --sign "$identity" "$dmg" >&2

if [ "$notarize" = 1 ]; then
  auth=(--key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID")
  result="$(xcrun notarytool submit "$dmg" "${auth[@]}" --wait --timeout 30m --output-format json)"
  status="$(plutil -extract status raw - <<<"$result")"
  if [ "$status" != "Accepted" ]; then
    echo "Notarization: $status" >&2
    xcrun notarytool log "$(plutil -extract id raw - <<<"$result")" "${auth[@]}" >&2 || true
    exit 1
  fi
  xcrun stapler staple "$dmg" >&2
  spctl --assess --type open --context context:primary-signature --verbose "$dmg" >&2
fi
echo "Hoply $version ($build): $dmg, $([ "$notarize" = 1 ] && echo "notarized" || \
  ([ "$identity" = "-" ] && echo "ad-hoc signed, not notarized" || echo "signed, not notarized"))" >&2
echo "$dmg"
