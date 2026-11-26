# CLI reference

`porthole` is one binary: the daemon (`porthole serve`) and the commands that
talk to it over a local socket. Run them as the user who owns the sessions,
never as root.

Global flags, accepted by every command:

| Flag | Meaning |
|---|---|
| `--config <file>` | configuration file (default `~/.config/porthole/config.toml`) |
| `--log-level <level>` | `debug`, `info`, `warn` or `error` (default `info`) |
| `--version` | print the version |

## Setup

### `install`

```
porthole install [--no-service] [--no-hooks]
```

Puts the running binary in `~/.local/bin/porthole` if it is not already there,
sets up a user service that starts the daemon at login, runs the `doctor`
checks and installs the hooks, then prints what to do next.

- Linux: writes `~/.config/systemd/user/porthole.service`, runs
  `systemctl --user daemon-reload` and `systemctl --user enable --now
  porthole`, and tries `loginctl enable-linger` so the daemon runs while you
  are logged out (prints the `sudo` command if that fails).
- macOS: writes `~/Library/LaunchAgents/io.zerkersec.porthole.daemon.plist` and loads it.

| Flag | Meaning |
|---|---|
| `--no-service` | do not create or start a service |
| `--no-hooks` | skip `install-hooks` |

### `doctor`

```
porthole doctor
```

Prints the config file in use, the workspaces, where `tmux`, `claude`, `codex`
and `cswap` were found, each Claude Code and Codex profile the daemon will
watch and whether the hooks are installed in it, and whether the daemon is
running and on which addresses, with the interface and kind (loopback, lan,
vpn) of each. Checks for an active host firewall (ufw, firewalld, nftables,
iptables, or the macOS application firewall) and prints the command that
opens the daemon's port in it.

### `install-hooks`

```
porthole install-hooks [--profile <dir>] [--codex-home <dir>] [--no-claude] [--no-codex]
```

Adds the Porthole hooks to Claude Code's `settings.json` and sets Codex's
`notify` handler. Running it again changes nothing. Hooks take effect for new sessions; running
sessions keep their old hook set.

| Flag | Meaning |
|---|---|
| `--profile <dir>` | `CLAUDE_CONFIG_DIR` to install into (default `~/.claude`) |
| `--codex-home <dir>` | `CODEX_HOME` to install into (default `~/.codex`) |
| `--no-claude` | skip Claude Code |
| `--no-codex` | skip Codex |

### `uninstall-hooks`

```
porthole uninstall-hooks [--profile <dir>]
```

Removes the hooks from Claude Code's settings. Codex's `notify = [...]` line
is removed by hand.

### `config`

```
porthole config
```

Prints the configuration directory, state directory, socket path and the
effective configuration as JSON.

## Running

### `serve`

```
porthole serve [--allow-public-bind-i-understand]
```

Runs the daemon in the foreground; the service runs this command. It refuses
to start as root and refuses to bind a public address.

| Flag | Meaning |
|---|---|
| `--allow-public-bind-i-understand` | bind and accept connections on public addresses; see [Security](../reference/security.md) |

### `status`

```
porthole status
```

Prints the version, machine name, pid, uptime, session and device counts,
whether tmux and cswap were detected, the bound addresses with the interface
and kind (loopback, lan, vpn) of each, the last ten connection attempts
from phones (time, source address, path, result and device), and the last
ten commands run from a phone with **Run in a window** (id, session, state,
exit code and start time).

### `sessions`

```
porthole sessions [--json]
```

Lists the sessions the daemon knows about: provider, status, the tmux session
when controllable, repository, title, last update and id. `--json` prints the
raw records.

## Phones

### `pair`

```
porthole pair [--label <text>] [--json]
```

Asks the running daemon for a one-time pairing code and prints it as a QR
(`porthole://pair?d=…`) plus the manual values: hosts, port, code and
certificate fingerprint. The code is single use and expires after two minutes.
See [Pair a phone](../getting-started/pairing.md).

| Flag | Meaning |
|---|---|
| `--label <text>` | optional label for this pairing |
| `--json` | print the pairing payload as JSON instead of a QR |

### `devices`

```
porthole devices
porthole devices revoke <id>
```

Lists paired phones (id, name, paired date, last seen). `revoke` deletes one
and closes its connections within a second.

## Repositories

### `add`

```
porthole add [dir] [--workspace] [--yes|-y]
```

Records a repository so the app can start sessions in it. With no argument it
uses the current directory. It finds the git top level, shows it, asks to
confirm, and writes it to `~/.config/porthole/repos.toml`. A running daemon is
told to reload at once; otherwise the change applies at the next start.

| Flag | Meaning |
|---|---|
| `--workspace` | record the directory as a workspace (a parent folder scanned two levels deep for git repositories) instead of a single repository |
| `--yes`, `-y` | do not ask for confirmation |


### `remove`

```
porthole remove [dir]
```

Removes a repository or workspace recorded by `add` (current directory when
omitted). Entries written by hand in `config.toml` are edited there.

### `repos`

```
porthole repos
```

Lists what the app will offer: configured repositories, repositories found
under workspaces, and recent directories.

## Sessions

### `wrap`

```
porthole wrap <claude|codex> [args...]
```

Starts the CLI inside a tmux session in the current directory, so the app can
control it, and attaches your terminal. Extra arguments are passed to the CLI.
Inside tmux already, it opens a new window instead of nesting.

## Internal commands

The hooks call `porthole hook` and `porthole codex-notify`. Both are hidden
and exit without an error when the daemon is down, so the CLIs keep working. `porthole client` is a hidden developer tool: a pinned-TLS WebSocket
client for exercising the protocol from the command line.
