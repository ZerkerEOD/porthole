package main

import (
	"bytes"
	"context"
	"fmt"
	"os"
	"os/exec"
	"runtime"
	"strings"
	"time"
)

// firewallHint reports whether a host firewall looks active and how to open
// the daemon's port in it. It never needs root; when a check cannot run
// without it, the line says so.
func firewallHint(ctx context.Context, port int) []string {
	switch runtime.GOOS {
	case "linux":
		return linuxFirewallHint(ctx, port)
	case "darwin":
		return darwinFirewallHint(ctx)
	}
	return nil
}

func run(ctx context.Context, name string, args ...string) (string, string, error) {
	ctx, cancel := context.WithTimeout(ctx, 3*time.Second)
	defer cancel()
	var out, errb bytes.Buffer
	cmd := exec.CommandContext(ctx, name, args...)
	cmd.Stdout, cmd.Stderr = &out, &errb
	err := cmd.Run()
	return out.String(), errb.String(), err
}

func serviceActive(ctx context.Context, unit string) bool {
	if _, err := exec.LookPath("systemctl"); err != nil {
		return false
	}
	_, _, err := run(ctx, "systemctl", "is-active", "--quiet", unit)
	return err == nil
}

// ufwEnabled reads the ufw config when it is readable; the unit stays active
// after `ufw disable`, so the service check alone is not enough.
func ufwEnabled() bool {
	b, err := os.ReadFile("/etc/ufw/ufw.conf")
	if err != nil {
		return true
	}
	for _, line := range strings.Split(string(b), "\n") {
		if strings.HasPrefix(strings.TrimSpace(line), "ENABLED=") {
			return strings.EqualFold(strings.TrimSpace(strings.TrimPrefix(strings.TrimSpace(line), "ENABLED=")), "yes")
		}
	}
	return true
}

func linuxFirewallHint(ctx context.Context, port int) []string {
	if serviceActive(ctx, "ufw") && ufwEnabled() {
		return []string{"firewall: ufw active", fmt.Sprintf("  allow the port: sudo ufw allow %d/tcp", port)}
	}
	if serviceActive(ctx, "firewalld") {
		return []string{"firewall: firewalld active", fmt.Sprintf("  allow the port: sudo firewall-cmd --add-port=%d/tcp --permanent && sudo firewall-cmd --reload", port)}
	}
	if _, err := exec.LookPath("nft"); err == nil {
		out, errb, err := run(ctx, "nft", "list", "ruleset")
		switch {
		case err != nil && (strings.Contains(errb, "Operation not permitted") || strings.Contains(errb, "Permission denied")):
			return []string{"firewall: nftables ruleset not readable without root; run `sudo nft list ruleset` to check for rules on the port"}
		case err == nil && strings.Contains(out, "hook input"):
			return []string{"firewall: nftables rules with an input hook are loaded", fmt.Sprintf("  allow tcp port %d in the input chain, or with ufw/firewalld if one manages the rules", port)}
		case err == nil:
			return []string{"firewall: none detected (nftables ruleset is empty)"}
		}
	}
	if b, err := os.ReadFile("/proc/net/ip_tables_names"); err == nil && len(bytes.TrimSpace(b)) > 0 {
		return []string{"firewall: iptables tables loaded (" + strings.Join(strings.Fields(string(b)), ", ") + ")", fmt.Sprintf("  check `sudo iptables -L INPUT -n` for a rule that drops tcp port %d", port)}
	}
	return []string{"firewall: none detected"}
}

func darwinFirewallHint(ctx context.Context) []string {
	out, _, err := run(ctx, "/usr/libexec/ApplicationFirewall/socketfilterfw", "--getglobalstate")
	if err != nil {
		return []string{"firewall: could not read the application firewall state"}
	}
	if strings.Contains(strings.ToLower(out), "enabled") {
		return []string{"firewall: macOS application firewall on", "  allow porthole when macOS asks, or add it under System Settings > Network > Firewall > Options"}
	}
	return []string{"firewall: macOS application firewall off"}
}
