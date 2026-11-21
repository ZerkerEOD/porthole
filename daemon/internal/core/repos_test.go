package core

import (
	"log/slog"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/ZerkerEOD/porthole/daemon/internal/config"
)

func mkRepo(t *testing.T, dir string) string {
	t.Helper()
	if err := os.MkdirAll(filepath.Join(dir, ".git"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, ".git", "HEAD"), []byte("ref: refs/heads/main\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	return dir
}

func TestReposSourcesAndReload(t *testing.T) {
	base := t.TempDir()
	ws := filepath.Join(base, "ws")
	inWs := mkRepo(t, filepath.Join(ws, "group", "proj"))
	explicit := mkRepo(t, filepath.Join(base, "explicit"))
	recent := mkRepo(t, filepath.Join(base, "recent"))
	plain := filepath.Join(base, "plain")
	_ = os.MkdirAll(plain, 0o755)

	cfgPath := filepath.Join(base, "config.toml")
	_ = os.WriteFile(cfgPath, []byte("workspaces = [\""+ws+"\"]\n"), 0o600)
	cfg, err := config.Load(cfgPath)
	if err != nil {
		t.Fatal(err)
	}
	r := New(cfg, slog.New(slog.NewTextHandler(os.Stderr, nil)))
	r.upsert(Session{Key: "claude:a", ID: "a", Provider: "claude", Cwd: recent, UpdatedAt: time.Now()})
	r.upsert(Session{Key: "claude:b", ID: "b", Provider: "claude", Cwd: plain, UpdatedAt: time.Now()})

	srcOf := func() map[string]string {
		m := map[string]string{}
		for _, rp := range r.Repos() {
			m[rp.Path] = rp.Source
		}
		return m
	}
	got := srcOf()
	if got[inWs] != "workspace" || got[recent] != "recent" {
		t.Fatalf("sources: %v", got)
	}
	if _, ok := got[plain]; ok {
		t.Fatal("a session dir without .git must not be listed")
	}
	if _, ok := got[explicit]; ok {
		t.Fatal("explicit repo listed before it was added")
	}
	if _, err := r.insideWorkspace(recent); err != nil {
		t.Fatal("recent dir should be spawnable:", err)
	}
	if _, err := r.insideWorkspace(explicit); err == nil {
		t.Fatal("explicit repo spawnable before add")
	}

	if _, err := config.AddManaged(config.ManagedPath(cfgPath), explicit, false); err != nil {
		t.Fatal(err)
	}
	if _, _, err := r.Reload(); err != nil {
		t.Fatal(err)
	}
	got = srcOf()
	if got[explicit] != "repo" {
		t.Fatalf("after reload: %v", got)
	}
	if _, err := r.insideWorkspace(filepath.Join(explicit, "sub")); err == nil {
		t.Fatal("missing subdir must fail")
	}
	_ = os.MkdirAll(filepath.Join(explicit, "sub"), 0o755)
	if _, err := r.insideWorkspace(filepath.Join(explicit, "sub")); err != nil {
		t.Fatal("subdir of an added repo should be spawnable:", err)
	}
}
