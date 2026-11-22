# Porthole

Follow and control Claude Code and Codex sessions from a phone. A daemon on
the machine where the agents run reads their transcript files and drives their
tmux sessions; the app connects to it over your LAN or VPN.

Documentation: <https://zerkersec.io/porthole/docs/>

## Install

On the computer that runs Claude Code or Codex (Linux, macOS, or Windows
through WSL2):

```sh
curl -fsSL https://raw.githubusercontent.com/ZerkerEOD/porthole/main/scripts/install.sh | sh
```

The script fetches the latest release for your platform, verifies the
checksum and runs `porthole install`, which copies the binary to
`~/.local/bin`, sets up a user service (systemd or launchd), installs the
Claude Code hooks and the Codex notify handler, and checks the environment.
To build from source instead, run `go build -o ~/.local/bin/porthole ./cmd/porthole`
in `daemon/`, then `porthole install`.

Then:

```sh
cd ~/code/my-project && porthole add   # optional; pairing works without it
porthole pair                          # scan the QR with the app
```

## App

`app/` is a Flutter project for Android and iOS, with a Linux desktop target
for development. Beta links are in the
[docs](https://zerkersec.io/porthole/docs/latest/getting-started/app/). To build
it with your own Firebase project and relay, see
[Build the app yourself](https://zerkersec.io/porthole/docs/latest/self-host/app/).

Notifications while the app is closed go through a push relay. Paste a relay
URL into Settings → Push relay. Run your own
([docs](https://zerkersec.io/porthole/docs/latest/self-host/relay/)) or use the
hosted one, available to supporters at
[zerkersec.io/supporter](https://zerkersec.io/supporter).

## Security

The daemon binds only loopback, private and VPN addresses. Connections use
TLS 1.3 with the certificate pinned by the app at pairing. Each phone holds a
device token that the daemon stores hashed. Pairing codes are single use.
Input reaches tmux as literal keystrokes. Details:
[security](https://zerkersec.io/porthole/docs/latest/reference/security/).

## License

AGPL-3.0 (see `LICENSE`) with a store-distribution exception for the
copyright holder's own builds (`LICENSE-EXCEPTION.md`). Contributions are
accepted under `CLA.md`. The Porthole name and icon are governed by
`TRADEMARKS.md`.
