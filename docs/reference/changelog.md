# Changelog

Releases of the daemon are on [GitHub](https://github.com/ZerkerEOD/porthole/releases).
The app ships through the App Store and Google Play; its version is shown in
Settings, About.

## 0.2.0 (2026-11-27)

Needs app 1.0 or newer. If you upgrade from 0.1.0, read the
[upgrading note](../getting-started/install.md#upgrading) first.

What you can do from the phone that you could not before:

- Answer Claude Code's questions. When Claude asks you to choose between options, the
  choices appear in the chat and your answer is typed into the session. Questions that
  are only visible in the terminal are read from the screen and offered the same way.
- Approve plans, with the full plan shown on the card, and change the permission mode
  (manual, accept edits, plan, auto) from the session header.
- Run a command Claude suggested, either inside the session with Claude's own `!`
  shortcut or in a separate window whose output is sent back into the conversation.
- Send a photo for Claude to look at, and see images Claude refers to inline.
- See the subagents a session has started, and a short summary when one finishes.
- See the messages you sent while Claude was busy, queued in order, before the session
  picks them up. The terminal view has a "Send now" key for them.
- Choose where a chat opens: at the bottom, at the start of Claude's latest reply, or
  where you left off, with a marker above what is new since then.

Smaller changes:

- Session rows and machine chips use one set of states and icons; a legend explains
  them. Busy is blue, attention is amber.
- The app tries the LAN and VPN addresses of a machine at the same time and shows
  which one answered. `porthole status` lists the addresses the daemon is listening on
  and the last connection attempts; `porthole doctor` mentions the firewall port.
- Push notifications go only to phones that opened the session, once per thing that
  needs you.
- Restarting or upgrading the daemon no longer stops the sessions it started.
- `porthole add`, `porthole remove` and `porthole repos` manage the repositories offered
  when you start a session; `porthole install` waits for the daemon to come up before
  running its checks.

## 0.1.0 (2026-11-22)

First release: the daemon with pairing, the session list, the conversation and terminal
views, permission prompts on the phone, new sessions from the app, several machines in
one list, the optional push relay, and account usage through claude-swap.
