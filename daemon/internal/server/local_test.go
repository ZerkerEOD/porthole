package server

import (
	"log/slog"
	"os"
	"path/filepath"
	"testing"

	"github.com/ZerkerEOD/porthole/daemon/internal/config"
	"github.com/ZerkerEOD/porthole/daemon/internal/core"
)

func TestResolveExisting(t *testing.T) {
	base := t.TempDir()
	real := filepath.Join(base, "real")
	if err := os.MkdirAll(filepath.Join(real, "projects"), 0o755); err != nil {
		t.Fatal(err)
	}
	alias := filepath.Join(base, "alias")
	if err := os.Symlink(real, alias); err != nil {
		t.Skip("symlinks not supported:", err)
	}
	got, err := resolveExisting(filepath.Join(alias, "projects", "new-dir", "sess.jsonl"))
	if err != nil {
		t.Fatal(err)
	}
	realBase, _ := filepath.EvalSymlinks(real)
	if want := filepath.Join(realBase, "projects", "new-dir", "sess.jsonl"); got != want {
		t.Fatalf("got %s want %s", got, want)
	}
	if _, err := resolveExisting("relative/path"); err == nil {
		t.Fatal("relative path accepted")
	}
}

func TestTranscriptAllowed(t *testing.T) {
	base := t.TempDir()
	profile := filepath.Join(base, "profile")
	if err := os.MkdirAll(filepath.Join(profile, "projects", "-home-u-repo"), 0o755); err != nil {
		t.Fatal(err)
	}
	alias := filepath.Join(base, "alias")
	if err := os.Symlink(profile, alias); err != nil {
		t.Skip("symlinks not supported:", err)
	}
	t.Setenv("CLAUDE_CONFIG_DIR", "")
	cfg := config.Default()
	cfg.Profiles = []string{alias}
	reg := core.New(cfg, slog.New(slog.NewTextHandler(os.Stderr, nil)))
	l := &Local{cfg: cfg, reg: reg, log: slog.New(slog.NewTextHandler(os.Stderr, nil))}

	cases := []struct {
		name string
		path string
		want bool
	}{
		{"missing file under watched dir", filepath.Join(profile, "projects", "-home-u-repo", "new.jsonl"), true},
		{"missing project dir under watched dir", filepath.Join(profile, "projects", "-home-u-other", "new.jsonl"), true},
		{"through the symlinked profile dir", filepath.Join(alias, "projects", "-home-u-repo", "new.jsonl"), true},
		{"outside", filepath.Join(base, "elsewhere", "projects", "x.jsonl"), false},
		{"escaping with dot-dot", filepath.Join(profile, "projects", "..", "..", "x.jsonl"), false},
		{"projects dir itself", filepath.Join(profile, "projects"), false},
	}
	for _, c := range cases {
		if got := l.transcriptAllowed(c.path); got != c.want {
			t.Errorf("%s: %s -> %v, want %v", c.name, c.path, got, c.want)
		}
	}
}
