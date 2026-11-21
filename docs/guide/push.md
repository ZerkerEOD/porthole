# Push notifications

While the app is open, or kept alive on Android, it hears about permission
prompts and finished turns directly from the daemon over the VPN. Once the app
is closed (and on iOS, as soon as it leaves the foreground; see
[iOS background behavior](../reference/ios-background.md)) nothing can reach
it except the platform push service. That needs a server holding the app's
push credentials, which is the one piece of Porthole that is not on your
machine: the **push relay**.

The relay is optional. Everything else in Porthole works without it.

## What the relay sees

The daemon encrypts a tiny notice (session title, machine name, what kind of
attention is needed) with a key agreed at pairing and posts the ciphertext to
the relay. The relay checks a signed grant and forwards the ciphertext through
FCM to the phone, which decrypts it and shows the notification. The relay sees a
push token, a random device id and a timestamp; never a prompt, a repository
name or any session content. The app fetches the details from your machine when
you open it.

## Use the hosted relay

The project runs a relay at `relay.zerkersec.io` for its supporters. Supporting
ZerkerEOD at <https://zerkersec.io/supporter> gives you a personal relay URL of
the form

```
https://PH-XXXX-XXXX-XXXX-XXXX@relay.zerkersec.io
```

The part before the `@` is your relay credential. The app sends it to the relay
as a bearer token and never interprets it.

1. On the phone: **Settings → Push relay**, paste the URL, tap **Connect**. The
   app asks for notification permission, fetches a grant from the relay, and
   hands that grant to every paired machine.
2. On each machine: set the relay's base URL (no credential) in
   `~/.config/porthole/config.toml` and restart the daemon:

    ```toml
    [push]
    relay_url = "https://relay.zerkersec.io"
    ```

    ```sh
    systemctl --user restart porthole      # Linux
    ```

    A daemon with an empty `relay_url` refuses push registrations, so the app
    shows the relay as connected but that machine never pushes.

## Run your own

Any relay that speaks the same small API works; the app accepts
`https://[credential@]host[/path]`. See
[Self-hosting the push relay](../self-host/relay.md).

## Relay status in Settings

| Shown as | Meaning |
|---|---|
| **Relay: connected** | A grant is held and renews itself. Push is on. |
| **Relay: not active** | The relay refused the credential (HTTP 402: not active, lapsed, or unknown). Check it with whoever runs the relay. |
| **Relay: could not verify** | The relay could not be reached. The app keeps the last grant if it has one and retries. |

Grants last at most 30 days and the app renews one within three days of its
expiry. If the relay answers 401, 403 or 410 (invalid grant, blocked device,
push token gone), the app drops the stored grant and requests a fresh one. **Re-check**
forces a renewal now; **Remove relay** forgets the URL and tells every machine
to stop pushing.

## Per-machine control

**Machines → Mute notifications** drops that machine's grant, so it neither
pushes nor raises live alerts; unmuting restores it. The **Push notifications**
switch in Settings turns push off for every machine without forgetting the relay.

## Builds without push

Push is only possible when the Firebase options are compiled into the app.
Store builds have them. A build you made yourself without
`--dart-define-from-file=dart_defines/store.json` has no **Push relay** field in
Settings at all, and shows a note saying so. Notifications still work while the
app is open, and on Android with **Stay connected in the background**.

## Android without a relay

Android can keep the daemon connection alive with a foreground service.
**Settings → Stay connected in the background** turns it on; it shows a
persistent notification while a session is open, and alerts arrive straight
from the daemon over the VPN with no cloud service involved.
