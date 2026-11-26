# The app

The Porthole app runs on Android and iOS. It talks to the daemons you paired
with and, if you turn it on, to a push relay. It has no accounts and no
purchases.

## Install it

- iOS: join the beta through the public TestFlight link,
  <https://testflight.apple.com/join/wYZrvvYa>. The link becomes active after
  Apple's beta review. If TestFlight says the beta is not accepting testers
  yet, try again later.
- Android: the Play closed test link will be added here once the test track
  is live. Until then, [build the app yourself](../self-host/app.md).

## Build it yourself

`app/` is a Flutter project. `flutter build apk` or `flutter build ipa` gives
you a build without push. To build with push against your own Firebase project
and relay, follow [Build the app yourself](../self-host/app.md).

## First launch

The empty home screen offers two things:

- **Scan pairing code** starts [pairing](pairing.md).
- **Try the demo** loads a sample machine with canned sessions so you can
  look around before pairing.

## Around the app

### Home

Home lists every session from every connected machine, filtered by **All**, a
machine, **Claude** or **Codex**. Each row shows a glyph and a word for what
the session is doing: blue means working, amber means it is waiting for you,
green means ready and grey means it has ended. The **(i)** button explains
every glyph; so does [Reading the states](../guide/sessions.md#reading-the-states).
Sessions that need you (a permission prompt, a question, a plan to approve)
move to the top with a badge. Finished sessions are under
**History**. **New session** starts an agent on a repository of a connected
machine. A machine's menu offers **Connect now**, **Accounts & usage**,
**Open machine view** and **Manage machines**.

### Session

The session screen renders the conversation from the CLI's own transcript:
prompts, replies, tool calls and results, and with **Show thinking** the
model's thinking. It opens at the bottom unless you change **Open chats at**
in Settings, and while you are at the bottom it stays there as new messages
and images arrive. Scroll up to **Load earlier**. The input bar types into the
session's tmux window, so slash commands and your own skills work as they do
at the keyboard.

- **Terminal view** switches to the live tmux pane for menus, prompts and
  anything the chat view cannot show, with a key bar for Enter, Escape, arrows
  and control keys.
- **Interrupt (Esc)** stops the agent mid-turn.
- **Resume in tmux…** restarts a finished session inside tmux so it becomes
  controllable.
- A permission request appears as a card with the tool name and input and
  **Allow** and **Deny** buttons. A prompt the terminal is already showing,
  or a plan waiting for approval, appears as a card with the same choices the
  terminal offers; see
  [permission prompts](../guide/sessions.md#hooks-permission-prompts-and-status).
- The **mode chip** in the header (Manual, Edits, Plan, Auto) shows the
  session's permission mode. Tap it to change it; see
  [Permission mode](../guide/sessions.md#permission-mode).
- A shell command in one of Claude's replies has **Copy**, **Run with !**
  and **Run in a window** under it. Either run path shows you the command
  and asks before running; see
  [Running a suggested command](../guide/sessions.md#running-a-suggested-command).
  Commands run with `!`, from the phone or at the keyboard, appear in the
  chat as a command block with their output.
- A message you send while Claude is busy shows at once as a faded bubble
  marked "Queued", and so do messages queued at the keyboard; see
  [Messages sent while Claude is busy](../guide/sessions.md#messages-sent-while-claude-is-busy).
- The **attach** button in the message box sends a photo or a picture from
  the library for Claude to look at. Images in the conversation show inline;
  tap one to see it full size. See [Images](../guide/sessions.md#images).
- A session that has started subagents shows a strip under its title with
  their count, how many are still working and their tokens. Tap it for the
  list; see [Subagents](../guide/sessions.md#subagents).

The header shows the machine, session status, repository, model and the
account doing the work. A session that is not running inside tmux shows a
read-only notice; see [Sessions](../guide/sessions.md#controllable-or-read-only).

### New session

Pick the machine, **Claude Code** or **Codex**, a repository (see
[choosing where sessions start](../guide/sessions.md#choosing-where-sessions-start)),
a permission mode for Claude Code (**Default (ask)**, **Plan mode**, **Accept
edits**) and an optional first prompt. The session runs inside a tmux session
you can also attach to from a terminal.

### Machines

Machines shows one entry per paired daemon with its reported name, version and
running sessions. Rename it, toggle **Auto-connect** (connect when the app
opens), **Mute notifications** (no alerts or push from this machine),
**Connect now**, or **Forget** it. **Pair machine** adds another.

Each entry lists the machine's addresses as the daemon advertises them, with
the result of the last check and which one carries the connection. Tap an
address to prefer it. Hold one for **Ignore this address**: the app stops
dialling and checking it, and it stays in the list struck through until you
hold it again and choose **Stop ignoring**. Addresses the daemon stops
advertising drop out of the list on the next connection by themselves. This
is the only place the app talks about addresses; everywhere else a machine is
just online, reconnecting, offline or unreachable.

### Accounts & usage

With [claude-swap](https://github.com/ZerkerEOD/claude-swap) installed on the
machine, this page shows which account is active, how much of each quota
window is used and when it resets. Codex rate limits appear when the CLI
reports them. Pull down to refresh; the back arrow returns to the list.

### Settings

- **Open chats at** chooses where a conversation opens: **Bottom** (the
  newest message, the default), **Top of the last message** (the start of
  Claude's latest reply), or **Last read position** (where you left off,
  with a thin "New since you were here" line above anything that arrived
  since). The position is remembered on the phone for each session.
- **Notify while connected** shows local notifications for permission prompts
  and input requests while the app is open or kept alive.
- **Stay connected in the background** (Android) runs a foreground service
  that keeps the connection to the daemon open, with a persistent
  notification. Alerts then arrive from the daemon directly, without a relay.
- **Push relay** enables notifications while the app is closed. See
  [Push notifications](../guide/push.md).
- **Machines** opens the same list as above.
- Links to the privacy policy, terms of service and source code.
