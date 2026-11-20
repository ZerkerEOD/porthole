# Porthole threat model

Produced with the `rafter-secure-design` auth and threat-modeling walks before
any auth or control-plane code was written. Update it when a boundary changes.

## Data-flow diagram

```
[Phone app] ──wss (VPN only, pinned cert, bearer device token)──┐
                                                                 ▼
                                                     [porthole daemon, runs as the user]
                                                       │   │        │          │
            transcript JSONL (read) ◄──────────────────┘   │        │          └──► [tmux] send-keys / capture-pane / pipe-pane
            ~/.claude/projects, ~/.codex/sessions          │        │
                                                           │        └──► [cswap list --json] (read, optional)
   [claude / codex hook process] ──unix socket 0600──────►─┘
                                                           │
   [Cloudflare Worker relay] ◄──https {grant, ciphertext}──┘ (opt-in, Supporter only)
          │
          └──► [FCM] ──► [Apple/Google push] ──► [Phone]
```

Trust boundaries:

1. Phone ↔ daemon (VPN network). Control point: TLS pinning + device token.
2. Hook process ↔ daemon (local unix socket). Control point: filesystem permission.
3. Daemon ↔ tmux and transcript files (same user). No boundary; the daemon is as
   privileged as the user. This is the blast radius if the daemon is compromised.
4. Daemon ↔ relay ↔ FCM (internet). Control point: signed grant, encrypted payload.
5. Store app ↔ relay (internet). Control point: supporter key checked against the entitlement service, plus Play Integrity attestation when `ATTEST_MODE` is on (off by default; App Attest not implemented).

## Auth decisions (docs/auth.md walk)

- **Identity.** End users are the device owner's phones; there are no accounts.
  Identity is the paired device. Hooks are local processes of the same OS user.
  The relay authenticates the app by the credential in its relay URL (and,
  when `ATTEST_MODE` is on, by platform attestation) and the daemon only
  indirectly, via a grant the app obtained.
- **AuthN primitive.** Opaque random 32-byte device tokens, stored on the daemon
  as SHA-256 hashes in `devices.json` (0600), presented as `Authorization:
  Bearer` over TLS. Not JWT: there is one verifier, revocation must be instant,
  and nothing needs to be self-contained. Pairing codes are 8 random base32
  chars, single use, 120 s TTL, compared in constant time, max 5 attempts per
  minute per source address.
- **TLS.** Daemon generates an ECDSA P-256 self-signed certificate on first run
  (valid 10 years, SAN = the configured bind addresses). The QR carries its
  SHA-256 SPKI fingerprint; the app pins that fingerprint and refuses anything
  else. No CA, no system trust store. TLS 1.3 only.
- **AuthZ model.** Flat: any paired device may do anything the daemon can do.
  This is explicit. Per-device scopes (read-only devices, per-workspace
  devices) are a v2 item with a `scopes` field already reserved in
  `devices.json` so it needs no migration.
- **Token lifetime and revocation.** Device tokens do not expire; they are
  revoked by `porthole devices revoke <id>` or by deleting the entry, and the
  WebSocket for that device is closed within one second. Pairing codes are
  removed on use or expiry. Push grants expire at min(subscription renewal,
  30 days) and are revocable by device id at the relay.
- **Service-to-service.** Daemon → relay carries the device's grant, not a
  daemon identity; the relay never trusts a daemon per se. Hook → daemon is
  trusted by socket ownership (0600, in `$XDG_RUNTIME_DIR` or `~/.porthole`).
- **Refuse-list check.** No passwords, no homegrown JWT (grants are PASETO
  v4.public via a maintained library, or Ed25519-signed JSON with a pinned
  algorithm), no trusted-network assumptions beyond the unix socket, no
  tenant ids from requests.

## STRIDE per boundary

### 1. Phone ↔ daemon

- **S** Token theft from a lost phone: tokens live in Keychain/Keystore,
  optional biometric lock in app, instant revocation on the daemon. Token
  theft on the wire: TLS 1.3 with pinning; a rogue AP on the VPN path sees
  ciphertext only. Spoofed daemon: pinning fails closed.
- **T** All traffic is TLS; messages are JSON validated against `proto/`
  schemas with size caps (64 KiB per message, 1 MiB per history page).
- **R** The daemon logs structured warnings (device id, error) through slog;
  there is no per-action audit log. Accepted for a single-user tool; a device's
  `last_seen` in `devices.json` is the only persistent trace of use.
- **I** Error responses are generic (`unauthorized`, `bad_request`). No
  transcript content in logs. `/v1/health` returns only `ok` and version to
  authenticated callers; unauthenticated callers get 401 with no body.
  Session titles and cwd paths are sent to paired devices only.
- **D** Per-connection message rate limit (60 msg/s, burst 120), max 4
  concurrent connections per device, pairing endpoint rate limit, `pane.bytes`
  back-pressure (drop and resend snapshot) so a chatty TUI cannot queue
  unbounded memory.
- **E** None available: all devices are equal and equal to the user.
  Mitigation for the blast radius is the bind policy (nothing reachable off
  the VPN) and revocation.

### 2. Hook ↔ daemon

- **S** Any process running as the user can connect to the socket and claim to
  be a hook. That process could already do anything the user can, so this is
  not an escalation. The daemon still validates the hook payload shape and
  only acts on events whose `transcript_path` resolves inside a watched
  profile.
- **T/I** Socket is 0600 in a 0700 directory. Permission decisions are sent
  back on the same connection only.
- **D** A hook that waits for a phone answer blocks the CLI. Timeout is
  configurable (default 60 s) and the hook exits with no decision on timeout,
  socket error, or daemon absence, so Claude Code falls back to its own prompt.

### 3. Daemon ↔ tmux and files

- The daemon runs as the user, never root, and refuses to start as uid 0.
  `send-keys` is passed with `-l` (literal) and the text as a separate argv
  element, never through a shell. Session and pane targets are validated
  against the set the daemon discovered, not taken from the client as free
  text. Spawn commands use a fixed argv (`claude`, `codex` plus allowlisted
  flags) with the working directory validated to be inside a configured
  workspace after symlink resolution.
- Transcript reads are read-only. Offsets are tracked per real path so a
  symlinked profile is not read twice.

### 4 and 5. Relay

- **S** A grant is minted only for an active supporter key (the relay asks the
  entitlement service) and, when `ATTEST_MODE` is on, only for a store build
  attested by Play Integrity. The grant binds the device id and push token.
- **T** Grants are signed (Ed25519) by a key that exists only as a Worker
  secret. Push payloads are encrypted (XChaCha20-Poly1305) with a key agreed at
  pairing, so the relay, FCM, and the platforms see ciphertext.
- **I** The relay learns the relay credential, device id, platform and push token
  at grant time, the IP addresses of phone and daemon, and per push the fact
  that "device X was pushed at time T" plus an opaque SHA-256 digest of the
  session key used as the collapse id. It never sees the notice content. The
  privacy policy at zerkersec.io/privacy states this.
- **D** Rate-limit bindings per device id (10/min) and per IP on grant
  (5/min), a 300/day KV counter per device, payload cap 480 bytes, free-plan
  hard cap of 100k requests/day fails closed on push only. KV deny list for
  revoked device ids.
- **E** A stolen grant can push only to its own device.

## Negative space

- **Assumed safe:** the VPN itself, the user's own machine, and the two CLIs'
  transcript formats. The first two are out of scope by design. The third is
  mitigated by parsers that ignore unknown entries and fixture tests pinned to
  observed formats.
- **Worst single compromise:** the daemon process. It has the user's full
  access anyway, so the control that matters is not letting anyone reach it:
  bind policy refuses public addresses, and a public bind requires an
  explicit flag with an alarming name.
- **Attacker goals:** read private code and conversations (needs VPN access
  plus a device token), drive the agent to exfiltrate or destroy (same), spam
  pushes (needs a valid relay credential and, when attestation is on, a
  genuine store build), run up Aaron's bill (hard cap, no bill).
- **Incident controls:** `porthole devices revoke` per device, relay deny
  list per device id, relay grant key rotation via a new Worker secret
  (existing grants stop verifying at once; apps re-mint within three days).

## Abuse twins

- Pair a phone → attacker on the VPN brute-forces pairing codes: 8 base32
  chars, 120 s TTL, 5 attempts/min, single use.
- Send input to a session → attacker injects commands into tmux: requires a
  device token; input is literal, never shell-interpreted.
- Approve a permission from the phone → stale approval applied to a different
  prompt: approvals carry the hook's request id and expire with it.
- Spawn a session in a repo → path traversal outside workspaces: resolved path
  must be inside a configured workspace.
- Subscribe to pane bytes → memory exhaustion from a fast TUI: bounded ring
  buffer per subscriber with snapshot resync.

## Residual risks accepted

- A paired device is fully trusted. Single-user tool; per-device scopes are v2.
- Hook socket trusts any same-user process. Equivalent to the user's own
  shell access.
- Audit log is not tamper-evident. Single-user tool.
- iOS background delivery depends on Apple's push service and a relay; users
  without a relay have foreground-only notifications on iOS. Documented.

## Follow-ups

- Tests: bind policy refusal, pairing brute-force limit, token revocation
  closes sockets, send-keys argv never passes through a shell, workspace path
  containment, pane buffer bound.
- `rafter-code-review` plus `rafter run` on `internal/server`, `internal/tmux`,
  `internal/hooks`, and `relay/` before each release.
