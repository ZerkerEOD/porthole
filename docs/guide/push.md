# Push notifications

While the app is open, or kept alive on Android with
[Stay connected in the background](../getting-started/app.md#settings), it
receives permission prompts, questions and finished turns from the daemon over
the VPN.
Once the app is closed, and on iOS as soon as it leaves the foreground (see
[iOS background behavior](../reference/ios-background.md)), only the
platform push service can reach it. That needs a server holding the app's push
credentials: the push relay. Without a relay, alerts arrive only while the app
is open.

A push goes only to phones that are not connected to that machine at that
moment; a connected app gets the same event over the socket instead.

## What the relay sees

The daemon encrypts a notice (session title, machine name, the kind of
attention needed) with a key agreed at pairing and posts the ciphertext to the
relay. The relay checks a signed grant and forwards the ciphertext through FCM
to the phone, which decrypts it and shows the notification. The relay stores a
push token, a random device id and a timestamp. The app fetches the details
from your machine when you open it. See
[Security](../reference/security.md) for the relay's place in the model.

## Use the hosted relay

A hosted relay runs at `relay.zerkersec.io`. Supporters get a personal relay
URL from <https://zerkersec.io/supporter>, of the form

```
https://PH-XXXX-XXXX-XXXX-XXXX@relay.zerkersec.io
```

The part before the `@` is your relay credential. The app sends it to the relay
as a bearer token. The phone gets the URL with the credential; each daemon gets
the base URL without it, as shown below.

1. On the phone, open **Settings → Push relay**, paste the URL and tap
   **Connect**. The app asks for notification permission, fetches a grant from
   the relay, and hands that grant to every paired machine.
2. On each machine, set the relay's base URL (without the credential) in
   `~/.config/porthole/config.toml` and restart the daemon:

    ```toml
    [push]
    relay_url = "https://relay.zerkersec.io"
    ```

    ```sh
    systemctl --user restart porthole                                    # Linux and WSL2
    launchctl kickstart -k "gui/$(id -u)/io.zerkersec.porthole.daemon"  # macOS
    ```

    A daemon with an empty `relay_url` refuses push registrations. The app then
    shows the relay as connected, but that machine never pushes.

## Run your own

The app accepts any relay URL of the form `https://[credential@]host[/path]`.
See [Self-hosting the push relay](../self-host/relay.md). A relay you run needs
an app built against your own Firebase project; see
[Build the app yourself](../self-host/app.md).

## Relay status in Settings

| Shown as | Meaning |
|---|---|
| Relay: connected | A grant is held and renews itself. Push is on. |
| Relay: not active | The relay refused the credential (HTTP 402: not active, lapsed, or unknown). Check it with whoever runs the relay. |
| Relay: could not verify | The relay could not be reached. The app keeps the last grant if it has one and retries. |

Grants last at most 30 days and the app renews one within three days of its
expiry. If the relay answers 401, 403 or 410 (invalid grant, blocked device,
push token gone), the app drops the stored grant and requests a fresh one.
**Re-check** forces a renewal now. **Remove relay** forgets the URL and tells
every machine to stop pushing.

## What is pushed

The daemon pushes the same notices the app shows live: a permission prompt, a
question, or a finished turn, once per wait, and only for sessions you opened
from the phone (see [Status and attention](sessions.md#status-and-attention)).

## Per-machine control

**Machines → Mute notifications** drops that machine's grant, so it neither
pushes nor raises live alerts. Unmuting restores it. The **Push notifications**
switch in Settings turns push off for every machine without forgetting the
relay.

## Builds without push

Push works only when the Firebase options are compiled into the app. Store
builds have them. A build made without
`--dart-define-from-file=dart_defines/store.json` has no **Push relay** field
in Settings and shows a note saying so. Notifications still work while the app
is open, and on Android with **Stay connected in the background**.
