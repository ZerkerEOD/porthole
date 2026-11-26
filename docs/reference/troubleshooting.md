# Troubleshooting

Start with `porthole doctor` and `porthole status` on the machine. Daemon logs: `journalctl --user -u porthole -f` on Linux,
`/tmp/porthole.log` for the launchd agent on macOS, or run `porthole serve
--log-level debug` in a terminal.

## Pairing and connecting

**`porthole pair` says "no VPN or private address is bound"**
:   The daemon found nothing but loopback to listen on. Bring the VPN up (or
    join the Wi-Fi) and restart the daemon; `listen = ["auto"]` picks up
    private and VPN addresses at start.

**The app cannot reach the machine**
:   The phone needs a private route to the host shown by `porthole pair`: the
    same network, or the VPN connected on the phone too. The daemon refuses
    connections from public addresses. Run `porthole status` on the machine:
    it lists the bound addresses with their kind (lan or vpn) and the recent
    connection attempts. If the phone's attempts do not show up there, the
    traffic is not reaching the daemon: wrong address, wrong network, or a
    firewall. `porthole doctor` reports an active host firewall and prints
    the command that opens TCP port 7433 (or your `port`). VPN traffic often
    bypasses the host firewall; LAN traffic does not.

**The VPN address times out while the LAN address works**
:   The phone's VPN client must be a peer of the same network as the machine,
    with a policy that lets it reach this peer. `porthole status` shows whether
    any attempt arrived from the VPN range; if none did, the phone has no
    route to that address. With NetBird, the phone must appear in
    `netbird status --detail` on the machine, under the same controller. The app
    keeps working over the LAN address and shows the VPN address as
    unreachable under **Machines**.

**"Certificate fingerprint mismatch"**
:   The daemon's certificate changed because its state directory
    (`~/.local/state/porthole/`) was deleted or the daemon moved to a new
    machine. Forget the machine in the app and pair again.

**The pairing code is rejected**
:   Codes are single use and expire after two minutes. Five wrong attempts in
    a minute lock that source address out for a minute. Run `porthole pair`
    again.

**A phone was lost**
:   `porthole devices` then `porthole devices revoke <id>`. Its connections
    close within a second and its token stops working.

## Sessions

**A session is read-only**
:   Only sessions running inside tmux can be controlled. Start them with
    `porthole wrap claude` (or `codex`), or from the app's **New session**. A
    finished session can be restarted under tmux with **Resume in tmux…**.
    See [Sessions](../guide/sessions.md#controllable-or-read-only).

**A session is missing**
:   The daemon reads `~/.claude/projects` and `~/.codex/sessions`. A CLI
    using another `CLAUDE_CONFIG_DIR` or `CODEX_HOME` is found while it runs;
    add the directory to `profiles` in config.toml to watch it always. Check
    `porthole sessions`.

**No repositories in New session**
:   Nothing has been recorded and no session has run anywhere yet. Run
    `porthole add` inside a repository, or `porthole add --workspace ~/code`
    for a folder of them, then check `porthole repos`.

**Permission prompts do not appear on the phone**
:   Hooks apply only to sessions started after `porthole install-hooks` ran;
    restart the session. `porthole doctor` reports whether each profile has
    the hooks. Prompts also fall back to the terminal after
    `permission_timeout_s` (60 s) with no answer, so an old prompt may already
    have been answered at the keyboard.

**Run with ! says the session is busy, has unsent text, or has messages queued**
:   `!` only enters Claude Code's shell mode when the session is waiting at
    its prompt with an empty input box and nothing queued. Wait for the turn
    and the queued messages to go through, or open the terminal view and
    clear anything typed there, then try again. If the session is busy for a
    while, **Run in a window** runs the command anyway and sends the output
    into the session when it exits.

**A message I sent from the phone is not in the chat**
:   If Claude was busy, the CLI queued it; the chat shows it as a faded
    "Queued" bubble until the turn ends. If the bubble says "Could not
    send", the daemon could not type into the pane; the reason is on the
    bubble and **Retry** sends it again. A message that shows neither way
    was typed into a terminal the app is not following; check the terminal
    view.

**A run card stays on "running", or the terminal shows a dead window**
:   The daemon that started the run has restarted, usually because the
    command itself reinstalled it. The new daemon picks the run up from
    disk, finishes the card and sends the output if asked; the card then
    says "recovered". A window whose command has ended stays in tmux for ten
    minutes and is closed by the daemon; the app never follows a dead window,
    so use **Full output** on the card instead.

**Session status stays "unknown"**
:   The status comes from hooks, so sessions started before the hooks were
    installed report nothing until restarted.

**No account or quota information**
:   [claude-swap](https://github.com/ZerkerEOD/claude-swap) must be on the
    daemon's `PATH`. The systemd unit and launchd agent set a fixed `PATH`;
    edit it if cswap lives elsewhere, and `[cswap] enabled` must not be
    `false`.

## Notifications

**Nothing arrives while the app is closed**
:   Direct notifications need the app open (or, on Android, **Stay connected
    in the background**). Everything else needs a push relay: a relay URL in
    **Settings → Push relay**, `[push] relay_url` set on every machine, and
    the daemon restarted afterwards. See [Push notifications](../guide/push.md).

**"Relay: not active"**
:   The relay answered 402: the credential in your relay URL is not active
    (lapsed, unknown, or mistyped). Check it with whoever runs the relay; for
    the hosted relay that is <https://zerkersec.io/supporter>.

**"Relay: could not verify"**
:   The relay could not be reached. The app keeps using its last grant and
    retries; **Re-check** forces a retry now.

**"Apple has not issued this phone a push token yet"**
:   The app asks Apple for a push token the first time you save a relay URL,
    and Apple can take a few seconds. Make sure the phone is online, then
    save the URL again. TestFlight build 1 never asked Apple for a token and
    fails here every time; update the app.

**Relay is connected but one machine never pushes**
:   That daemon has no `relay_url`, or the machine is muted under
    **Machines**. The daemon refuses push registrations until the URL is set
    and it is restarted.

**There is no Push relay field in Settings**
:   This build was made without the Firebase options, so it cannot receive
    push at all. Install a store build, or build with
    `--dart-define-from-file=dart_defines/store.json`.

**iOS alerts arrive late or not at all without a relay**
:   iOS suspends the connection shortly after the app leaves the foreground. See [iOS background behavior](ios-background.md).

## The daemon

**"refusing to run as root"**
:   Run the daemon as the user who owns the sessions. The service files do
    this already; do not wrap them in `sudo`.

**"listen ... is a public address; refusing"**
:   An explicit `listen` entry is a public IP. Use a private or VPN address
    instead. `--allow-public-bind-i-understand` overrides the check; see
    [Security](security.md).

**The service does not come back after a reboot (Linux)**
:   User services only run while you are logged in unless linger is enabled:
    `sudo loginctl enable-linger "$USER"`. `porthole install` tries this and
    prints the command if it could not.

**`claude` or `codex` not found by the daemon but fine in a shell**
:   The service runs with a fixed `PATH` (`~/.local/bin`, `/usr/local/bin`,
    `/usr/bin`, `/bin`, plus `/opt/homebrew/bin` on macOS). Add the directory
    your CLI lives in to the unit's `Environment=PATH=…` line (Linux) or the
    plist's `PATH` (macOS), or point `binary` in config.toml at the full path.

**Changes to config.toml do nothing**
:   Only `repos.toml` and `workspaces` reload live (on `SIGHUP` or when
    `porthole add` runs). Everything else needs
    `systemctl --user restart porthole`. See [Reloading](../guide/config.md#reloading).
