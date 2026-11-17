#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

TEAM=24M9Y6KW2S
BUNDLE=com.coolcraftcoders.hoply.appstore
CONTAINER=iCloud.com.coolcraftcoders.hoply
PLIST=Sources/Hoply/Info-AppStore.plist
SANDBOX=scripts/store.entitlements
OUT=build/store
APP="$OUT/Hoply.app"
PKG="$OUT/Hoply.pkg"

usage() {
  echo "Usage: scripts/build-store.sh [--adhoc | --dev]" >&2
  exit 2
}

mode=store
case "${1:-}" in
  "") ;;
  --adhoc) mode=adhoc ;;
  --dev) mode=dev ;;
  *) usage ;;
esac
[ $# -le 1 ] || usage

fail() {
  echo "build-store: $*" >&2
  exit 1
}

version="${HOPLY_VERSION:-$(git tag --list 'v*' --sort=-v:refname 2>/dev/null | head -n 1 | sed 's/^v//')}"
[ -n "$version" ] || version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
build="${HOPLY_BUILD:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"

profile=""
case "$mode" in
  dev) profile="${HOPLY_STORE_DEV_PROFILE:-}"; [ -n "$profile" ] || fail "set HOPLY_STORE_DEV_PROFILE" ;;
  store)
    profile="${HOPLY_STORE_PROFILE:-}"
    [ -n "$profile" ] || fail "set HOPLY_STORE_PROFILE"
    [ -n "${HOPLY_STORE_P12:-}" ] || fail "set HOPLY_STORE_P12 (Apple Distribution)"
    [ -n "${HOPLY_INSTALLER_P12:-}" ] || fail "set HOPLY_INSTALLER_P12 (3rd Party Mac Developer Installer)"
    [ -n "${HOPLY_STORE_P12_PASSWORD:-}" ] || fail "set HOPLY_STORE_P12_PASSWORD"
    ;;
esac
[ -z "$profile" ] || [ -f "$profile" ] || fail "no such profile: $profile"

work="$(mktemp -d -t hoply-store)"
keychain=""
cleanup() {
  [ -z "$keychain" ] || security delete-keychain "$keychain" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT

import_p12() {
  local p12="$1" password="$2"
  [ -f "$p12" ] || fail "no such file: $p12"
  if [ -z "$keychain" ]; then
    keychain="$work/signing.keychain-db"
    keychain_password="$(uuidgen)"
    security create-keychain -p "$keychain_password" "$keychain"
    security set-keychain-settings -lut 3600 "$keychain"
    security unlock-keychain -p "$keychain_password" "$keychain"
  fi
  if ! security import "$p12" -k "$keychain" -P "$password" -T /usr/bin/codesign -T /usr/bin/productbuild \
      >/dev/null 2>&1; then
    local legacy="$work/legacy-$(basename "$p12")"
    export HOPLY_P12_SECRET="$password"
    /usr/bin/openssl pkcs12 -export -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 \
      -inkey <(/usr/bin/openssl pkcs12 -in "$p12" -nocerts -nodes -passin env:HOPLY_P12_SECRET 2>/dev/null) \
      -in <(/usr/bin/openssl pkcs12 -in "$p12" -nokeys -clcerts -passin env:HOPLY_P12_SECRET 2>/dev/null) \
      -out "$legacy" -passout env:HOPLY_P12_SECRET || fail "$p12: can't read it (wrong password?)"
    unset HOPLY_P12_SECRET
    security import "$legacy" -k "$keychain" -P "$password" -T /usr/bin/codesign -T /usr/bin/productbuild >/dev/null
    rm -f "$legacy"
  fi
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$keychain_password" "$keychain" >/dev/null
}

profile_certificates() {
  local decoded="$1" i=0 der
  while der="$(plutil -extract "DeveloperCertificates.$i" raw -o - "$decoded" 2>/dev/null)"; do
    printf '%s' "$der" | base64 -D | /usr/bin/openssl x509 -inform DER -noout -fingerprint -sha1 | sed 's/.*=//; s/://g'
    i=$((i + 1))
  done
}

identity_from_profile() {
  local decoded="$1" allowed hash
  shift
  allowed="$(profile_certificates "$decoded")"
  security find-identity -v -p codesigning "$@" | while read -r _ hash _; do
    [ "${#hash}" -eq 40 ] || continue
    case "$allowed" in *"$hash"*) echo "$hash"; break ;; esac
  done
}

entitlements="$SANDBOX"
identity=-
keychain_args=()
if [ -n "$profile" ]; then
  decoded="$work/profile.plist"
  security cms -D -i "$profile" -o "$decoded" 2>/dev/null || fail "$profile is not a provisioning profile"
  [ "$(plutil -extract TeamIdentifier.0 raw -o - "$decoded")" = "$TEAM" ] || fail "$profile is not team $TEAM's"
  entitlements="$work/entitlements.plist"
  environment=Production
  [ "$mode" = dev ] && environment=Development
  scripts/profile-entitlements.sh "$profile" "$CONTAINER" "$BUNDLE" "$environment" > "$entitlements"
  /usr/libexec/PlistBuddy -c "Merge $SANDBOX" "$entitlements" >/dev/null
  plutil -lint -s "$entitlements"

  if [ "$mode" = store ]; then
    import_p12 "$HOPLY_STORE_P12" "$HOPLY_STORE_P12_PASSWORD"
    import_p12 "$HOPLY_INSTALLER_P12" "${HOPLY_INSTALLER_P12_PASSWORD:-$HOPLY_STORE_P12_PASSWORD}"
  elif [ -n "${HOPLY_STORE_DEV_P12:-}" ]; then
    import_p12 "$HOPLY_STORE_DEV_P12" "${HOPLY_STORE_DEV_P12_PASSWORD:-}"
  fi
  [ -z "$keychain" ] || keychain_args=(--keychain "$keychain")
  identity="$(identity_from_profile "$decoded" ${keychain:+"$keychain"})"
  [ -n "$identity" ] || fail "no valid signing identity of team $TEAM matches $profile"
fi

scratch=.build/appstore
traits=(--disable-default-traits --traits AppStore --arch arm64 --arch x86_64 --scratch-path "$scratch")
swift build -c release --product Hoply "${traits[@]}" >&2
bin="$(swift build -c release --show-bin-path "${traits[@]}")/Hoply"
if otool -L "$bin" | grep -i sparkle >/dev/null; then fail "the store binary links Sparkle"; fi

rm -rf "$APP" "$PKG"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$bin" "$APP/Contents/MacOS/Hoply"
cp "$PLIST" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" -c "Set :CFBundleVersion $build" \
  "$APP/Contents/Info.plist"
[ -z "$profile" ] || cp "$profile" "$APP/Contents/embedded.provisionprofile"

otool -l "$APP/Contents/MacOS/Hoply" | awk '$1 == "cmd" { rpath = ($2 == "LC_RPATH") } rpath && $1 == "path" { print $2 }' |
  sort -u | while read -r path; do
    case "$path" in /usr/lib/swift) ;; /*) install_name_tool -delete_rpath "$path" "$APP/Contents/MacOS/Hoply" ;; esac
  done

if xcrun --find actool >/dev/null 2>&1; then
  xcrun actool Sources/Hoply/Hoply.icon --compile "$APP/Contents/Resources" --platform macosx \
    --minimum-deployment-target 14.0 --app-icon Hoply \
    --output-partial-info-plist "$work/icon.plist" --output-format human-readable-text >/dev/null
else
  [ "$mode" = adhoc ] || fail "actool not found: the store needs the app icon (install Xcode)"
  echo "build-store: actool not found (needs Xcode), building without an app icon" >&2
fi

xattr -cr "$APP"
codesign --force --timestamp=none --sign "$identity" ${keychain_args[@]+"${keychain_args[@]}"} \
  --entitlements "$entitlements" "$APP" >&2
codesign --verify --strict --verbose=1 "$APP" >&2
codesign --display --entitlements - "$APP" >&2

if [ "$mode" != store ]; then
  echo "Hoply $version ($build), $mode: $APP" >&2
  echo "$APP"
  exit 0
fi

installer="$(security find-identity -v -p basic "$keychain" |
  sed -n "s/.*\"\(3rd Party Mac Developer Installer: .* ($TEAM)\)\"$/\1/p" | head -n 1)"
[ -n "$installer" ] || fail "HOPLY_INSTALLER_P12 holds no 3rd Party Mac Developer Installer identity of team $TEAM"
productbuild --sign "$installer" --keychain "$keychain" --component "$APP" /Applications "$PKG" >&2
pkgutil --check-signature "$PKG" >&2
echo "Hoply $version ($build), Mac App Store: $PKG (not uploaded)" >&2
echo "$PKG"
