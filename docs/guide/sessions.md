# Sessions

A session is one Claude Code or Codex conversation. The daemon finds sessions
by reading the transcript files the CLIs write (`~/.claude/projects` and
`~/.codex/sessions`, plus any `profiles` you configure). Every session the
CLIs record appears in the app, whether or not Porthole started it.

## Controllable or read-only

The app can read any session the daemon can see. It can type into a session
only when that session runs inside tmux, because tmux is how the daemon
delivers keystrokes and captures the screen. There are two ways to get a
controllable session:

- Start it from the terminal with `porthole wrap`:

    ```sh
    cd ~/code/my-project
    porthole wrap claude            # or: porthole wrap codex
    porthole wrap claude --resume   # extra arguments go to the CLI
    ```

    `wrap` opens a tmux session in the current directory and runs the CLI in
    it, attaching your terminal. If you are already inside tmux, it opens a new
    window instead of nesting.

- Start it from the app with **New session**. These run inside tmux, named
  `ph-<provider>-<id>`, and you can attach to them from a terminal too.

A session started any other way (plain `claude` in a terminal, an IDE
integration) is shown read-only: you can follow it, but the input bar and the
terminal view are disabled. Once it has finished, **Resume in tmux…** restarts
it under tmux and makes it controllable.

## Choosing where sessions start

**New session** lists the repositories the daemon offers. `porthole repos`
prints the same list, which comes from three sources:

1. Recent directories: every directory the daemon has seen a Claude Code or
   Codex session in, from the profiles it watches. These need no
   configuration.
2. Repositories recorded with `porthole add`, or listed under `repos` in
   `config.toml`. Use this for a repository you have not run an agent in yet:

    ```sh
    cd ~/code/new-project
    porthole add            # finds the git top level, asks to confirm
    porthole add ~/code/other-project --yes
    ```

3. Workspaces: parent folders scanned two levels deep for git repositories,
   recorded with `porthole add --workspace ~/code` or listed under
   `workspaces` in `config.toml`.

`porthole add` writes to `~/.config/porthole/repos.toml`, a file the CLI
manages. It does not edit `config.toml`. A running daemon picks the change up
at once; otherwise it applies at the next start. `porthole remove [dir]` takes
an entry out again (entries you wrote in `config.toml` yourself are edited
there). The daemon logs a warning at start when no repositories or workspaces
are configured; recent directories still work.

A new session's directory must be inside a configured repository or
workspace, or be one of the recent directories. The app cannot start an agent
in any other path.

## Hooks: permission prompts and status

`porthole install` (or `porthole install-hooks`) registers Porthole as a
Claude Code hook for `SessionStart`, `SessionEnd`, `UserPromptSubmit`, `Stop`,
`Notification`, `PermissionRequest`, `PermissionDenied` and `PostModelSwitch`, and as the Codex
`notify` handler. This is how the daemon learns a session's status (idle,
busy, waiting for permission, waiting for input, exited) without polling, and
how a permission prompt reaches the phone.

When Claude Code asks for permission, the hook tells the daemon, which decides
who should answer:

1. A phone has the session open: the daemon holds the prompt for
   `permission_timeout_s` (60 s by default) and shows it on the phone with the
   tool name and input. Tap **Allow** or **Deny**; the answer goes back
   through the hook, bound to that request's id.
2. No phone is watching, but you opened the session from a phone and no
   terminal is attached to its tmux session: the daemon holds the prompt for
   `permission_timeout_detached_s` (5 minutes) and sends a push, so you have
   time to open the app and answer.
3. A terminal is attached and no phone is watching: the hook returns at once
   and Claude Code draws its own prompt in the terminal, so the person at the
   keyboard is not kept waiting.

In the last case, and whenever a held prompt times out, the daemon reads the
prompt off the terminal screen and shows it in the app with the same choices
the terminal offers: **Yes**, **Yes, and always allow…**, **Yes, and switch
to auto mode**, **No**, or for a plan **Yes, and use auto mode**, **Yes,
manually approve edits**, **Tell Claude what to change**. Tapping one presses
the matching keys in the terminal. If the daemon is not running, nothing is
held and the terminal prompt appears as usual.

Hooks take effect for sessions started after they were installed; running
sessions keep their old hook set. `porthole uninstall-hooks` removes them
(remove Codex's `notify` line by hand).

## Permission mode

Each Claude session runs in a permission mode: **Manual** (ask before each
tool), **Accept edits**, **Plan**, **Auto**, and the launch-only **Don't ask**
and **Bypass**. The mode shows as a chip in the session header and after the
status in the session list. Tap the chip to change it: the daemon presses
Shift+Tab in the terminal until the status bar names the mode you chose, the
same thing you would do at the keyboard. Auto is offered only when the
account has it; Bypass only when the session was started with it. The mode
cannot be changed while a prompt or question is open, because Tab means
something else inside a dialog.

In auto mode, actions the classifier blocks never open a prompt; the session
header notes the last one ("Auto mode blocked Bash, 2m ago") and the terminal
lists them under `/permissions`. After several blocks Claude Code pauses auto
mode and prompts normally, which the app then shows as above.

## Status and attention

Each session carries a status: `idle`, `busy`, `waiting_permission`,
`waiting_input`, `exited` or `unknown`. Sessions that need you sort to the top
of the home screen.

Notifications follow three rules. They are sent only for sessions you opened
from the phone: started with **New session**, or viewed in the app at least
once. They are sent only when the session needs you: a permission prompt, a
question, or a turn that has finished and is waiting for your next message.
Each of those sends one notice per wait; the session going busy again resets
it. Sessions running in your own terminals that you never opened in the app
stay silent.

With **Notify while connected** on, the app raises those notices itself while
it is open, and on Android also in the background when **Stay connected in the
background** is on. For notifications while the app is closed, see
[Push notifications](push.md).

## Multiple machines

Pair the phone with each machine. Each runs its own daemon with its own
pairing. The app merges their sessions into one list and lets you filter by
machine.

## Accounts and usage

If [claude-swap](https://github.com/ZerkerEOD/claude-swap) is on the
machine's `PATH`, the daemon reads its cached account list. The app shows the
active account and quota windows under **Accounts & usage** and tags each
session with the account doing the work. Turn this off with
`[cswap] enabled = false` in [config.toml](config.md).
