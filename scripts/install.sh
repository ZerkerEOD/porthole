#!/bin/sh
# Porthole daemon installer: downloads the latest release for this OS/arch,
# verifies its checksum, and runs `porthole install` (binary in ~/.local/bin,
# user service, Claude Code / Codex hooks).
#   curl -fsSL https://raw.githubusercontent.com/ZerkerEOD/porthole/main/scripts/install.sh | sh
# Env: PORTHOLE_VERSION=v1.2.3 pins a release; PORTHOLE_NO_SERVICE=1 skips the
# service; PORTHOLE_NO_HOOKS=1 skips the hooks. Never run this as root.
set -eu
REPO=ZerkerEOD/porthole
if [ "$(id -u)" = 0 ]; then echo "run as the user who runs claude/codex, not root" >&2; exit 1; fi
case "$(uname -s)" in Linux) os=linux ;; Darwin) os=darwin ;; *) echo "unsupported OS: $(uname -s)" >&2; exit 1 ;; esac
case "$(uname -m)" in x86_64|amd64) arch=amd64 ;; aarch64|arm64) arch=arm64 ;; *) echo "unsupported arch: $(uname -m)" >&2; exit 1 ;; esac
command -v curl >/dev/null || { echo "curl is required" >&2; exit 1; }
command -v tar >/dev/null || { echo "tar is required" >&2; exit 1; }
if [ -n "${PORTHOLE_VERSION:-}" ]; then
  tag=$PORTHOLE_VERSION
else
  tag=$(curl -fsSL -H 'Accept: application/vnd.github+json' "https://api.github.com/repos/$REPO/releases/latest" | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -1)
  [ -n "$tag" ] || { echo "no published release found; build from source: go build ./cmd/porthole in daemon/" >&2; exit 1; }
fi
ver=${tag#v}
file="porthole_${ver}_${os}_${arch}.tar.gz"
base="https://github.com/$REPO/releases/download/$tag"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
echo "downloading $file ($tag)"
curl -fsSL -o "$tmp/$file" "$base/$file"
curl -fsSL -o "$tmp/checksums.txt" "$base/checksums.txt"
expected=$(grep " $file\$" "$tmp/checksums.txt" | cut -d' ' -f1)
[ -n "$expected" ] || { echo "checksum for $file missing from checksums.txt" >&2; exit 1; }
if command -v sha256sum >/dev/null; then actual=$(sha256sum "$tmp/$file" | cut -d' ' -f1); else actual=$(shasum -a 256 "$tmp/$file" | cut -d' ' -f1); fi
[ "$actual" = "$expected" ] || { echo "checksum mismatch for $file" >&2; exit 1; }
tar -xzf "$tmp/$file" -C "$tmp" porthole
flags=""
[ "${PORTHOLE_NO_SERVICE:-}" = 1 ] && flags="$flags --no-service"
[ "${PORTHOLE_NO_HOOKS:-}" = 1 ] && flags="$flags --no-hooks"
# shellcheck disable=SC2086
"$tmp/porthole" install $flags
case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) echo "note: add $HOME/.local/bin to your PATH to run porthole by name" ;; esac
