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
machine, **Claude** or **Codex**. Sessions that need you (a permission prompt, a
question) move to the top with a badge. Finished sessions are under
**History**. **New session** starts an agent on a repository of a connected
machine. A machine's menu offers **Connect now**, **Accounts & usage**,
**Open machine view** and **Manage machines**.

### Session

The session screen renders the conversation from the CLI's own transcript:
prompts, replies, tool calls and results, and with **Show thinking** the
model's thinking. Scroll up to **Load earlier**. The input bar types into the
session's tmux window, so slash commands and your own skills work as they do
at the keyboard.

- **Terminal view** switches to the live tmux pane for menus, prompts and
  anything the chat view cannot show, with a key bar for Enter, Escape, arrows
  and control keys.
- **Interrupt (Esc)** stops the agent mid-turn.
- **Resume in tmux…** restarts a finished session inside tmux so it becomes
  controllable.
- A permission request appears as a card with the tool name and input and
  **Allow** and **Deny** buttons.

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

### Accounts & usage

With [claude-swap](https://github.com/ZerkerEOD/claude-swap) installed on the
machine, this screen shows which account is active and how much of each quota
window is used. Codex rate limits appear when the CLI reports them.

### Settings

- **Notify while connected** shows local notifications for permission prompts
  and input requests while the app is open or kept alive.
- **Stay connected in the background** (Android) runs a foreground service
  that keeps the connection to the daemon open, with a persistent
  notification. Alerts then arrive from the daemon directly, without a relay.
- **Push relay** enables notifications while the app is closed. See
  [Push notifications](../guide/push.md).
- **Machines** opens the same list as above.
- Links to the privacy policy, terms of service and source code.
