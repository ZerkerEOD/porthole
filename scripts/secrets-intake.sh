#!/usr/bin/env bash
# Interactive intake of the Porthole release secrets into the personal sops store.
#
#   scripts/secrets-intake.sh                        prompt for entries that are not stored yet
#   scripts/secrets-intake.sh NAME [NAME...]         only those entries (offers replace if stored)
#   scripts/secrets-intake.sh --all                  offer every entry again (keep or replace)
#   scripts/secrets-intake.sh --status               print what is stored and what is missing
#   scripts/secrets-intake.sh --list                 print the entry names
# Staging dir: ~/porthole-keys, or PORTHOLE_KEYS=<dir>. It must be outside any git checkout.
#
# Typed values: type or paste, press Enter. Secrets are read with echo off; ids are shown.
# Enter on an empty line skips that entry. Nothing typed ends up in shell history.
#
# File values are picked up from the staging directory (default ~/porthole-keys):
#   asc/AuthKey_<KEYID>.p8      App Store Connect API key   -> PORTHOLE_ASC_API_KEY_P8, PORTHOLE_ASC_KEY_ID
#   apns/AuthKey_<KEYID>.p8     APNs auth key               -> PORTHOLE_APNS_KEY_P8, PORTHOLE_APNS_KEY_ID
#   play/*.json                 Play upload service account -> PORTHOLE_PLAY_SERVICE_ACCOUNT_JSON
#   firebase/*.json             Firebase Admin SDK key      -> PORTHOLE_FCM_SERVICE_ACCOUNT
#   google-services.json        Firebase Android config     -> PORTHOLE_GOOGLE_SERVICES_JSON
#   GoogleService-Info.plist    Firebase iOS config         -> PORTHOLE_GOOGLESERVICE_INFO_PLIST
#
# Store: ~/.config/sops/zerkersec.yaml through ~/.config/sops/put.sh (only `value` is encrypted;
# `_consumers` and `_url` stay readable). Override the file with SOPS_FILE=<name>.yaml.
set -euo pipefail

SOPS_DIR="$HOME/.config/sops"
PUT="$SOPS_DIR/put.sh"
export SOPS_FILE="${SOPS_FILE:-zerkersec.yaml}"
BUNDLE_ID="io.zerkersec.porthole"

ALL=0; STATUS=0; LIST=0; ONLY=()
for a in "$@"; do
  case "$a" in
    --all) ALL=1 ;;
    --status) STATUS=1 ;;
    --list) LIST=1 ;;
    --*) echo "unknown option $a" >&2; exit 2 ;;
    *) ONLY+=("$a") ;;
  esac
done
STAGE="${PORTHOLE_KEYS:-$HOME/porthole-keys}"

# The staging folder must never sit inside a repository.
if [ -d "$STAGE" ] && git -C "$STAGE" rev-parse --show-toplevel >/dev/null 2>&1; then
  echo "refusing: $STAGE is inside a git checkout ($(git -C "$STAGE" rev-parse --show-toplevel)); move it to ~/porthole-keys" >&2
  exit 1
fi

[ -x "$PUT" ] || { echo "missing $PUT" >&2; exit 1; }
command -v sops >/dev/null || { echo "sops is not on PATH" >&2; exit 1; }
command -v jq >/dev/null || { echo "jq is not on PATH" >&2; exit 1; }

# Ordered list: NAME|kind|prompt or staging hint|consumers|url
#   kind: secret (hidden input), id (visible input), file
ENTRIES=(
  "PORTHOLE_APPLE_TEAM_ID|id|Apple Team ID (10 characters, Membership details)|jenkins porthole-apple-team-id, fastlane FASTLANE_TEAM_ID, Firebase APNs upload|https://developer.apple.com/account"
  "PORTHOLE_ASC_API_KEY_P8|file|asc/AuthKey_<KEYID>.p8|jenkins porthole-asc-api-key-p8, Mac seed session (fastlane match + pilot)|https://appstoreconnect.apple.com/access/integrations/api"
  "PORTHOLE_ASC_KEY_ID|id|App Store Connect API Key ID|jenkins porthole-asc-key-id, fastlane ASC_KEY_ID|https://appstoreconnect.apple.com/access/integrations/api"
  "PORTHOLE_ASC_ISSUER_ID|id|App Store Connect Issuer ID (UUID at the top of the API keys page)|jenkins porthole-asc-issuer-id, fastlane ASC_ISSUER_ID|https://appstoreconnect.apple.com/access/integrations/api"
  "PORTHOLE_APNS_KEY_P8|file|apns/AuthKey_<KEYID>.p8|Firebase Cloud Messaging (uploaded once in the Firebase console); kept here as the record|https://developer.apple.com/account/resources/authkeys/list"
  "PORTHOLE_APNS_KEY_ID|id|APNs Key ID|Firebase Cloud Messaging APNs configuration|https://developer.apple.com/account/resources/authkeys/list"
  "PORTHOLE_PLAY_SERVICE_ACCOUNT_JSON|file|play/<service-account>.json|jenkins porthole-play-service-account-json, fastlane upload_to_play_store|https://console.cloud.google.com/iam-admin/serviceaccounts"
  "PORTHOLE_FCM_SERVICE_ACCOUNT|file|firebase/<firebase-adminsdk>.json|relay secret FCM_SERVICE_ACCOUNT (scripts/deploy-relay-hosted.sh secrets)|https://console.firebase.google.com/project/_/settings/serviceaccounts/adminsdk"
  "PORTHOLE_GOOGLE_SERVICES_JSON|file|google-services.json|app/dart_defines/store.json (FB_* values), not a secret but kept with its siblings|https://console.firebase.google.com/project/_/settings/general"
  "PORTHOLE_GOOGLESERVICE_INFO_PLIST|file|GoogleService-Info.plist|app/dart_defines/store.json (FB_* values), not a secret but kept with its siblings|https://console.firebase.google.com/project/_/settings/general"
  "JENKINS_URL|id|Jenkins controller URL (https://...)|scripts/jenkins-credentials.sh|"
  "JENKINS_USER|id|Jenkins username|scripts/jenkins-credentials.sh|"
  "JENKINS_API_TOKEN|secret|Jenkins API token (user menu, Security, API Token)|scripts/jenkins-credentials.sh|"
)

declare -A HAVE
while IFS= read -r k; do HAVE["$k"]=1; done < <(
  cd "$SOPS_DIR" && sops -d --output-type json "$SOPS_FILE" \
    | jq -r 'to_entries[] | select((.value|type)=="object" and (.value.value // "") != "") | .key'
)

stored() { [ -n "${HAVE[$1]:-}" ]; }
known()  { local e; for e in "${ENTRIES[@]}"; do [ "${e%%|*}" = "$1" ] && return 0; done; return 1; }
selected() { # selected NAME -> 0 when this run should visit the entry
  [ ${#ONLY[@]} -eq 0 ] && return 0
  local n; for n in "${ONLY[@]}"; do [ "$n" = "$1" ] && return 0; done; return 1
}
for n in "${ONLY[@]+"${ONLY[@]}"}"; do
  known "$n" || { echo "unknown entry $n (see --list)" >&2; exit 2; }
done
[ ${#ONLY[@]} -gt 0 ] && ALL=1   # naming an entry means: offer to replace it

status() {
  local e name
  printf '%-38s %s\n' "entry" "state"
  for e in "${ENTRIES[@]}"; do
    IFS='|' read -r name _ <<<"$e"
    if stored "$name"; then printf '%-38s stored\n' "$name"; else printf '%-38s MISSING\n' "$name"; fi
  done
}

if [ $STATUS -eq 1 ]; then status; exit 0; fi
if [ $LIST -eq 1 ]; then for e in "${ENTRIES[@]}"; do echo "${e%%|*}"; done; exit 0; fi

# want NAME -> 0 when the entry should be prompted for
want() {
  if stored "$1"; then
    if [ $ALL -eq 1 ]; then
      local a; read -r -p "  $1 is already stored. Replace it? [y/N] " a
      [[ "$a" =~ ^[Yy] ]] && return 0
    else
      echo "  $1: already stored, keeping"
    fi
    return 1
  fi
  return 0
}

store_value() { # store_value NAME note url VALUE (value goes over stdin, never argv)
  printf %s "$4" | "$PUT" "$1" "$2" "$3" - >/dev/null
  HAVE["$1"]=1
}

ask() { # ask NAME kind prompt note url [default]
  local name="$1" kind="$2" prompt="$3" note="$4" url="$5" def="${6:-}" val
  want "$name" || return 0
  if [ "$kind" = secret ]; then
    read -r -s -p "  $prompt (hidden, Enter to store, empty to skip): " val; echo
  elif [ -n "$def" ]; then
    read -r -p "  $prompt [$def]: " val; val="${val:-$def}"
  else
    read -r -p "  $prompt (Enter to store, empty to skip): " val
  fi
  val="${val//[$'\r\n']/}"
  if [ -z "$val" ]; then echo "  skipped $name"; return 0; fi
  store_value "$name" "$note" "$url" "$val"
  echo "  stored $name ($(printf %s "$val" | wc -c) bytes)"
}

find_one() { # find_one dir glob -> path on stdout, empty if none; warns on several
  local d="$1" g="$2" m=()
  [ -d "$d" ] || { echo ""; return 0; }
  shopt -s nullglob; m=("$d"/$g); shopt -u nullglob
  case ${#m[@]} in
    0) echo "" ;;
    1) echo "${m[0]}" ;;
    *) echo "  several files match $g in $d; leave only one: ${m[*]}" >&2; echo "" ;;
  esac
}

import_file() { # import_file NAME hint note url path
  local name="$1" hint="$2" note="$3" url="$4" path="$5" a
  want "$name" || return 0
  if [ -z "$path" ]; then echo "  $name: nothing at $STAGE/$hint, skipped"; return 0; fi
  read -r -p "  import $path as $name? [Y/n] " a
  if [[ "$a" =~ ^[Nn] ]]; then echo "  skipped $name"; return 0; fi
  "$PUT" "$name" "$note" "$url" "@$path" >/dev/null
  HAVE["$name"]=1
  echo "  stored $name ($(wc -c <"$path") bytes)"
}

# Light sanity checks on staged files; they only warn.
check_json_sa() { jq -e '.type=="service_account" and (.client_email|length>0)' "$1" >/dev/null 2>&1 || echo "  warning: $1 does not look like a service-account key" >&2; }
check_gs_json() { jq -e --arg b "$BUNDLE_ID" '[.client[].client_info.android_client_info.package_name]|index($b)!=null' "$1" >/dev/null 2>&1 || echo "  warning: $1 has no client for $BUNDLE_ID" >&2; }
check_plist()   { grep -q "<string>$BUNDLE_ID</string>" "$1" 2>/dev/null || echo "  warning: $1 does not mention $BUNDLE_ID" >&2; }
key_id_from()   { local b; b="$(basename "$1" .p8)"; b="${b#AuthKey_}"; [[ "$b" =~ ^[A-Z0-9]{10}$ ]] && echo "$b" || echo ""; }

echo "Porthole secrets intake -> $SOPS_DIR/$SOPS_FILE   (staging: $STAGE)"
echo

for e in "${ENTRIES[@]}"; do
  IFS='|' read -r name kind hint note url <<<"$e"
  selected "$name" || continue
  case "$kind" in
    secret|id)
      def=""
      case "$name" in
        PORTHOLE_ASC_KEY_ID)  p="$(find_one "$STAGE/asc" 'AuthKey_*.p8')";  [ -n "$p" ] && def="$(key_id_from "$p")" ;;
        PORTHOLE_APNS_KEY_ID) p="$(find_one "$STAGE/apns" 'AuthKey_*.p8')"; [ -n "$p" ] && def="$(key_id_from "$p")" ;;
      esac
      ask "$name" "$kind" "$hint" "$note" "$url" "$def"
      ;;
    file)
      case "$name" in
        PORTHOLE_ASC_API_KEY_P8)            p="$(find_one "$STAGE/asc" 'AuthKey_*.p8')" ;;
        PORTHOLE_APNS_KEY_P8)               p="$(find_one "$STAGE/apns" 'AuthKey_*.p8')" ;;
        PORTHOLE_PLAY_SERVICE_ACCOUNT_JSON) p="$(find_one "$STAGE/play" '*.json')";     [ -n "$p" ] && check_json_sa "$p" ;;
        PORTHOLE_FCM_SERVICE_ACCOUNT)       p="$(find_one "$STAGE/firebase" '*.json')"; [ -n "$p" ] && check_json_sa "$p" ;;
        PORTHOLE_GOOGLE_SERVICES_JSON)      p="$(find_one "$STAGE" 'google-services.json')";     [ -n "$p" ] && check_gs_json "$p" ;;
        PORTHOLE_GOOGLESERVICE_INFO_PLIST)  p="$(find_one "$STAGE" 'GoogleService-Info.plist')"; [ -n "$p" ] && check_plist "$p" ;;
        *) p="" ;;
      esac
      import_file "$name" "$hint" "$note" "$url" "$p"
      ;;
  esac
done

echo
status
echo
missing=0
for e in "${ENTRIES[@]}"; do IFS='|' read -r name _ <<<"$e"; stored "$name" || missing=1; done
if [ $missing -eq 0 ]; then
  echo "Everything is stored. Once a build has used them, remove the staging copies:"
  echo "  find '$STAGE' -type f -exec shred -u {} + && rm -r '$STAGE'"
else
  echo "Run again after adding the missing items; stored entries are kept unless you pass --all."
fi
