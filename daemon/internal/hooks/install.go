// Package hooks installs the Claude Code hook entries and the Codex notify
// setting that route events to the daemon, idempotently.
package hooks

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// ClaudeEvents are the hook events Porthole subscribes to.
var ClaudeEvents = []string{"SessionStart", "SessionEnd", "UserPromptSubmit", "Stop", "Notification", "PermissionRequest", "PostModelSwitch"}

const marker = "porthole hook"

// InstallClaude merges Porthole hook entries into <profile>/settings.json,
// keeping every existing hook. permissionTimeout is seconds the
// PermissionRequest hook may block (Claude's own hook timeout).
func InstallClaude(profileDir, binary string, permissionTimeout int) (changed bool, err error) {
	path := filepath.Join(profileDir, "settings.json")
	var doc map[string]any
	b, err := os.ReadFile(path)
	switch {
	case err == nil:
		if err := json.Unmarshal(b, &doc); err != nil {
			return false, fmt.Errorf("%s is not valid JSON: %w", path, err)
		}
	case errors.Is(err, os.ErrNotExist):
		doc = map[string]any{}
	default:
		return false, err
	}
	hooks, _ := doc["hooks"].(map[string]any)
	if hooks == nil {
		hooks = map[string]any{}
	}
	cmd := binary + " hook"
	for _, ev := range ClaudeEvents {
		timeout := 30
		if ev == "PermissionRequest" {
			timeout = permissionTimeout + 10
		}
		entry := map[string]any{
			"matcher": "",
			"hooks":   []any{map[string]any{"type": "command", "command": cmd, "timeout": timeout}},
		}
		list, _ := hooks[ev].([]any)
		found := false
		for i, it := range list {
			m, _ := it.(map[string]any)
			if m == nil {
				continue
			}
			hs, _ := m["hooks"].([]any)
			for _, h := range hs {
				hm, _ := h.(map[string]any)
				if hm != nil && strings.HasSuffix(fmt.Sprint(hm["command"]), marker) {
					found = true
					if fmt.Sprint(hm["command"]) != cmd || fmt.Sprint(hm["timeout"]) != fmt.Sprint(timeout) {
						list[i] = entry
						changed = true
					}
				}
			}
		}
		if !found {
			list = append(list, entry)
			changed = true
		}
		hooks[ev] = list
	}
	doc["hooks"] = hooks
	if !changed {
		return false, nil
	}
	var out bytes.Buffer
	enc := json.NewEncoder(&out)
	enc.SetIndent("", "  ")
	if err := enc.Encode(doc); err != nil {
		return false, err
	}
	if err := os.MkdirAll(profileDir, 0o700); err != nil {
		return false, err
	}
	tmp := path + ".porthole.tmp"
	if err := os.WriteFile(tmp, out.Bytes(), 0o600); err != nil {
		return false, err
	}
	return true, os.Rename(tmp, path)
}

// UninstallClaude removes Porthole entries from settings.json.
func UninstallClaude(profileDir string) (changed bool, err error) {
	path := filepath.Join(profileDir, "settings.json")
	b, err := os.ReadFile(path)
	if err != nil {
		return false, err
	}
	var doc map[string]any
	if err := json.Unmarshal(b, &doc); err != nil {
		return false, err
	}
	hooks, _ := doc["hooks"].(map[string]any)
	for ev, v := range hooks {
		list, _ := v.([]any)
		var keep []any
		for _, it := range list {
			m, _ := it.(map[string]any)
			hs, _ := m["hooks"].([]any)
			ours := false
			for _, h := range hs {
				hm, _ := h.(map[string]any)
				if hm != nil && strings.HasSuffix(fmt.Sprint(hm["command"]), marker) {
					ours = true
				}
			}
			if ours {
				changed = true
				continue
			}
			keep = append(keep, it)
		}
		if len(keep) == 0 {
			delete(hooks, ev)
		} else {
			hooks[ev] = keep
		}
	}
	if !changed {
		return false, nil
	}
	out, err := json.MarshalIndent(doc, "", "  ")
	if err != nil {
		return false, err
	}
	return true, os.WriteFile(path, append(out, '\n'), 0o600)
}

// InstallCodex sets `notify` in <profile>/config.toml when absent. If notify
// is already set to something else it returns ErrNotifyTaken with the line
// the user should merge by hand.
func InstallCodex(profileDir, binary string) (changed bool, err error) {
	path := filepath.Join(profileDir, "config.toml")
	b, err := os.ReadFile(path)
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		return false, err
	}
	want := fmt.Sprintf("notify = [%q, %q]", binary, "codex-notify")
	lines := strings.Split(string(b), "\n")
	for _, l := range lines {
		t := strings.TrimSpace(l)
		if strings.HasPrefix(t, "notify") && strings.Contains(t, "=") {
			if strings.Contains(t, "codex-notify") {
				return false, nil
			}
			return false, fmt.Errorf("%w: config.toml already has %q; replace it with %s", ErrNotifyTaken, t, want)
		}
	}
	// Top-level keys must precede any [table]; insert at the top.
	content := want + "\n" + string(b)
	if err := os.MkdirAll(profileDir, 0o700); err != nil {
		return false, err
	}
	return true, os.WriteFile(path, []byte(content), 0o600)
}

// ErrNotifyTaken means Codex already has a notify program configured.
var ErrNotifyTaken = errors.New("codex notify already configured")
