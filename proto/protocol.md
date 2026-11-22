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
| `hello` | `{name, version, protocol, device, hosts?:[string], sessions:[Session], accounts, permissions:[PermissionRequest], features:{claude,codex,push,tmux}}` sent once after connect. `hosts` is optional: the daemon's current advertised addresses, VPN first, in the same form as the pairing payload, so the app can refresh the addresses it stored at pairing |
| `session.upsert` | `Session` |
| `session.removed` | `{key}` |
| `event` | `{key, events:[Event]}` for subscribed sessions |
| `pane.snapshot` | `{key, screen:{lines:[ansi strings], cursor_x, cursor_y, width, height, in_mode}}` for pane subscriptions; coalesced so only the latest is delivered |
| `permission.pending` | `PermissionRequest` |
| `permission.resolved` | `{id, behavior: allow\|deny\|timeout\|cancelled}` |
| `accounts.update` | `AccountsSnapshot` |

## Client → daemon

| type | payload | result data |
|---|---|---|
| `ping` | `{}` | `{pong}` |
| `session.list` | `{}` | `[Session]` |
| `session.subscribe` | `{key, before?, limit?}` | `{key, events, has_more}` latest page; then `event` pushes |
| `session.unsubscribe` | `{key}` | |
| `history.page` | `{key, before, limit}` | `{key, events, has_more}` events with seq < before |
| `session.input` | `{key, text, enter}` | | types literal text into the tmux pane (`enter` presses Enter) |
| `session.keys` | `{key, keys:[...]}` | | named keys: Enter Escape Tab BTab Up Down Left Right Home End PageUp PageDown C-c C-d C-u C-l C-z … or single printable characters |
| `session.spawn` | `{provider, dir, resume?, prompt?, permission_mode?, model?}` | placeholder `Session` (`pending:true`); the real session replaces it with the same `pane_id` |
| `pane.subscribe` | `{key}` | `{key, screen}` then `pane.snapshot` pushes |
| `pane.unsubscribe` | `{key}` | |
| `pane.resize` | `{key, cols, rows}` | | only for sessions Porthole spawned |
| `permission.answer` | `{id, behavior: allow\|deny}` | |
| `repos.list` | `{}` | `[Repo]` |
| `skills.list` | `{provider?, repo?}` | `[Skill]` |
| `accounts.get` | `{}` | `AccountsSnapshot` |
| `push.register` | `{grant, expires_at}` | | stores the relay grant for this device; refused unless the daemon has `[push] relay_url` set |
| `push.unregister` | `{}` | | drops the grant; the daemon stops pushing to this device |

## Types

**Session** `{key, id, provider: claude|codex, title, cwd, repo, branch, profile, status, running, controllable, pane_id?, tmux_session?, pid?, kind?, model?, account?, last_prompt?, started_at, updated_at, size?, spawned?, pending?}`

`status` ∈ `unknown idle busy waiting_permission waiting_input exited`. `key` is `<provider>:<session id>`.

**Event** `{seq, type, ts, id?, parent_id?, message_id?, turn_id?, sidechain?, agent_id?, text?, truncated?, tool?:{id,name,input}, result?:{tool_use_id,is_error}, status?, usage?, model?, level?, meta?}`

`type` ∈ `meta user assistant.text assistant.thinking tool.use tool.result status usage model_switch compact system`.
`seq` is monotonic per session and stable across reconnects for the daemon's lifetime. Text over 16 KiB is clipped with `truncated:true`.

**PermissionRequest** `{id, session_key, tool_name, tool_input, cwd, created_at, expires_at}`

**AccountsSnapshot** `{fetched_at, claude?: {fetched_at, raw: <cswap list --json document>, active_email, schema_version}, codex?: {email, rate_limits:{plan, primary:{used_percent, window_minutes, resets_at}, secondary:{...}}, seen_at}}`

**Repo** `{name, path, workspace?, source: workspace|repo|recent, branch?, last_used?, last_provider?}` · **Skill** `{name, description, source: user|project|plugin|builtin, provider, path?}`

## REST (same auth)

`GET /v1/health`, `GET /v1/sessions`, `GET /v1/sessions/{key}/history?before=&limit=`, `GET /v1/repos`, `GET /v1/skills?provider=&repo=`, `GET /v1/accounts`, `POST /v1/sessions/spawn`.

## Local control socket

`$XDG_RUNTIME_DIR/porthole/porthole.sock` (0600), plain HTTP: `GET /status`, `POST /pair/new`, `GET /devices`, `POST /devices/revoke`, `GET /sessions`, `GET /notes`, `POST /hook` (Claude Code hook JSON in, hook JSON out), `POST /codex-notify`.
