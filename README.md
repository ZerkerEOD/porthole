# Porthole

A self-hosted phone remote for **Claude Code** and **Codex** sessions running on
your own machine. No cloud in the path of your sessions, no accounts: a small
daemon on the computer, an app on the phone, and your VPN in between.

- Attach to sessions you already started in tmux, or start new ones in any repo.
- Read the conversation as rendered markdown, straight from the CLIs' own
  transcript files. Tool calls, results and thinking are all there.
- Type prompts and slash commands (`/compact`, your own skills) into the real
  TUI, and drop into a terminal view for permission prompts and menus.
- Approve Claude Code permission prompts from the phone.
- See which account is doing the work and how much quota is left (with
  [claude-swap](https://github.com/ZerkerEOD/claude-swap) installed).

The daemon only listens on loopback, private and VPN addresses and refuses to
start on a public one. Phones pair by scanning a one-time QR code, pin the
daemon's certificate, and can be revoked at any time.

## Install (daemon)

Download a release from GitHub Releases (or `go build ./cmd/porthole` in
`daemon/`), put `porthole` on your PATH, then:

```sh
porthole doctor          # checks tmux, claude, codex, profiles
porthole install-hooks   # Claude Code hooks + Codex notify (idempotent)
porthole serve           # or install packaging/porthole.service / the launchd plist
porthole pair            # scan the QR with the app
```

Config lives at `~/.config/porthole/config.toml` (see
`daemon/packaging/config.example.toml`). Set `workspaces` to the parent
directory of your repos to start sessions from the phone.

Sessions are controllable when they run inside tmux. `porthole wrap claude`
starts one in the current directory; sessions started from the app are always
in tmux. Sessions outside tmux are shown read-only.

## App

`app/` is a Flutter project (Android, iOS; Linux desktop for development).
Build it yourself with `flutter build apk` / `flutter build ios`, or install
the free store builds. The app sells nothing and has no accounts. Push
notifications while the app is closed need a small relay: paste a relay URL
into Settings → Push relay. Run your own (`docs/self-host-relay.md`) or use
the one the project hosts for its supporters (zerkersec.io/supporter hands
out a personal relay URL). Everything else is identical and needs no cloud
at all. The empty home screen has a "Try the demo" link that loads a sample
machine so you can look around before pairing.

## Security

See `docs/threat-model.md`. Short version: VPN-only bind policy, TLS 1.3 with
certificate pinning, per-device bearer tokens stored hashed, single-use pairing
codes, literal (never shell-interpreted) input into tmux, and a permission
broker that falls back to the terminal prompt when no phone answers.

## License

AGPL-3.0 (see `LICENSE`) with a store-distribution exception for the
copyright holder's own builds (`LICENSE-EXCEPTION.md`). Contributions are
accepted under `CLA.md`. The Porthole name and icon are governed by
`TRADEMARKS.md`.
