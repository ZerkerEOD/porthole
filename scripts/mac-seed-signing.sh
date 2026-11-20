#!/usr/bin/env bash
# One-time iOS signing seed on the Mac mini, driven from this workstation so the secrets
# come straight out of sops and never rest on the Mac. Run from the repository root.
#   scripts/mac-seed-signing.sh <ssh-host> [checkout-dir]
# On the Mac it: ensures ~/.ssh/porthole_certs_deploy exists (prints the public half if it
# had to create it; add that as a write deploy key on ZerkerEOD/porthole-certs, then rerun),
# clones or updates the Porthole checkout, installs the fastlane bundle and runs
# `fastlane bootstrap_signing`, which creates the Apple Distribution certificate and the
# App Store profile and stores them encrypted in porthole-certs.
#
# Secrets travel over stdin into ONE ssh session whose cleanup trap is armed before anything
# is written; they live in a mktemp dir for the length of that session only. The script
# never touches ~/.zshenv, ~/.zprofile, ~/.ssh/config, authorized_keys, ~/flutter or any
# other lane's files on the Mac.
set -euo pipefail
HOST="${1:?ssh host for the Mac mini}"
DIR="${2:-ph-build/porthole}"
SOPS_DIR="$HOME/.config/sops"
get() { (cd "$SOPS_DIR" && sops -d --extract "[\"$1\"][\"value\"]" zerkersec.yaml); }
REPO_URL="${PORTHOLE_REPO_URL:-https://github.com/ZerkerEOD/porthole.git}"
REMOTE_SCRIPT='.porthole-seed.sh'

echo "== deploy key on $HOST"
if ! ssh "$HOST" 'test -f ~/.ssh/porthole_certs_deploy'; then
  ssh "$HOST" 'ssh-keygen -t ed25519 -N "" -C porthole-certs-deploy -f ~/.ssh/porthole_certs_deploy >/dev/null && cat ~/.ssh/porthole_certs_deploy.pub'
  echo "New key printed above. Add it to github.com/ZerkerEOD/porthole-certs (Settings, Deploy keys, allow write), then rerun." >&2
  exit 3
fi
ssh "$HOST" 'GIT_SSH_COMMAND="ssh -i $HOME/.ssh/porthole_certs_deploy -o IdentitiesOnly=yes" git ls-remote git@github.com:ZerkerEOD/porthole-certs.git >/dev/null' \
  || { echo "porthole-certs not reachable with the deploy key; add the public key with write access first." >&2; exit 3; }

echo "== remote script (no secrets) to the Mac"
ssh "$HOST" "umask 077; cat > ~/$REMOTE_SCRIPT" <<'REMOTE'
set -euo pipefail
# Cleanup is armed before any secret exists: the temp dir and this script go on every exit.
TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP"; rm -f "$HOME/.porthole-seed.sh"; }
trap cleanup EXIT
# stdin: KEY=value lines, a line __P8__, then the App Store Connect .p8 body.
awk -v d="$TMP" '/^__P8__$/ { f = 1; next } f { print > (d "/asc.p8"); next } { print > (d "/seed.env") }'
chmod 600 "$TMP/seed.env" "$TMP/asc.p8"
export PATH="$HOME/flutter/bin:$HOME/.local/share/gem/ruby/4.0.0/bin:/opt/homebrew/opt/ruby/bin:/opt/homebrew/bin:$PATH"
export LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8 CI=true FASTLANE_SKIP_UPDATE_CHECK=1 FASTLANE_DISABLE_COLORS=1
export GIT_SSH_COMMAND="ssh -i $HOME/.ssh/porthole_certs_deploy -o IdentitiesOnly=yes"
set -a; . "$TMP/seed.env"; set +a
export ASC_API_KEY_PATH="$TMP/asc.p8"
mkdir -p "$(dirname "$HOME/$DIR")"
if [ -d "$HOME/$DIR/.git" ]; then git -C "$HOME/$DIR" fetch -q origin && git -C "$HOME/$DIR" checkout -q main && git -C "$HOME/$DIR" pull -q --ff-only
else git clone -q "$REPO_URL" "$HOME/$DIR"; fi
cd "$HOME/$DIR/app"
xcodebuild -version | head -1
flutter --version | head -1
flutter pub get >/dev/null
cd ios
bundle config set --local path vendor/bundle >/dev/null
bundle install --quiet
bundle exec fastlane bootstrap_signing
echo "seed complete"
REMOTE

echo "== seed session (secrets over stdin, removed on exit)"
{
  printf 'MATCH_PASSWORD=%s\n' "$(get PORTHOLE_MATCH_PASSWORD)"
  printf 'ASC_KEY_ID=%s\n' "$(get PORTHOLE_ASC_KEY_ID)"
  printf 'ASC_ISSUER_ID=%s\n' "$(get PORTHOLE_ASC_ISSUER_ID)"
  printf 'FASTLANE_TEAM_ID=%s\n' "$(get PORTHOLE_APPLE_TEAM_ID)"
  printf '__P8__\n'
  get PORTHOLE_ASC_API_KEY_P8
} | ssh "$HOST" "DIR='$DIR' REPO_URL='$REPO_URL' bash ~/$REMOTE_SCRIPT"
