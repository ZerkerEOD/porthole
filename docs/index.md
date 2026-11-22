# Porthole

Porthole lets you follow and control Claude Code and Codex sessions from a phone.
A daemon runs on the machine where the agents run. The app connects to it over
your LAN or VPN on TCP port 7433, reads the agents' own transcript files, and
sends input into the session's tmux window. From the phone you can read a
conversation including tool calls and thinking, type prompts and slash commands,
open a terminal view of the tmux pane, answer Claude Code permission prompts,
start a new session in a repository, and, with
[claude-swap](https://github.com/ZerkerEOD/claude-swap) installed, see which
account is active and how much quota is left.

The daemon listens only on loopback, private and VPN addresses. Phones pair
with a single-use QR code and pin the daemon's certificate. The details are on
the [security page](reference/security.md).

## How it fits together

| Piece | Where it runs | What it does |
|---|---|---|
| Daemon (`porthole`) | the computer that runs Claude Code or Codex: Linux, macOS, or [Windows through WSL2](getting-started/windows.md) | watches transcript files, drives tmux, brokers permission prompts, serves the app over TLS on port 7433 |
| App | Android or iOS | lists sessions, renders conversations, sends input, answers permission prompts |
| Network | between the two | any private network the phone can reach the computer on: the same Wi-Fi, WireGuard, Tailscale, NetBird |
| Push relay (optional) | a Cloudflare Worker, hosted by the project or by you | wakes the phone while the app is closed; receives only ciphertext |

## Quick start

On the computer:

```sh
curl -fsSL https://raw.githubusercontent.com/ZerkerEOD/porthole/main/scripts/install.sh | sh
cd ~/code/my-project && porthole add     # optional; pairing works without it
porthole pair                            # prints a QR code
```

On the phone, install the app (see [The app](getting-started/app.md#install-it)
for the beta links), tap **Scan pairing code** and point it at the QR. The
longer version:

1. [Install the daemon](getting-started/install.md)
2. [Pair a phone](getting-started/pairing.md)
3. [The app](getting-started/app.md)

Store and beta links for the app are on [The app](getting-started/app.md#install-it).
Source code and daemon releases: <https://github.com/ZerkerEOD/porthole>.

## Where to go next

- [Sessions](guide/sessions.md): which sessions the app can control, and how to start new ones.
- [Push notifications](guide/push.md): alerts while the app is closed.
- [Configuration](guide/config.md) and the [CLI reference](guide/cli.md).
- [Build the app yourself](self-host/app.md) and [self-host the push relay](self-host/relay.md).
- [Troubleshooting](reference/troubleshooting.md) and [security](reference/security.md).
