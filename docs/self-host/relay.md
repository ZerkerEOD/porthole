# Self-hosting the push relay

The relay is only needed for background push on phones. The app takes any
relay URL in **Settings → Push relay**; the project hosts one for its
supporters (<https://zerkersec.io/supporter> hands out a personal URL; see
[Push notifications](../guide/push.md)), and this page is how to run your own.

## The relay URL

The app accepts `https://[credential@]host[/path]`. The optional userinfo is
the relay credential: the app sends it as `Authorization: Bearer` on the grant
request and never interprets it. A relay with `ENTITLEMENT_STATIC_KEYS` hands
out credentials of the form `PH-XXXX-XXXX-XXXX-XXXX`; a relay backed by an
entitlement service uses whatever that service issues. The daemon only needs
the base URL (no credential) in `[push] relay_url`.

## What it needs

| Secret / var | Purpose |
|---|---|
| `GRANT_SIGNING_KEY` | Ed25519 private key (PKCS8, base64url) that signs push grants. Generate: `node -e "crypto.subtle.generateKey({name:'Ed25519'},true,['sign','verify']).then(async k=>console.log(Buffer.from(await crypto.subtle.exportKey('pkcs8',k.privateKey)).toString('base64url')))"` |
| `FCM_SERVICE_ACCOUNT` | Firebase service account JSON with the **Firebase Cloud Messaging API** role |
| `FCM_PROJECT_ID` (var) | Firebase project id (optional; read from the service account otherwise) |
| `ENTITLEMENT_URL` (var) + `ENTITLEMENT_SECRET` | an HTTPS endpoint that answers whether a credential is active (see below) |
| `ENTITLEMENT_STATIC_KEYS` (var) | alternative for a personal relay: comma-separated SHA-256 hex hashes of the credentials you hand out yourself |
| `ATTEST_MODE` (var) | `off`, `android` (Play Integrity) or `all`; iOS App Attest is not yet implemented, so `all` refuses iOS grants. The store builds send no attestation today, so leave it `off` for them |
| `DENY` (KV) | revoked device ids and daily counters |

Keep the origin of record for every secret outside the repo; set them with
`wrangler secret put`.

The service account must belong to the Firebase project the app was built
with: push tokens are issued per project, and the relay can only send to
tokens of the project it holds a service account for. The store builds carry
the project's own Firebase options, so they only work with the hosted relay.
To use your own relay, [build the app](app.md) with your own project.

### The entitlement contract

The relay never decides who may push. It calls
`POST $ENTITLEMENT_URL` with `Authorization: Bearer $ENTITLEMENT_SECRET` and
body `{"key": "<credential>", "device_id": "...", "platform": "ios|android"}`
and expects `{"active": true|false, "period_end": "<ISO 8601>", "level": 0, "tier": null, "reason": "..."}`.
`level` and `tier` are optional: a tier level (1 and up) and its name, passed
back to the app on the grant response. Omit them or send 0 for a flat yes/no.
Status 404 means unknown credential, 429 means too many devices on that
credential. The grant it mints expires at `period_end` or 30 days, whichever
is sooner, and the app re-mints within three days of expiry, so revoking a
credential on your side takes effect by the next refresh. Any backend that
follows this contract works; Porthole's own is the supporter service at
zerkersec.io.

## Deploy

```sh
cd relay
npm install
npx wrangler kv namespace create DENY     # put the id into wrangler.jsonc
# remove the "routes" entry in wrangler.jsonc (it is the project's custom domain)
npx wrangler secret put GRANT_SIGNING_KEY
npx wrangler secret put FCM_SERVICE_ACCOUNT
npx wrangler secret put ENTITLEMENT_SECRET   # or set ENTITLEMENT_STATIC_KEYS as a var
npx wrangler deploy
```

Then [build the app](app.md) with the same Firebase project, paste
`https://<credential>@your-worker.workers.dev` into Settings → Push relay, and
set `[push] relay_url` in the daemon config to the base URL.

## How a push travels

1. The user pastes a relay URL into the app, which obtains a platform push
   token from FCM.
2. The app asks the relay for a grant: `POST /v1/grant` with the credential
   as a bearer token. The relay asks the entitlement service whether it is
   active and returns a signed grant binding the device id and push token,
   valid for at most 30 days.
3. The app hands the grant to each paired daemon over the VPN.
4. When a session needs you and the phone is not connected, the daemon
   encrypts a notice with the key agreed at pairing and posts
   `{grant, ct}` to the relay.
5. The relay checks the signature, expiry, deny list and rate limits, then
   sends the ciphertext through FCM. The phone decrypts it and shows the
   notification, and the app fetches details from the daemon on open.

The relay never sees session content, repository names or prompts. It sees a
push token, a device id and a timestamp.

## Blocking a device

```sh
npx wrangler kv key put --binding DENY <device-id> 1
```

## Rotating the grant key

Set a new `GRANT_SIGNING_KEY`; existing grants stop verifying immediately and
apps re-mint on their next refresh (within three days of a grant's expiry).
