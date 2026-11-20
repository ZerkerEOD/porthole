#!/usr/bin/env bash
# Deploys relay/ as the project's hosted relay (relay.zerkersec.io) and sets its
# secrets from the personal sops store. Run from the repository root.
#   scripts/deploy-relay-hosted.sh            deploy only
#   scripts/deploy-relay-hosted.sh secrets    deploy, then put every secret
set -euo pipefail
cd "$(dirname "$0")/../relay"
SOPS_DIR="$HOME/.config/sops"
get() { (cd "$SOPS_DIR" && sops -d --extract "[\"$1\"][\"value\"]" zerkersec.yaml); }
export CLOUDFLARE_API_TOKEN CLOUDFLARE_ACCOUNT_ID
CLOUDFLARE_API_TOKEN="$(get CLOUDFLARE_TOKEN_ZS_DEPLOY)"
CLOUDFLARE_ACCOUNT_ID="$(get CLOUDFLARE_ACCOUNT_ID)"
npx wrangler deploy
if [ "${1:-}" = "secrets" ]; then
  get PORTHOLE_RELAY_GRANT_SIGNING_KEY | npx wrangler secret put GRANT_SIGNING_KEY
  get ENTITLEMENT_SECRET | npx wrangler secret put ENTITLEMENT_SECRET
  if (cd "$SOPS_DIR" && sops -d zerkersec.yaml | grep -q '^PORTHOLE_FCM_SERVICE_ACCOUNT:'); then
    get PORTHOLE_FCM_SERVICE_ACCOUNT | npx wrangler secret put FCM_SERVICE_ACCOUNT
  else
    echo "PORTHOLE_FCM_SERVICE_ACCOUNT is not in sops yet; push stays 503 until it is set." >&2
  fi
fi
