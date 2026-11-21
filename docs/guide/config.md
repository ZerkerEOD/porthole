# Configuration

The daemon reads `~/.config/porthole/config.toml` (or the file given with
`--config`). The file is optional: with no file at all the daemon listens on
every private address on port 7433, watches the default Claude Code and Codex
profiles, and offers the repositories it has seen sessions in. `porthole
config` prints the effective values and the paths in use.

Two files live next to each other:

| File | Who writes it | Holds |
|---|---|---|
| `config.toml` | you | everything below; never rewritten by the CLI |
| `repos.toml` | `porthole add` and `porthole remove` | `repos` and `workspaces` lists, merged with the ones in `config.toml` |

## Reference

The full example ships as `daemon/packaging/config.example.toml`:

```toml
# ~/.config/porthole/config.toml
name = "desktop"            # shown in the app
listen = ["auto"]           # every loopback/private/VPN address; or explicit IPs
port = 7433
workspaces = ["~/Programming"]   # parent dirs scanned two levels deep for git repos
repos = []                  # single repos to offer; `porthole add` writes them to repos.toml instead
                            # (directories you have already run claude/codex in appear automatically)
profiles = []               # extra CLAUDE_CONFIG_DIR / CODEX_HOME dirs to watch

[claude]
enabled = true
binary = "claude"

[codex]
enabled = true
binary = "codex"

[tmux]
binary = "tmux"
session_prefix = "ph"       # spawned sessions are named ph-<provider>-<id>

[hooks]
permission_timeout_s = 60   # how long a permission prompt waits for the phone

[cswap]
enabled = true              # auto-off when cswap is not on PATH
poll_interval_s = 150       # cache reads; cswap owns the real network cadence

[push]
relay_url = ""              # empty = push off. The relay the app uses, without its credential
                            # (e.g. https://relay.zerkersec.io or your own Worker).
```

### Top level

`name`
:   The machine name the app shows. Default: the hostname.

`listen`
:   `["auto"]` binds every loopback, RFC1918, CGNAT (`100.64.0.0/10`), IPv6
    ULA and VPN-interface address (`tailscale*`, `wg*`, `utun*`, `tun*`,
    `nebula*`, `zt*`) on the machine. Give explicit IP addresses instead to bind
    only those. A public address is refused unless `serve` is run with
    `--allow-public-bind-i-understand`, which is not the intended deployment:
    use a VPN. Default: `["auto"]`.

`port`
:   TCP port for the app. Default: `7433`. Open it in the host firewall on the
    interface the phone uses.

`workspaces`
:   Parent directories scanned two levels deep for git repositories, offered
    in **New session**. `~` and environment variables are expanded.
    `porthole add --workspace` records the same thing in `repos.toml` instead.
    Default: none.

`repos`
:   Individual repositories offered in **New session** without scanning.
    `porthole add` records them in `repos.toml`; this key is for listing them
    by hand. Default: none.

`profiles`
:   Extra `CLAUDE_CONFIG_DIR` or `CODEX_HOME` directories to watch for
    transcripts, on top of `~/.claude` and `~/.codex` and anything a running
    process is using. Default: none.

### `[claude]` and `[codex]`

`enabled`
:   Turn the integration off entirely. Default: `true`.

`binary`
:   Name or path of the CLI used to start new sessions. Default: `claude` /
    `codex`.

### `[tmux]`

`binary`
:   Name or path of tmux. Default: `tmux`.

`session_prefix`
:   Sessions started from the app are named `<prefix>-<provider>-<id>`.
    Default: `ph`.

### `[hooks]`

`permission_timeout_s`
:   How long a Claude Code permission prompt waits for an answer from a phone
    before falling back to the terminal prompt. Default: `60`.

### `[cswap]`

`enabled`
:   Read account and quota information from
    [claude-swap](https://github.com/ZerkerEOD/claude-swap). Automatically off
    when `cswap` is not on `PATH`. Default: `true`.

`binary`
:   Name or path of the cswap binary. Default: `cswap`.

`poll_interval_s`
:   How often the daemon re-reads cswap's cached account list. cswap decides
    when to hit the network; this only controls how fresh the app's view is.
    Default: `150`.

### `[push]`

`relay_url`
:   Base URL of the push relay, **without** the credential that sits in the
    app's relay URL: `https://relay.zerkersec.io` for the hosted relay, or
    your own Worker's URL. Empty means push is off and the daemon refuses push
    registrations from the app. Default: empty. See
    [Push notifications](push.md).

## Reloading

The daemon reloads `repos.toml` and the `workspaces` list when `porthole add`
or `porthole remove` asks it to, or on `SIGHUP`:

```sh
systemctl --user kill -s HUP porthole      # Linux
kill -HUP "$(pgrep -u "$USER" -f 'porthole serve')"
```

Every other key (`port`, `listen`, `profiles`, the provider, hook, cswap and
push sections) needs a restart:

```sh
systemctl --user restart porthole                                              # Linux
launchctl kickstart -k "gui/$(id -u)/io.zerkersec.porthole.daemon"            # macOS
```

## Paths

| What | Where | Override |
|---|---|---|
| Configuration | `~/.config/porthole/` (`config.toml`, `repos.toml`) | `XDG_CONFIG_HOME`, `--config` |
| State: TLS key and certificate, paired devices (`devices.json`), transcript cursors | `~/.local/state/porthole/` (mode 0700) | `XDG_STATE_HOME` |
| Control socket for the CLI and hooks | `$XDG_RUNTIME_DIR/porthole/porthole.sock`, or `<state>/run/` where there is no runtime dir (macOS) | `XDG_RUNTIME_DIR` |
| Service unit | `~/.config/systemd/user/porthole.service` (Linux), `~/Library/LaunchAgents/io.zerkersec.porthole.daemon.plist` (macOS) | |

Deleting the state directory makes the daemon generate a new certificate and
forget every paired phone; you will have to pair again.
