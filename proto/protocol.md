# Porthole wire protocol v1

Transport: `wss://<host>:<port>/v1/ws`, TLS 1.3, self-signed certificate
pinned by SHA-256 of the DER leaf (base64url, no padding). Header
`Authorization: Bearer <device-token>`. Subprotocol `porthole.v1`.

Every frame is a JSON text message:

```json
{"type": "<name>", "id": "<optional request id>", "payload": { ... }}
```

Client requests carry an `id`; the daemon answers with `{"type":"result","id":...,"payload":{"ok":bool,"error"?:string,"data"?:any}}`.
Unsolicited daemon messages have no `id`. Max frame 64 KiB from the client;
the daemon may send larger history pages (up to ~1 MiB).

## Pairing (HTTPS, no auth)

`POST /v1/pair` `{"code":"ABCDEFGH","device_name":"iPhone","push_key"?:"<b64 X25519 pub>"}` →
`{"device_id","token","name","version","protocol"}`. The code comes from
`porthole pair` as a QR with URL `porthole://pair?d=<base64url JSON>` where the
JSON is `{"v":1,"name","hosts":[...],"port","fp","code","exp"}`. Codes are single
use, expire after 120 s, and five failures per minute per source address lock
that source out for a minute.

## Daemon → client

| type | payload |
|---|---|
| `hello` | `{name, version, protocol, device, hosts?:[string], sessions:[Session], accounts, permissions:[PermissionRequest], runs:[Run], features:{claude,codex,push,tmux}}` sent once after connect. `hosts` is optional: the daemon's current advertised addresses, VPN first, in the same form as the pairing payload, so the app can refresh the addresses it stored at pairing |
| `session.upsert` | `Session` |
| `session.replaced` | `{old, new}` when a spawn placeholder (`<provider>:pending:<pane>`) becomes a real session: sent after the real session's `session.upsert` and before the placeholder's `session.removed` |
| `session.removed` | `{key}` |
| `event` | `{key, events:[Event]}` for subscribed sessions |
| `pane.snapshot` | `{key, run_id?, pane_id?, screen:{lines:[ansi strings], cursor_x, cursor_y, width, height, in_mode}}` for pane subscriptions; coalesced so only the latest is delivered. `run_id`/`pane_id` are set for a run window |
| `agent.events` | `{key, agent_id, events:[Event]}` for subscribed subagent transcripts |
| `run.update` | `Run` whenever a command run from the phone starts, prints, exits or is dismissed |
| `permission.pending` | `PermissionRequest` |
| `permission.resolved` | `{id, behavior: allow\|deny\|timeout\|cancelled\|gone\|replaced}` (`gone`/`replaced` for prompts read off the terminal that left the screen) |
| `accounts.update` | `AccountsSnapshot` |

## Client → daemon

| type | payload | result data |
|---|---|---|
| `ping` | `{}` | `{pong}` |
| `session.list` | `{}` | `[Session]` |
| `session.subscribe` | `{key, before?, limit?}` | `{key, events, has_more}` latest page; then `event` pushes |
| `session.unsubscribe` | `{key}` | |
| `history.page` | `{key, before, limit, agent_id?}` | `{key, agent_id?, events, has_more}` events with seq < before; with `agent_id`, from that subagent's transcript |
| `agent.subscribe` | `{key, agent_id, before?, limit?}` | `{key, agent_id, events, has_more}` latest page of a subagent transcript (read-only); then `agent.events` pushes |
| `agent.unsubscribe` | `{key, agent_id}` | |
| `session.mode` | `{key, mode}` | `{key, mode}` presses Shift+Tab in the pane until the status bar names `mode` (default, acceptEdits, plan, auto; bypassPermissions only when the session started with it). Fails with the mode reached when the target is not in the cycle or a dialog is open |
| `session.run` | `{key, command, feed}` | `{id}` runs `command` with `sh` in a new tmux window next to the session (`ph-run-<id>`), streaming `run.update`; with `feed` the output is typed into the session as a message when the command exits. At most 4 running per session; `command` ≤ 4 KB |
| `run.stop` | `{key, id}` | | sends Ctrl-C to the run window |
| `run.dismiss` | `{key, id}` | | kills the window and drops the run |
| `run.list` | `{key?}` | `{runs:[Run]}` |
| `session.input` | `{key, text, enter}` | | types literal text into the tmux pane (`enter` presses Enter) |
| `session.keys` | `{key, keys:[...]}` | | named keys: Enter Escape Tab BTab Up Down Left Right Home End PageUp PageDown C-c C-d C-u C-l C-z … or single printable characters |
| `session.spawn` | `{provider, dir, resume?, prompt?, permission_mode?, model?}` | placeholder `Session` (`pending:true`); the real session replaces it with the same `pane_id` |
| `pane.subscribe` | `{key, run_id?, pane_id?}` | `{key, run_id?, pane_id?, screen}` then `pane.snapshot` pushes; with `run_id` or a run's `pane_id`, the run window instead of the session's pane |
| `pane.unsubscribe` | `{key, run_id?, pane_id?}` | |
| `pane.resize` | `{key, cols, rows}` | | only for sessions Porthole spawned |
| `permission.answer` | `{id, behavior?: allow\|deny, option?}` | | for a hook-held prompt, `behavior`; for a prompt read off the terminal (`recovered`), `option` picks one of its `options` by index (`behavior` maps to the first Yes / No) |
| `question.answer` | `{key, id, answers:[Answer]}` | `{ok, reason?}` | answers the session's pending `question` (same `id`) by driving the dialog in the tmux pane; one `Answer` per question, in order. `ok:false` with a `reason` when the dialog is not on screen, the answers do not fit the questions, or the screen ended up in a state the daemon does not recognize (`reason` then carries the last pane lines) |
| `repos.list` | `{}` | `[Repo]` |
| `skills.list` | `{provider?, repo?}` | `[Skill]` |
| `accounts.get` | `{}` | `AccountsSnapshot` |
| `push.register` | `{grant, expires_at}` | | stores the relay grant for this device; refused unless the daemon has `[push] relay_url` set |
| `push.unregister` | `{}` | | drops the grant; the daemon stops pushing to this device |

## Types

**Session** `{key, id, provider: claude|codex, title, cwd, repo, branch, profile, status, running, controllable, pane_id?, tmux_session?, pid?, kind?, model?, account?, last_prompt?, started_at, updated_at, size?, spawned?, pending?, question?, permission_mode?, last_denied?, agents?:[AgentInfo], agents_total?, usage?:Usage}`

`permission_mode` is the Claude Code mode (`default acceptEdits plan auto dontAsk bypassPermissions`) from the last hook or the status bar. `last_denied` `{tool, at}` is the last action auto mode refused. `agents` lists the session's subagents (every running one and the 40 most recent finished; `agents_total` counts all), `usage` the session's own token totals without them. A session whose transcript is idle but has running subagents or pending background tasks reports `busy`.

**AgentInfo** `{id, type, description, tool_use_id?, background, finished, running, started_at?, updated_at?, turns, tool_uses, usage:Usage, model?, last_text?}`. **Usage** `{input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens}` (all omitempty).

**Run** `{key, id, command, state: running|done|stopped, exit?, tail, started_at, ended_at?, fed, queued, pane_id, device}`: a command started with `session.run`. `tail` is the last 40 lines (8 KB) of its output; `fed` says the output was typed into the session, `queued` that the session was busy and the CLI holds it for the next turn.

**PermissionRequest** `{id, session_key, tool_name, tool_input?, cwd?, created_at, expires_at?, recovered?, prompt?, description?, detail?, options?:[string]}`. A hook-held request carries `tool_input` and takes `permission.answer {behavior}`. A `recovered` request describes the dialog the CLI drew in the terminal (read off the pane): `tool_name` is the dialog's header ("Bash command", "Create file", "Plan approval"), `detail` the command, file content or the full plan, `options` the choices as numbered on screen; answer it with `permission.answer {option}`.

`status` ∈ `unknown idle busy waiting_permission waiting_input exited`. `key` is `<provider>:<session id>`.

`question` is present while a Claude Code `AskUserQuestion` dialog is open and `status` is then `waiting_input`:
`{id, questions:[{question, header, multiSelect, options:[{label, description, preview?}]}], recovered?, remaining?}`. `questions` is the tool input as the CLI reported it (`preview` is the optional code or layout sample attached to an option); `id` is opaque and is echoed in `question.answer`. The field disappears once the dialog is answered or dismissed. A push notice of kind `input` is sent for it.

When the daemon did not see the dialog open (it restarted, or the hook never reached it) it reads the dialog off the terminal instead and sets `recovered: true`. Only the question on screen is visible then, so `questions` holds that one item (its `header` is the dialog's tab label, empty for a single-question dialog; `description` is what the screen shows and `preview` is never set) and `remaining` is how many unanswered questions follow it (absent when 0). Answer it with one `Answer`; on success the next question, if any, is published as a new `question` with a new `id`, and the last answer submits the dialog.

**Answer** `{index?, indices?:[int], text?, notes?}`: `index` picks one option of a single-select question, `indices` the options of a multi-select one, `text` fills the free-text row (alone for a single select; with or without `indices` for a multi select). Indices are zero-based positions in `options`. `notes` is a note on the chosen option and is only valid with `index` on a single select; this daemon accepts it but does not yet type it into the dialog (it is dropped with a log line).

**Event** `{seq, type, ts, id?, parent_id?, message_id?, turn_id?, sidechain?, agent_id?, text?, truncated?, tool?:{id,name,input}, result?:{tool_use_id,is_error}, status?, usage?, model?, level?, meta?}`

Event types include `user`, `assistant.text`, `assistant.thinking`, `tool.use`, `tool.result`, `status`, `compact`, `model_switch`, `usage`, `system` and `command`. A `command` event is a shell command the person ran in the session with the CLI's `!` prefix (`text` is the command, `meta` `{source:"bang", stdout, stderr}`, each capped at 20 KB) or a slash command's output (`text` empty, `meta.source:"slash"`). A `system` event with `meta.kind:"task_notification"` is the CLI's notice that a background subagent or command finished (`agent_id` names the agent; `text` reads like `Agent "…" finished · 64k tokens · 15 tool uses · 1m 32s`).

`type` ∈ `meta user assistant.text assistant.thinking tool.use tool.result status usage model_switch compact system`.
`seq` is monotonic per session and stable across reconnects for the daemon's lifetime. Text over 16 KiB is clipped with `truncated:true`.

**PermissionRequest** `{id, session_key, tool_name, tool_input, cwd, created_at, expires_at}`

**AccountsSnapshot** `{fetched_at, claude?: {fetched_at, raw: <cswap list --json document>, active_email, schema_version}, codex?: {email, rate_limits:{plan, primary:{used_percent, window_minutes, resets_at}, secondary:{...}}, seen_at}}`

**Repo** `{name, path, workspace?, source: workspace|repo|recent, branch?, last_used?, last_provider?}` · **Skill** `{name, description, source: user|project|plugin|builtin, provider, path?}`

## Notifications

Push notices (kinds `permission`, `input`, `done`) go only to devices that are not connected and have opened the session (`session.subscribe`, `pane.subscribe` or `session.spawn` from that device within the last 7 days), or for any session the daemon spawned. Each kind is sent at most once per wait: a wait starts when the session stops working and ends on the next prompt, permission answer or question answer (for Codex, also any return to busy). A turn end sends `done` only if the session is still idle 2 s later and has no running subagents or pending background tasks; while such work is pending the notice is held and sent once the work is done and the session has been idle for 20 s, or dropped if the session resumes. An idle prompt sends `input` only when neither `done` nor `input` went out in that wait.

## REST (same auth)

`GET /v1/health`, `GET /v1/sessions`, `GET /v1/sessions/{key}/history?before=&limit=`, `GET /v1/repos`, `GET /v1/skills?provider=&repo=`, `GET /v1/accounts`, `POST /v1/sessions/spawn`.

## Local control socket

`$XDG_RUNTIME_DIR/porthole/porthole.sock` (0600), plain HTTP: `GET /status`, `POST /pair/new`, `GET /devices`, `POST /devices/revoke`, `GET /sessions`, `GET /notes`, `POST /hook` (Claude Code hook JSON in, hook JSON out), `POST /codex-notify`.
