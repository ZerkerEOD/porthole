package hooks

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestInstallClaudePreservesExisting(t *testing.T) {
	dir := t.TempDir()
	os.WriteFile(filepath.Join(dir, "settings.json"), []byte(`{"model":"x","hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"python3 guard.py"}]}],"Stop":[{"matcher":"","hooks":[{"type":"command","command":"say done"}]}]}}`), 0o600)
	ch, err := InstallClaude(dir, "/usr/bin/porthole", 60)
	if err != nil || !ch {
		t.Fatalf("install: %v %v", ch, err)
	}
	ch, err = InstallClaude(dir, "/usr/bin/porthole", 60)
	if err != nil || ch {
		t.Fatalf("second install should be a no-op: %v %v", ch, err)
	}
	b, _ := os.ReadFile(filepath.Join(dir, "settings.json"))
	var doc map[string]any
	json.Unmarshal(b, &doc)
	if doc["model"] != "x" {
		t.Fatal("other settings lost")
	}
	hooks := doc["hooks"].(map[string]any)
	if len(hooks["PreToolUse"].([]any)) != 1 {
		t.Fatal("existing PreToolUse hook lost")
	}
	if len(hooks["Stop"].([]any)) != 2 {
		t.Fatalf("Stop should have user hook + ours: %v", hooks["Stop"])
	}
	pr := hooks["PermissionRequest"].([]any)[0].(map[string]any)["hooks"].([]any)[0].(map[string]any)
	if pr["timeout"].(float64) != 70 {
		t.Fatalf("permission timeout: %v", pr["timeout"])
	}
	ch, err = UninstallClaude(dir)
	if err != nil || !ch {
		t.Fatal("uninstall")
	}
	b, _ = os.ReadFile(filepath.Join(dir, "settings.json"))
	if strings.Contains(string(b), "porthole hook") {
		t.Fatal("hooks not removed")
	}
	json.Unmarshal(b, &doc)
	if len(doc["hooks"].(map[string]any)["Stop"].([]any)) != 1 {
		t.Fatal("user Stop hook lost on uninstall")
	}
}

func TestInstallCodex(t *testing.T) {
	dir := t.TempDir()
	os.WriteFile(filepath.Join(dir, "config.toml"), []byte("model = \"gpt-5.5\"\n[mcp_servers.x]\nurl = \"y\"\n"), 0o600)
	ch, err := InstallCodex(dir, "/usr/bin/porthole")
	if err != nil || !ch {
		t.Fatal(err)
	}
	b, _ := os.ReadFile(filepath.Join(dir, "config.toml"))
	if !strings.HasPrefix(string(b), "notify = [\"/usr/bin/porthole\", \"codex-notify\"]\n") {
		t.Fatalf("got %q", b)
	}
	if ch, _ := InstallCodex(dir, "/usr/bin/porthole"); ch {
		t.Fatal("should be idempotent")
	}
	os.WriteFile(filepath.Join(dir, "config.toml"), []byte("notify = [\"other\"]\n"), 0o600)
	if _, err := InstallCodex(dir, "/usr/bin/porthole"); err == nil {
		t.Fatal("expected conflict error")
	}
}
