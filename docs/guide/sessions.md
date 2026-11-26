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

The plan approval dialog is never held by the hook, because a hook decision
can only say yes or no. The daemon lets the terminal draw it, reads it back
within a second or two, and shows the whole plan from the plan file on the
card with the dialog's three choices. After **Tell Claude what to change**,
type the change in the message box.

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

## Where a chat opens

A chat opens at the bottom, and stays pinned there while you are at the
bottom, so new messages and images that finish loading never leave you a
screen above the end. **Open chats at** in Settings can change that to the
top of Claude's latest reply, or to where you left off: the app remembers,
per session and only on the phone, which message was at the top of the
screen when you last scrolled, and draws a thin "New since you were here"
line above anything that arrived after that. If the remembered message is
far back, the app loads a few earlier pages to find it, and falls back to
the bottom with a short note if it cannot.

## Messages sent while Claude is busy

Claude Code does not interrupt a turn for a new message. Type one while it
is working, at the keyboard or from the phone, and the CLI holds it in a
queue, draws it above the spinner, and sends it when the turn ends or when
it next reports back from a tool. A queued message is not in the transcript
yet, so the app cannot read it from there. Instead it shows it two ways.

- A message you send from the phone appears at the bottom of the chat as
  soon as you tap send, faded, with a line under it: "Sending…", then
  "Queued · sends when Claude finishes the current turn" while the session
  is busy. When the message reaches the transcript the placeholder is
  replaced by the real one. If the daemon could not type it, the bubble
  says why and offers **Retry**.
- Messages queued from anywhere else, including the keyboard and another
  phone, are read off the terminal screen by the daemon and shown the same
  way, in the order they will be sent. They disappear when the CLI sends
  them.

While messages are queued, **Run with !** is unavailable, because the `!`
command would only join the queue behind them; the block says how many are
ahead. **Run in a window** still works. To send the queued messages at
once, open the terminal view and tap **Send now** on the key bar; it
presses ctrl+x ctrl+s, the CLI's own key for that.

## Running a suggested command

When Claude's reply contains a shell block, the block carries three actions:
**Copy**, **Run with !** and **Run in a window**. Both run paths show the
exact command first and wait for you to confirm.

**Run with !** uses a feature of Claude Code itself: a line that starts
with `!` is run in a shell instead of being sent to the model, and the
command and its output are written into the conversation, so Claude sees
them on its next turn. The app asks the daemon to type `!` into the
session, wait for the terminal to show its shell prompt, then type the
command and press Enter, exactly what you would do at the keyboard. The
chat shows the result as a command block: the command line, then its
output, then any errors. Because `!` only works while the session is
waiting at its prompt, the action is greyed out while Claude is working,
and if the terminal does not switch to its shell prompt within a second or
two the daemon takes the `!` back and tells you the session is busy or has
unsent text in its input box. The action is offered only for blocks whose
lines are plain commands (no heredocs, no line continuations); several
lines are joined with `&&`.

**Run in a window** is for long commands, multi-line blocks, or a session
that is busy. The daemon opens a new window in the session's tmux session,
runs the command there and streams the last lines into a card under the
session header, with **Stop**, **Open window** and **Dismiss**. **Open
window** shows that window in the terminal view while the command runs;
**Back to session** returns to the session's own pane. When the command
exits, the daemon types one message into the session with the command, the
last 120 lines of output and the exit code, so the result reaches Claude
the same way a pasted message would. If the session was busy, Claude Code
queues that message as the next turn and the card says so. Switch **Send
output to the session** off in the confirmation to keep the output on the
card only. The finished window stays in tmux, named `ph-run-` and the run's
id, for ten minutes and is then closed; **Dismiss** closes it at once. The
daemon only ever closes windows it opened itself. The card keeps the output
either way.

Both actions run with your account on the machine, exactly as typing into
the terminal would; the daemon logs every run with the device that asked
and the exit code, and `porthole status` lists the last ten.

Runs are written to disk, so a command that restarts the daemon itself (a
rebuild followed by `porthole install`) is picked up by the new daemon: it
finishes the card, sends the output to the session if you asked for it, and
closes the window after ten minutes. A card marked "recovered" went through
that. **Full output** on a finished card shows the whole log.

## Images

Images travel both ways between the phone and the machine, and never
anywhere else.

- The attach button in the message box takes a photo or picks one from the
  library, uploads it to the daemon, and adds an "Attached image:" line with
  the file's path to your message. Claude reads the file from there with its
  Read tool, so you can ask about a screenshot, a whiteboard or an error on
  another screen. PNG, JPEG, WebP and GIF up to 10 MB are accepted. Uploads
  live under the daemon's state directory in `uploads/<session id>/`,
  readable only by your user, and are removed after seven days.
- Images in the transcript are shown inline: what you pasted in the terminal
  and what Claude looked at with its Read tool. Tap one to view it full size.
  Images over 1.5 MB are listed by size instead of shown.
- An image Claude writes and refers to by path, or embeds in markdown, is
  fetched from the machine and shown inline. The daemon serves only image
  files under the session's directory, its uploads folder, or its scratch
  space, and only to a paired phone.

## Subagents

When Claude Code hands work to a subagent (its Agent tool), the CLI writes
that agent's transcript to its own file next to the session's. The daemon
reads those files, so a session with subagents shows a strip under its title:
"3 agents · 2 working · 190k tokens". Tap it for the list: each agent's type,
what it was asked to do, how long it has run, tokens in and out, tool uses and
its last line of output. Open one to read its transcript as it is written.

Subagents run inside the session's own process and have no input of their
own, so the agent view is read-only. To steer one, message the session;
**Message the session** on the agent view puts an opening line in the
composer for you. When a background agent finishes, the session's chat shows
one line with its summary, tokens, tool uses and duration.

The session's own token total (without its agents) appears at the end of the
header line once the daemon has read it.

## Reading the states

A session row shows a glyph and a word for what the agent is doing. The
colours mean one thing each: blue is working, amber is waiting for you,
green is ready, grey is over, and crimson is reserved for errors.

| Glyph | Label | Meaning |
|---|---|---|
| spinning ring | working | The CLI is busy. With subagents the label counts them. |
| filled question mark | needs your answer | A multiple-choice question is open. |
| shield | needs approval | A permission prompt is waiting. |
| checklist | plan ready to approve | Plan mode has written a plan and asks how to proceed. |
| speech bubble | waiting for you | The turn ended; the session waits for your next message. |
| check | ready | Idle, nothing pending. |
| stop | ended | The CLI exited. **Resume in tmux…** restarts it. |
| eye (trailing) | read-only | Not inside tmux, so the app can watch but not type. |
| crimson corner mark | blocked … | Auto mode refused an action in the last 15 minutes. |

Machines use a different set: a link for online, a spinning sync for
connecting or reconnecting, a broken link for offline (crimson when every
address failed its last check), and a warning sign for "pair again". The
same table is in the app under the **(i)** button on the home screen.

## Status and attention

Each session carries a status: `idle`, `busy`, `waiting_permission`,
`waiting_input`, `exited` or `unknown`. Sessions that need you sort to the top
of the home screen.

Notifications follow three rules. They are sent only for sessions you opened
from the phone: started with **New session**, or viewed in the app at least
once. They are sent only when the session needs you: a permission prompt, a
question, or a turn that has finished and is waiting for your next message.
Each of those sends one notice per wait; a new message from you starts the
next wait. A turn that ends while subagents or background commands are still
running is not finished: the notice waits until that work is done and the
session has stayed idle for a moment, and if the work wakes Claude again
nothing is sent. Sessions running in your own terminals that you never
opened in the app stay silent.

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
