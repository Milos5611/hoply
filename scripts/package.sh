#!/usr/bin/env bash
# Usage: scripts/package.sh
#   Universal release build → build/Hoply-<version>.dmg. Prints the DMG's path on stdout.
#   With a Developer ID identity it is signed with the hardened runtime; with a notary key as well it is
#   notarized and stapled, so it opens on any Mac without a Gatekeeper warning. Without either it is ad-hoc
#   signed, which only proves the build: other Macs block it.
#   With SPARKLE_PUBLIC_KEY the app checks for updates, and build/appcast.xml (one item: this DMG, EdDSA signed)
#   is written next to it; publish both as assets of the release v<version> on HOPLY_REPO (release.yml does).
# Env: HOPLY_SIGN_IDENTITY  "Developer ID Application: <name> (<team id>)"; unset = ad-hoc
#      NOTARY_KEY_PATH, NOTARY_KEY_ID, NOTARY_ISSUER_ID  App Store Connect API key (.p8) for notarytool
#      HOPLY_VERSION  default: CFBundleShortVersionString in Sources/Hoply/Info.plist
#      HOPLY_BUILD    default: the commit count
#      SPARKLE_PUBLIC_KEY   generate_keys' public key; unset = no updates
#      SPARKLE_PRIVATE_KEY  generate_keys -x output; unset = the login Keychain item (account SPARKLE_ACCOUNT, default hoply)
#      HOPLY_REPO           public owner/repo whose releases host the DMG and appcast; default Milos5611/homebrew-hoply
#      HOPLY_FEED_URL       SUFeedURL; default https://hoply.dev/appcast.xml (redirects to the latest release's appcast)
#      HOPLY_DOWNLOAD_URL   default: https://github.com/<repo>/releases/download/v<version>/Hoply-<version>.dmg
#      HOPLY_RELEASE_NOTES  a Markdown file shown in the update window
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

feed=""
rm -f build/appcast.xml
if [ -n "${SPARKLE_PUBLIC_KEY:-}" ]; then
  repo="${HOPLY_REPO:-Milos5611/homebrew-hoply}"
  feed="${HOPLY_FEED_URL:-https://hoply.dev/appcast.xml}"
  download="${HOPLY_DOWNLOAD_URL:-https://github.com/$repo/releases/download/v$version/Hoply-$version.dmg}"
  case "$feed $download" in
    https://*" https://"*) ;;
    *) echo "The feed and download URLs must be https: $feed $download" >&2; exit 1 ;;
  esac
  [ -z "${HOPLY_RELEASE_NOTES:-}" ] || [ -f "$HOPLY_RELEASE_NOTES" ] ||
    { echo "HOPLY_RELEASE_NOTES: no such file: $HOPLY_RELEASE_NOTES" >&2; exit 1; }
fi

app="$(HOPLY_SIGN_IDENTITY="$identity" HOPLY_HARDENED=$hardened HOPLY_UNIVERSAL=1 \
       HOPLY_VERSION="$version" HOPLY_BUILD="$build" \
       HOPLY_FEED_URL="$feed" HOPLY_ED_PUBLIC_KEY="${SPARKLE_PUBLIC_KEY:-}" scripts/build-app.sh)"
codesign --verify --strict --deep --verbose=1 "$app" >&2

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
if [ -n "$feed" ]; then
  # After stapling, which rewrites the DMG.
  sign_update=.build/artifacts/sparkle/Sparkle/bin/sign_update
  if [ -n "${SPARKLE_PRIVATE_KEY:-}" ]; then
    signature="$(printf '%s' "$SPARKLE_PRIVATE_KEY" | "$sign_update" --ed-key-file - -p "$dmg")"
  else
    signature="$("$sign_update" --account "${SPARKLE_ACCOUNT:-hoply}" -p "$dmg")"
  fi
  notes=""
  if [ -n "${HOPLY_RELEASE_NOTES:-}" ]; then
    # A CDATA section ends at the first "]]>", so split any inside the notes.
    notes="      <description sparkle:format=\"markdown\"><![CDATA[$(sed 's/]]>/]]]]><![CDATA[>/g' "$HOPLY_RELEASE_NOTES")]]></description>"
  fi
  appcast=build/appcast.xml
  {
    cat <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Hoply</title>
    <item>
      <title>Hoply $version</title>
      <pubDate>$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')</pubDate>
      <sparkle:version>$build</sparkle:version>
      <sparkle:shortVersionString>$version</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$app/Contents/Info.plist")</sparkle:minimumSystemVersion>
XML
    [ -z "$notes" ] || printf '%s\n' "$notes"
    echo "      <sparkle:fullReleaseNotesLink>https://github.com/$repo/releases</sparkle:fullReleaseNotesLink>"
    cat <<XML
      <enclosure url="$(sed 's/&/\&amp;/g; s/"/\&quot;/g; s/</\&lt;/g' <<<"$download")" length="$(stat -f %z "$dmg")" type="application/octet-stream" sparkle:edSignature="$signature"/>
    </item>
  </channel>
</rss>
XML
  } > "$appcast"
  xmllint --noout "$appcast"
  echo "Appcast: $appcast (feed $feed)" >&2
fi

echo "Hoply $version ($build): $dmg, $([ "$notarize" = 1 ] && echo "notarized" || \
  ([ "$identity" = "-" ] && echo "ad-hoc signed, not notarized" || echo "signed, not notarized"))" >&2
echo "$dmg"
