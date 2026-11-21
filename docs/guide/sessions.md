# Sessions

A session is one Claude Code or Codex conversation. The daemon finds them by
reading the transcript files the CLIs write (`~/.claude/projects` and
`~/.codex/sessions`, plus any `profiles` you configure), so every session
shows up in the app whether or not Porthole started it.

## Controllable or read-only

The app can **read** any session the daemon can see. It can **type into** a
session only when that session runs inside tmux, because tmux is how the
daemon delivers keystrokes and captures the screen. There are two ways to get
a controllable session:

- Start it from the terminal with `porthole wrap`:

    ```sh
    cd ~/code/my-project
    porthole wrap claude            # or: porthole wrap codex
    porthole wrap claude --resume   # extra arguments go to the CLI
    ```

    `wrap` opens a tmux session in the current directory and runs the CLI in
    it, attaching your terminal as usual. Inside tmux already? It opens a new
    window instead of nesting.

- Start it from the app with **New session**. Those always run inside tmux
  (named `ph-<provider>-<id>`), and you can attach to them from a terminal too.

A session started any other way (plain `claude` in a terminal, an IDE
integration) is shown read-only: you can follow it, but the input bar and the
terminal view are disabled. Once it has finished, **Resume in tmux…** restarts
it under tmux and makes it controllable.

## Choosing where sessions start

**New session** lists the repositories the daemon offers. `porthole repos`
prints the same list, which comes from three sources:

1. **Recent:** every directory the daemon has seen a Claude Code or Codex
   session in, from the profiles it watches. Nothing to configure; if you have
   used an agent in a repository, it is here.
2. **Repositories** recorded with `porthole add` (or listed under `repos` in
   `config.toml`). Use this for a repository you have not run an agent in yet:

    ```sh
    cd ~/code/new-project
    porthole add            # finds the git top level, asks to confirm
    porthole add ~/code/other-project --yes
    ```

3. **Workspaces**: parent folders scanned two levels deep for git
   repositories, recorded with `porthole add --workspace ~/code` (or listed
   under `workspaces` in `config.toml`).

`porthole add` writes to `~/.config/porthole/repos.toml`, a file the CLI
manages; your hand-written `config.toml` is never rewritten. A running daemon
picks the change up immediately; otherwise it applies at the next start.
`porthole remove [dir]` takes an entry out again (entries you wrote in
`config.toml` yourself are edited there). The daemon logs a warning at start
when no repositories or workspaces are configured, but recent directories
still work.

For safety, a new session's directory must be inside a configured repository
or workspace, or be one of the recent directories; the app cannot start an
agent in an arbitrary path.

## Hooks: permission prompts and status

`porthole install` (or `porthole install-hooks`) registers Porthole as a
Claude Code hook for `SessionStart`, `SessionEnd`, `UserPromptSubmit`, `Stop`,
`Notification`, `PermissionRequest` and `PostModelSwitch`, and as the Codex
`notify` handler. That is how the daemon learns a session's status (idle,
busy, waiting for permission, waiting for input, exited) without polling, and
how a permission prompt reaches the phone.

When Claude Code asks for permission:

1. The hook sends the request to the daemon and waits.
2. The daemon shows it to every connected phone (and sends a push if a relay is
   configured) with the tool name and input.
3. Tap **Allow** or **Deny**. The answer goes back through the hook, bound to
   that request's id, so a stale approval can never apply to a different prompt.
4. If nobody answers within `permission_timeout_s` (60 s by default), the hook
   steps aside and Claude Code shows its own prompt in the terminal, exactly as
   if Porthole were not there. The same happens if the daemon is not running.

Hooks take effect for sessions started after they were installed; running
sessions keep their old hook set. `porthole uninstall-hooks` removes them
(Codex's `notify` line is removed by hand).

## Status and attention

Each session carries a status: `idle`, `busy`, `waiting_permission`,
`waiting_input`, `exited` or `unknown`. Sessions that need you sort to the top
of the home screen. With **Notify while connected** on, the app raises a local
notification for permission prompts and input requests while it is open, and
on Android also in the background when **Stay connected in the background** is
on. For notifications while the app is closed, see
[Push notifications](push.md).

## Multiple machines

Pair the phone with each machine (laptop, workstation, a box in the rack).
Each runs its own daemon with its own pairing; the app merges their sessions
into one list and lets you filter by machine.

## Accounts and usage

If [claude-swap](https://github.com/ZerkerEOD/claude-swap) is on the
machine's `PATH`, the daemon reads its cached account list and the app shows
the active account and quota windows under **Accounts & usage**, and tags each
session with the account doing the work. Turn it off with `[cswap] enabled =
false` in [config.toml](config.md).
