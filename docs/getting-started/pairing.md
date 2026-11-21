# Pair a phone

Pairing gives the phone a device token and the daemon's certificate
fingerprint. It happens once per phone and machine; after that the app
reconnects on its own.

## Before you start

- The daemon must be running (`porthole status` answers).
- The phone must be able to reach the computer on a **private address**: the
  same Wi-Fi network, or a VPN such as WireGuard, Tailscale or NetBird. The
  daemon refuses connections from public addresses, so there is no way to pair
  across the open internet.
- TCP port 7433 must be open in the computer's firewall on that interface.

## Scan the code

On the computer:

```sh
porthole pair
```

prints a QR code, how long it is valid, and the same values as text:

```
Scan with the Porthole app within 2m0s.
Manual entry: host 100.64.0.5 or 192.168.1.20  port 7433  code ABCDEFGH
Certificate fingerprint: …
```

In the app, tap **Scan pairing code** (the empty home screen) or **Machines → Pair
machine**, and point the camera at the QR. The code is single use and expires
after two minutes; run `porthole pair` again if you miss the window.

If the output ends with `warning: no VPN or private address is bound; is your
VPN up?`, the daemon found nothing but loopback to listen on. Bring the VPN up
and restart the daemon.

## Enter the values by hand

Tap **Enter manually** on the pairing screen if the camera is not an option. The fields are:

| Field | From `porthole pair` |
|---|---|
| Host (VPN address) | one of the `host` values; pick the one on the network the phone is on |
| Port | `port` (7433 unless you changed it) |
| Certificate fingerprint | the `Certificate fingerprint` line |
| Pairing code | `code` |
| This device's name | anything you like; it is what `porthole devices` lists |

## Options

- `porthole pair --label "Aaron's phone"` attaches a label to the pairing.
- `porthole pair --json` prints the pairing payload as JSON instead of a QR,
  for scripting or for feeding a second screen.

## What pairing establishes

- The app pins the daemon's self-signed TLS certificate by fingerprint and
  refuses anything else, so there is no certificate authority to manage.
- The app receives a random device token, stored in the phone's keychain or
  keystore; the daemon stores only a hash of it.
- The two sides agree on a key used to encrypt push notices, so a relay (if
  you use one) never sees their contents.

See [Security](../reference/security.md) for the full model.

## Manage paired devices

```sh
porthole devices              # ID, name, paired date, last seen
porthole devices revoke <id>  # closes that phone's connections within a second
```

On the phone, **Machines** lists every daemon you have paired: rename it, mute
its notifications, turn auto-connect on or off, or forget it. One phone can
pair with as many machines as you like, and they share a single session list.
