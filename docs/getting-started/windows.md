# Windows (WSL2)

There is no native Windows build. Session discovery reads `/proc` and runs
`ps`, control goes through the `tmux` binary, and the service installer knows
systemd and launchd only. On Windows, run the daemon inside a WSL2 distribution
and run Claude Code or Codex inside the same distribution: the daemon reads
their transcripts from `~/.claude` and `~/.codex` of the Linux home, so agents
started from PowerShell or cmd are not seen. Everything on
[Install the daemon](install.md) applies inside WSL2; this page covers what
differs.

## Set up WSL2

Enable systemd so `porthole install` can register the user service. Inside the
distribution:

```sh
sudo tee /etc/wsl.conf <<'EOT'
[boot]
systemd=true
EOT
```

Then from PowerShell:

```powershell
wsl --shutdown
```

Open the distribution again and confirm with `systemctl --user status`. Without
systemd the service step fails and `porthole install` prints `You can still run
porthole serve by hand`; run `porthole install --no-service` instead and start
`porthole serve` in a tmux window yourself.

Install tmux:

```sh
sudo apt install tmux
```

The daemon needs it for every session you want to control from the phone.

Run the installer:

```sh
curl -fsSL https://raw.githubusercontent.com/ZerkerEOD/porthole/main/scripts/install.sh | sh
```

`uname -s` reports `Linux` inside WSL2, so the script takes the Linux path: it
downloads the linux release for your architecture, verifies the checksum, and
runs `porthole install`. The install step tries `loginctl enable-linger`; if
that needs root it prints the `sudo` command to run.

## Networking

The phone must reach the daemon on a private address, and the daemon only
accepts connections whose source is loopback, link-local, RFC1918, 100.64/10
(Tailscale) or an IPv6 ULA address. Pick one of these two setups.

### Tailscale inside WSL

Install Tailscale inside the distribution, not on Windows:

```sh
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up
```

The distribution gets its own `tailscale0` interface with a 100.x address. The
daemon binds it and lists it first in the pairing QR, and the phone connects
over the tailnet from anywhere. No Windows firewall change is needed because
the traffic arrives through the tunnel.

### Mirrored networking and a firewall rule

Mirrored networking (Windows 11 22H2 or later) gives the distribution the same
LAN address as the Windows host. Create or edit `%UserProfile%\.wslconfig`:

```ini
[wsl2]
networkingMode=mirrored
```

Then from PowerShell:

```powershell
wsl --shutdown
```

Allow TCP 7433 through Windows Defender Firewall, from an elevated PowerShell:

```powershell
New-NetFirewallRule -DisplayName "Porthole" -Direction Inbound -Protocol TCP -LocalPort 7433 -Action Allow
```

Use the port you set in [config.toml](../guide/config.md) if you changed it.
If the phone still cannot connect, allow inbound traffic to WSL in the Hyper-V
firewall:

```powershell
Set-NetFirewallHyperVVMSetting -Name '{40E0AC32-46A5-438A-A0B2-2B479E8F2E90}' -DefaultInboundAction Allow
```

The phone then pairs over the same Wi-Fi, like a Linux host would.

### NAT mode is not supported

The default WSL2 networking mode puts the distribution behind NAT with a
172.x address that the phone cannot reach. Forwarding the port with
`netsh interface portproxy` does not help: the daemon sees the proxy as the
connection source, so it cannot tell your phone from any other client, and the
address it prints for pairing is still the unreachable one. Use one of the two
setups above.

## Pair

Inside the distribution:

```sh
porthole pair
```

prints the QR code and a `Manual entry: host ...` line with the addresses the
daemon chose. Check that line before scanning: with Tailscale it should show a
100.x address, with mirrored networking the LAN address of the Windows host.
If it shows only a 172.x address, or ends with
`warning: no VPN or private address is bound`, the networking step is not
complete. Then follow [Pair a phone](pairing.md).

## Limits

- The daemon runs only while the WSL instance runs. `wsl --shutdown`, a Windows
  reboot, or WSL stopping the distribution stops it. Open a WSL terminal to start
  the instance again; with systemd and lingering enabled the user service starts
  with it, otherwise run `porthole serve`.
- Agents started on the Windows side (PowerShell, cmd, Windows Terminal without
  WSL) are not discovered. The daemon only sees processes and transcripts inside
  its own distribution.
- `porthole wrap`, hooks and session control need `tmux` and `claude` or `codex`
  installed inside the distribution, on the Linux `PATH`.
