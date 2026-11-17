#!/usr/bin/env bash
set -euo pipefail

[ $# -eq 3 ] || [ $# -eq 4 ] ||
  { echo "Usage: scripts/profile-entitlements.sh <profile.provisionprofile> <iCloud container> <bundle id> [Production|Development]" >&2; exit 2; }
profile="$1"
container="$2"
bundle="$3"
environment="${4:-}"
case "$environment" in "" | Production | Development) ;; *) echo "Unknown iCloud environment: $environment" >&2; exit 2 ;; esac
pb=/usr/libexec/PlistBuddy

work="$(mktemp -d -t hoply-profile)"
trap 'rm -rf "$work"' EXIT
decoded="$work/profile.plist"
out="$work/entitlements.plist"

fail() { echo "$profile: $*" >&2; exit 1; }

security cms -D -i "$profile" -o "$decoded" 2>/dev/null || fail "not a provisioning profile"

get() { "$pb" -c "Print :$1" "$decoded" 2>/dev/null; }

values() {
  local key="$1" value i=0
  value="$(get "$key")" || return 0
  case "$value" in
    "Array {"*)
      while value="$(get "$key:$i")"; do
        echo "$value"
        i=$((i + 1))
      done
      ;;
    *) echo "$value" ;;
  esac
}

matches() {
  local wanted="$1" value
  while read -r value; do
    case "$value" in
      "$wanted") return 0 ;;
      *\*) case "$wanted" in "${value%\*}"*) return 0 ;; esac ;;
    esac
  done
  return 1
}

team="$(get Entitlements:com.apple.developer.team-identifier)" || fail "no com.apple.developer.team-identifier"
application="$(get Entitlements:com.apple.application-identifier)" || fail "no com.apple.application-identifier"
matches "$team.$bundle" <<<"$application" || fail "made for $application, not $team.$bundle"
matches "$container" <<<"$(values Entitlements:com.apple.developer.icloud-container-identifiers)" ||
  fail "no iCloud container $container (com.apple.developer.icloud-container-identifiers)"
matches CloudKit <<<"$(values Entitlements:com.apple.developer.icloud-services)" ||
  fail "no CloudKit in com.apple.developer.icloud-services"

if [ -z "$environment" ] && [ "$(get ProvisionsAllDevices || true)" = true ]; then
  environment=Production
elif [ -z "$environment" ]; then
  environment=Development
fi
matches "$environment" <<<"$(values Entitlements:com.apple.developer.icloud-container-environment)" ||
  fail "no $environment in com.apple.developer.icloud-container-environment"
aps="$(get Entitlements:com.apple.developer.aps-environment || true)"

printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' \
  '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
  '<plist version="1.0">' '<dict/>' '</plist>' > "$out"
add() { "$pb" -c "Add :$1" "$out" >/dev/null; }
add "com.apple.application-identifier string $team.$bundle"
add "com.apple.developer.team-identifier string $team"
add "com.apple.developer.icloud-container-identifiers array"
add "com.apple.developer.icloud-container-identifiers:0 string $container"
add "com.apple.developer.icloud-services array"
add "com.apple.developer.icloud-services:0 string CloudKit"
add "com.apple.developer.icloud-container-environment string $environment"
[ -z "$aps" ] || add "com.apple.developer.aps-environment string $aps"
plutil -lint -s "$out"
cat "$out"
