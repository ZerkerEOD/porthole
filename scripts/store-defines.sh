#!/usr/bin/env bash
# Writes app/dart_defines/store.json (Firebase client ids for --dart-define-from-file) from the
# personal sops store. The file is gitignored: the ids are not credentials, but they are
# key-shaped and belong to the project, so they never sit in the public repository.
#   scripts/store-defines.sh          write the file
#   scripts/store-defines.sh --rm     remove it
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=app/dart_defines/store.json
if [ "${1:-}" = "--rm" ]; then rm -f "$OUT"; echo "removed $OUT"; exit 0; fi
(cd "$HOME/.config/sops" && sops -d --extract '["PORTHOLE_STORE_DEFINES_JSON"]["value"]' zerkersec.yaml) > "$OUT"
jq -e 'has("FB_API_KEY") and has("FB_IOS_APP_ID")' "$OUT" >/dev/null
echo "wrote $OUT ($(jq -r 'keys|length' "$OUT") keys)"
