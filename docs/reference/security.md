# Security

How Porthole secures the paths between the phone, the daemon, the agent CLIs
and the optional push relay. The pairing steps are in
[Pair a phone](../getting-started/pairing.md) and the push setup is in
[Push notifications](../guide/push.md).

## Components and boundaries

The phone app talks to the daemon over a WebSocket on a LAN or VPN address,
with TLS 1.3 and a self-signed certificate the app pins at pairing. The daemon
runs as the user who owns the agent sessions and refuses to start as root. It
reads agent transcripts from disk, receives hook events over a local unix
socket, drives terminals through tmux, and, when a relay URL is configured,
posts encrypted notices to the relay, which forwards them through FCM. The
phone and the hook process cross a boundary (the pinned certificate with the
device token, and the socket file permission); the daemon and the user's tmux
panes and transcript files do not, since the daemon has the same access as the
user.

```
[Phone app] ──wss, TLS 1.3, pinned certificate, bearer device token──┐
   (LAN or VPN address only)                                          ▼
                                                      [porthole daemon, runs as the user]
                                                        │        │           │
   transcript JSONL (read only) ◄───────────────────────┘        │           └──► [tmux] send-keys, paste-buffer, capture-pane
   <profile>/projects, <codex home>/sessions                     │
                                                                 │
   [agent CLI hook process] ──unix socket, mode 0600────────────►┘
                                                                 │
   [relay (Cloudflare Worker)] ◄──https {grant, ciphertext, collapse}──┘  (only when push.relay_url is set)
          │
          └──► [FCM] ──► [Apple or Google push service] ──► [Phone]
```

## Phone authentication

`porthole pair` asks the daemon over the local socket for a pairing code and
prints a QR code carrying the daemon name, the advertised addresses, the port,
the certificate fingerprint and the code. The code is 8 characters of base32
from 5 random bytes, valid for 120 seconds, and deleted on first use. The
daemon keeps only a SHA-256 hash of it in memory and compares hashes in
constant time. A source address that fails five times in one minute is refused
until the window passes, and `POST /v1/pair` as a whole admits one request
every two seconds with a burst of ten.

A successful pairing returns a device id and a 32-byte random token, base64url
encoded, sent to the app once. The daemon stores the token's SHA-256 in
`devices.json` (mode 0600, written through a temporary file and a rename)
under the state directory, `$XDG_STATE_HOME/porthole` or
`~/.local/state/porthole`, mode 0700. The app stores the token with the hosts,
port and fingerprint in the platform keystore. Every request carries
`Authorization: Bearer <token>`; a WebSocket client may instead pass it as the
subprotocol `porthole.token.<token>`. Tokens do not expire. `porthole devices`
lists paired devices and `porthole devices revoke <id>` removes one; the daemon
closes that device's open connections within one second, and the app treats
the next 401 as a revocation and asks the user to pair again.

On first run the daemon generates an ECDSA P-256 self-signed certificate valid
for ten years and writes `tls.crt` and `tls.key` to the state directory with
mode 0600. The fingerprint in the QR code is the base64url SHA-256 of the
certificate's DER encoding. The app builds its TLS context with no trusted
roots and accepts a certificate only when its fingerprint matches the stored
one; a different certificate fails the handshake and the app reports
"Certificate changed. Pair again." The daemon accepts TLS 1.3 only. Deleting
`tls.crt` and `tls.key` and restarting the daemon rotates the certificate, and
every phone must then re-pair.

## Network exposure

With the default `listen = ["auto"]` the daemon binds every loopback,
link-local IPv4, RFC 1918, CGNAT (100.64.0.0/10) and IPv6 ULA address on an
interface that is up, plus every address on an interface whose name starts
with `tailscale`, `wg`, `utun`, `tun`, `nebula` or `zt`; interfaces named
`docker`, `br-`, `veth`, `virbr`, `lxc`, `cni`, `flannel` or `podman` are
skipped. 127.0.0.1 is always bound, the list is re-evaluated every ten seconds
so a VPN interface that appears later is picked up, and the default port is
7433. An explicit listen address outside those ranges is refused at startup
unless `porthole serve` is given `--allow-public-bind-i-understand`.
Independently of binding, every accepted request is checked against the same
address classes and a public source address receives 403 unless that flag is
set. Without a valid token a caller reaches only `POST /v1/pair`; every other
route returns 401 with an empty body.

The control socket `porthole.sock` lives in `$XDG_RUNTIME_DIR/porthole` (or
`run/` under the state directory when that variable is unset), with the
directory at 0700 and the socket at 0600. It carries the CLI commands (pair,
devices, revoke, status, config reload) and the hook events, with no
authentication beyond the file permission: any process running as the same
user can use it, which equals that user's shell access.

## What a phone can do

Every paired phone holds the same rights; there are no per-device scopes. Over
the WebSocket a phone can:

- list sessions, including title and working directory, and subscribe to the
  transcript events and the tmux screen of any session the daemon discovers;
- page through transcript history (the daemon only reads transcript files);
- send text to a session that has a tmux pane. The daemon passes the text to
  `send-keys -l` (or `set-buffer` and `paste-buffer` for multi-line text) as a
  separate argument, never through a shell, and takes the pane id from its own
  session list rather than from the client;
- press named keys from a fixed allowlist (Enter, Escape, arrows, C-c and the
  like) or single printable characters, up to 32 per message;
- answer a pending permission prompt with allow or deny. The daemon holds the
  hook open only while a phone subscribes to that session, gives each prompt a
  random id, and accepts an answer only for an id that is still pending. After
  `hooks.permission_timeout_s` (default 60) the hook returns no decision and
  the terminal prompt appears as usual;
- start a session. The daemon builds the argv itself from the configured
  binary, the `--resume`, `--permission-mode` and `--model` values (at most 64
  characters each, letters, digits and `-_.:[]` only), and the prompt after
  `--`. The directory passes `insideWorkspace` in
  `daemon/internal/core/registry.go`: after symlink resolution it is inside a
  configured workspace or an added repository, or it is exactly a directory an
  agent session has already run in;
- register or clear its push grant.

Per connection the daemon reads at most 64 KiB per message, allows 60 messages
per second with a burst of 120, admits four connections per device, and
coalesces screen snapshots per session so a fast terminal cannot queue
unbounded output.

A stolen phone or token therefore reads code and conversations, types into
running agents, answers their permission prompts and starts new agents in the
allowed directories, from any address that reaches the daemon. There is no
second factor; the mitigation is `porthole devices revoke`, which takes effect
within a second, and keeping the daemon reachable only over the VPN.

Hook events arrive through `porthole hook`, which `porthole install-hooks`
registers for the session, prompt, stop, notification and permission events,
and through the Codex `notify` program `porthole codex-notify`, which only
reports completed turns. The daemon acts on a hook only when its
`transcript_path`, after symlink resolution, lies under the `projects`
directory of a watched profile; otherwise it logs a warning and returns no
decision.

## Push relay

Push is off until `push.relay_url` names an https URL. At pairing the app
generates an X25519 key pair and sends the public key; the daemon generates its
own pair, derives a 32-byte key with HKDF-SHA256 over the shared secret and the
info string `porthole-push-v1`, stores that key in `devices.json`, returns its
public key and discards its private key. The app derives the same key and
stores it in the keystore.

A notice is a JSON object with the kind (permission, input or done), the
session key, the title clipped to 80 characters, the daemon name and a
timestamp. The daemon seals it with XChaCha20-Poly1305 under the pairing key
with a random 24-byte nonce; the ciphertext is capped at 480 bytes. The relay,
FCM and the platforms carry only that ciphertext, and the APNs alert text is
the fixed "A session needs your attention".

The app obtains a grant with `POST /v1/grant`, sending a random device id it
generates, the platform, the FCM registration token, and the credential from
the relay URL's userinfo as a bearer token. The relay limits grant requests to
5 per minute per client IP, rejects device ids on its deny list, optionally
requires platform attestation (`ATTEST_MODE`; `android` verifies Play
Integrity, iOS verification is not implemented, so `all` refuses iOS), and
asks the entitlement service (an HTTPS endpoint sharing `ENTITLEMENT_SECRET`)
or, on a self-hosted relay, a static list of credential SHA-256 hashes whether
the credential is active. The grant is the JSON payload `{v, d, t, p, iat,
exp}` base64url encoded, a dot, and an Ed25519 signature over that encoding
made with a key held as a Worker secret; `GET /v1/pubkey` returns the
verification key. It expires at the end of the entitlement period or after 30
days, whichever is sooner. The app registers the grant with each daemon over
the WebSocket and renews it when fewer than three days remain.

The daemon posts `{grant, ct, collapse}` to `POST /v1/push` for each device
that holds a live grant and is not connected, at most once per device, session
and kind every 45 seconds; `collapse` is the first 32 hex characters of the
SHA-256 of the session key. The relay verifies the signature and expiry, checks
the deny list, enforces 10 pushes per minute per device id and 300 per day (a
KV counter that expires after two days), and forwards to FCM. A 400 or 404 from
FCM becomes a 410, on which the daemon drops the grant.

At grant time the relay sees the relay credential, device id, platform, push
token and client IP; per push it sees the grant contents, the ciphertext, the
collapse digest and the time. It keeps no subscriber list; its KV namespace
holds the deny list (device ids the operator writes) and the daily counters.
Rotating the signing key invalidates every grant at once. A self-hosted relay
runs the same code with the static credential list in place of the entitlement
service; the encryption, grant format and limits are unchanged.

## Threat summary

| Threat | Control | Residual risk |
| --- | --- | --- |
| Public internet exposure | Bind and source-address policy admit only loopback, private, CGNAT, ULA and VPN addresses; public addresses need `--allow-public-bind-i-understand` | A host that sets the flag, or a VPN that admits strangers, exposes the daemon to anyone who can reach it |
| Stolen phone or device token | Token hashed at rest, kept in the phone keystore, revocable with `porthole devices revoke`, connections closed within a second | Until revocation the holder has every right a paired phone has; no second factor |
| Malicious prompt in a transcript driving the agent | Phone input is literal keystrokes; permission prompts reach the phone with tool name and input for a human decision | A prompt approved from the phone runs with the user's rights, as it would in the terminal |
| Relay compromise | Notices are encrypted end to end with a key the relay never holds; grants bind one device id and push token | The relay operator learns push tokens, device ids, timing and the per-session collapse digest, and can suppress or delay pushes |
| Hook tampering | Hook payloads are accepted only for transcripts under a watched profile; answers match a pending prompt id; a hook timeout yields no decision | Any process of the same user can connect to the socket and inject events, which equals that user's shell access |
| Local user on the machine | State directory 0700, `devices.json`, `tls.key` and the socket 0600; the daemon refuses to run as root | The same user, or root, reads tokens, the push key and every transcript |
