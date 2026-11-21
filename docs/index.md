# Porthole

A self-hosted phone remote for **Claude Code** and **Codex** sessions running on
your own machine. No cloud in the path of your sessions, no accounts: a small
daemon on the computer, an app on the phone, and your VPN in between.

- Attach to sessions you already started in tmux, or start new ones in any repository.
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

## How it fits together

| Piece | Where it runs | What it does |
|---|---|---|
| **Daemon** (`porthole`) | the computer that runs Claude Code or Codex (Linux or macOS) | watches transcript files, drives tmux, brokers permission prompts, serves the app over TLS on port 7433 |
| **App** | Android or iOS | lists sessions, renders conversations, sends input, answers permission prompts |
| **VPN** | between the two | any private network the phone can reach the computer on: the same Wi-Fi, WireGuard, Tailscale, NetBird |
| **Push relay** (optional) | a Cloudflare Worker, hosted by the project or by you | wakes the phone while the app is closed; sees only ciphertext |

## Quick start

On the computer:

```sh
curl -fsSL https://raw.githubusercontent.com/ZerkerEOD/porthole/main/scripts/install.sh | sh
cd ~/code/my-project && porthole add     # optional: offer this repository in the app
porthole pair                            # shows a QR code
```

On the phone: install the app, tap **Scan pairing code**, point it at the QR.
That is the whole setup. Follow the detailed path if anything needs explaining:

1. [Install the daemon](getting-started/install.md)
2. [Pair a phone](getting-started/pairing.md)
3. [The app](getting-started/app.md)

## Get the app

- **iOS:** a public TestFlight link, <https://testflight.apple.com/join/wYZrvvYa>, is used for
  the beta. It starts working once Apple's beta review has passed; if it reports that the beta
  is not accepting testers yet, check back shortly.
- **Android:** the Play closed test link will be added here once the test track is live.
- **Build it yourself:** the Flutter project is in `app/`; see [The app](getting-started/app.md#build-it-yourself).

Source code and daemon releases: <https://github.com/ZerkerEOD/porthole>.

## Where to go next

- [Sessions](guide/sessions.md): what the app can see and control, and why tmux matters.
- [Push notifications](guide/push.md): alerts while the app is closed.
- [Configuration](guide/config.md) and the [CLI reference](guide/cli.md).
- [Self-host the push relay](self-host/relay.md).
- [Troubleshooting](reference/troubleshooting.md) and the [security model](reference/security.md).
