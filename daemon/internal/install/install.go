// Package install puts the daemon binary in place and registers it with the
// user's service manager (systemd on Linux, launchd on macOS).
package install

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
)

// Unit is the systemd user unit (kept identical to packaging/porthole.service).
const Unit = `# systemd user unit: ~/.config/systemd/user/porthole.service
# Enable with: systemctl --user enable --now porthole
[Unit]
Description=Porthole daemon (remote for Claude Code and Codex sessions)
After=network-online.target

[Service]
ExecStart=%h/.local/bin/porthole serve
Restart=on-failure
RestartSec=3
# The daemon must see your login environment (PATH with claude/codex/tmux).
Environment=PATH=%h/.local/bin:/usr/local/bin:/usr/bin:/bin

[Install]
WantedBy=default.target
`

// Plist is the launchd agent; BIN is replaced with the installed binary.
const Plist = `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>io.zerkersec.porthole.daemon</string>
  <key>ProgramArguments</key>
  <array><string>BIN</string><string>serve</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>EnvironmentVariables</key>
  <dict><key>PATH</key><string>HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string></dict>
  <key>StandardOutPath</key><string>HOME/Library/Logs/porthole.log</string>
  <key>StandardErrorPath</key><string>HOME/Library/Logs/porthole.log</string>
</dict>
</plist>
`

// Label is the launchd agent label.
const Label = "io.zerkersec.porthole.daemon"

// BinDir is where the binary is installed.
func BinDir() string {
	h, _ := os.UserHomeDir()
	return filepath.Join(h, ".local", "bin")
}

// Binary copies src to ~/.local/bin/porthole unless it already is that file.
// It returns the installed path.
func Binary(src string) (string, error) {
	dst := filepath.Join(BinDir(), "porthole")
	if rs, err := filepath.EvalSymlinks(src); err == nil {
		src = rs
	}
	if rd, err := filepath.EvalSymlinks(dst); err == nil && rd == src {
		return dst, nil
	}
	if err := os.MkdirAll(BinDir(), 0o755); err != nil {
		return "", err
	}
	in, err := os.Open(src)
	if err != nil {
		return "", err
	}
	defer in.Close()
	tmp := dst + ".tmp"
	out, err := os.OpenFile(tmp, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0o755)
	if err != nil {
		return "", err
	}
	if _, err := io.Copy(out, in); err != nil {
		_ = out.Close()
		_ = os.Remove(tmp)
		return "", err
	}
	if err := out.Close(); err != nil {
		return "", err
	}
	// Rename over a running binary is fine on unix; the old inode lives on.
	return dst, os.Rename(tmp, dst)
}

// Service registers and starts the daemon with the user's service manager.
// Each line of the returned notes is something the user should know
// (for example a command that needs sudo).
func Service(ctx context.Context, bin string) (notes []string, err error) {
	switch runtime.GOOS {
	case "linux":
		return systemd(ctx)
	case "darwin":
		return launchd(ctx, bin)
	default:
		return nil, fmt.Errorf("no service manager support for %s; run `porthole serve` yourself", runtime.GOOS)
	}
}

func run(ctx context.Context, name string, args ...string) (string, error) {
	out, err := exec.CommandContext(ctx, name, args...).CombinedOutput()
	return strings.TrimSpace(string(out)), err
}

func systemd(ctx context.Context) ([]string, error) {
	if _, err := exec.LookPath("systemctl"); err != nil {
		return nil, errors.New("systemctl not found; run `porthole serve` yourself or copy packaging/porthole.service")
	}
	h, _ := os.UserHomeDir()
	dir := filepath.Join(h, ".config", "systemd", "user")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return nil, err
	}
	unit := filepath.Join(dir, "porthole.service")
	if err := os.WriteFile(unit, []byte(Unit), 0o644); err != nil {
		return nil, err
	}
	var notes []string
	if out, err := run(ctx, "systemctl", "--user", "daemon-reload"); err != nil {
		return nil, fmt.Errorf("systemctl --user daemon-reload: %s", out)
	}
	if out, err := run(ctx, "systemctl", "--user", "enable", "--now", "porthole"); err != nil {
		return nil, fmt.Errorf("systemctl --user enable --now porthole: %s", out)
	}
	if _, err := run(ctx, "systemctl", "--user", "restart", "porthole"); err == nil {
		notes = append(notes, "service porthole started (systemd user unit "+unit+")")
	}
	if _, err := run(ctx, "loginctl", "enable-linger"); err != nil {
		u := os.Getenv("USER")
		notes = append(notes, "could not enable lingering; to keep the daemon running after you log out: sudo loginctl enable-linger "+u)
	} else {
		notes = append(notes, "lingering enabled: the daemon keeps running after you log out")
	}
	return notes, nil
}

func launchd(ctx context.Context, bin string) ([]string, error) {
	h, _ := os.UserHomeDir()
	dir := filepath.Join(h, "Library", "LaunchAgents")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return nil, err
	}
	_ = os.MkdirAll(filepath.Join(h, "Library", "Logs"), 0o755)
	plist := filepath.Join(dir, Label+".plist")
	body := strings.ReplaceAll(strings.ReplaceAll(Plist, "BIN", bin), "HOME", h)
	if err := os.WriteFile(plist, []byte(body), 0o644); err != nil {
		return nil, err
	}
	domain := fmt.Sprintf("gui/%d", os.Getuid())
	_, _ = run(ctx, "launchctl", "bootout", domain+"/"+Label)
	if out, err := run(ctx, "launchctl", "bootstrap", domain, plist); err != nil {
		return nil, fmt.Errorf("launchctl bootstrap: %s", out)
	}
	return []string{"launch agent loaded (" + plist + "); log: ~/Library/Logs/porthole.log"}, nil
}
