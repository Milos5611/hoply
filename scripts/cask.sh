#!/usr/bin/env bash
# Usage: scripts/cask.sh <version> <sha256>
#   Prints Casks/hoply.rb for the Homebrew tap Milos5611/homebrew-hoply (brew install --cask milos5611/hoply/hoply).
#   The cask downloads from the releases on HOPLY_REPO, default Milos5611/hoply. <sha256> is Hoply-<version>.dmg's.
#   release.yml commits the output to the tap after publishing the release.
set -euo pipefail
cd "$(dirname "$0")/.."

[ $# -eq 2 ] || { echo "Usage: scripts/cask.sh <version> <sha256>" >&2; exit 2; }
version="$1"
sha256="$(tr 'A-F' 'a-f' <<<"$2")"
[[ "$version" =~ ^[0-9]+(\.[0-9]+)*([-+][0-9A-Za-z.]+)?$ ]] || { echo "Not a version: $version" >&2; exit 1; }
[[ "$sha256" =~ ^[0-9a-f]{64}$ ]] || { echo "Not a SHA-256 (64 hex digits): $2" >&2; exit 1; }
repo="${HOPLY_REPO:-Milos5611/hoply}"

info=Sources/Hoply/Info.plist
bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info")"
minimum="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$info")"
case "$minimum" in
  14 | 14.*) macos=sonoma ;;
  15 | 15.*) macos=sequoia ;;
  26 | 26.*) macos=tahoe ;;
  *) echo "LSMinimumSystemVersion $minimum: add its Homebrew symbol (MacOSVersion::SYMBOLS) here" >&2; exit 1 ;;
esac

cat <<RUBY
cask "hoply" do
  version "$version"
  sha256 "$sha256"

  url "https://github.com/$repo/releases/download/v#{version}/Hoply-#{version}.dmg"
  name "Hoply"
  desc "Menu bar hub for AI coding agents and local model servers"
  homepage "https://hoply.dev"

  livecheck do
    url "https://hoply.dev/appcast.xml"
    strategy :sparkle, &:short_version
  end

  auto_updates true
  depends_on macos: :$macos

  app "Hoply.app"

  zap trash: [
    "~/Library/Application Support/Hoply",
    "~/Library/Caches/$bundle_id",
    "~/Library/HTTPStorages/$bundle_id",
    "~/Library/HTTPStorages/$bundle_id.binarycookies",
    "~/Library/Preferences/$bundle_id.plist",
  ]
end
RUBY
