# Install the daemon

The daemon runs on the computer where Claude Code or Codex runs, as your own
user. It needs:

- Linux or macOS.
- `tmux`, for sessions you want to control from the phone.
- `claude` and/or `codex` on your `PATH`.
- A private address the phone can reach: the same Wi-Fi, or a VPN such as
  WireGuard, Tailscale or NetBird. The daemon never listens on a public address.

## One-line installer

```sh
curl -fsSL https://raw.githubusercontent.com/ZerkerEOD/porthole/main/scripts/install.sh | sh
```

The script downloads the latest [GitHub release](https://github.com/ZerkerEOD/porthole/releases)
for your OS and architecture, verifies the checksum, and runs `porthole install`.

Prefer to build from source? You need Go 1.27:

```sh
cd daemon
go build -o ~/.local/bin/porthole ./cmd/porthole
porthole install
```

## What `porthole install` does

1. Copies the running binary to `~/.local/bin/porthole` if it is not already there.
2. Sets up a user service so the daemon starts at login and restarts if it crashes:
    - **Linux:** writes `~/.config/systemd/user/porthole.service`, runs
      `systemctl --user daemon-reload` and `systemctl --user enable --now porthole`,
      then tries `loginctl enable-linger` so the service also runs while you are
      logged out. If linger needs root it prints the `sudo` command to run.
    - **macOS:** writes `~/Library/LaunchAgents/io.zerkersec.porthole.daemon.plist`
      and loads it.
3. Runs the same checks as [`porthole doctor`](../guide/cli.md#doctor): tmux, the CLIs, the
   profiles it will watch, and whether the daemon answers.
4. Installs the Claude Code hooks and the Codex notify handler, exactly like
   [`porthole install-hooks`](../guide/cli.md#install-hooks). Hooks are what turn
   permission prompts into something the phone can answer; they apply to sessions
   started after this point.
5. Prints the next steps: `porthole add` inside a repository, then `porthole pair`.

`porthole install --no-service` skips step 2 (run `porthole serve` yourself, or use the unit
files under `daemon/packaging/`). `--no-hooks` skips step 4.

## Check it

```sh
porthole status
```

prints the version, the addresses the daemon is listening on, and how many
sessions and devices it knows about. `porthole doctor` goes through the
environment in more detail.

## Firewall

The app connects to TCP port **7433** (change it with `port` in
[config.toml](../guide/config.md)). If the computer runs a host firewall,
allow that port on the VPN or LAN interface the phone will use.

## Next

- [Tell the daemon about your repositories](../guide/sessions.md#choosing-where-sessions-start) with `porthole add` (optional: everything you have already used an agent in is listed automatically).
- [Pair a phone](pairing.md).
