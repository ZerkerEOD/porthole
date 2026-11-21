package config

import (
	"os"
	"path/filepath"
	"testing"
)

func TestManagedMergeAddRemove(t *testing.T) {
	dir := t.TempDir()
	cfgPath := filepath.Join(dir, "config.toml")
	if err := os.WriteFile(cfgPath, []byte("workspaces = [\""+dir+"/ws\"]\nrepos = [\""+dir+"/hand\"]\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	mp := ManagedPath(cfgPath)
	if mp != filepath.Join(dir, "repos.toml") {
		t.Fatal("managed path", mp)
	}
	added, err := AddManaged(mp, dir+"/repo1", false)
	if err != nil || !added {
		t.Fatal("add", added, err)
	}
	if added, _ := AddManaged(mp, dir+"/repo1", false); added {
		t.Fatal("duplicate add should report false")
	}
	if _, err := AddManaged(mp, dir+"/ws2", true); err != nil {
		t.Fatal(err)
	}
	st, err := os.Stat(mp)
	if err != nil || st.Mode().Perm() != 0o600 {
		t.Fatal("repos.toml mode", err, st.Mode())
	}
	cfg, err := Load(cfgPath)
	if err != nil {
		t.Fatal(err)
	}
	want := func(got []string, exp ...string) {
		t.Helper()
		if len(got) != len(exp) {
			t.Fatalf("got %v want %v", got, exp)
		}
		for i := range exp {
			if got[i] != exp[i] {
				t.Fatalf("got %v want %v", got, exp)
			}
		}
	}
	want(cfg.Workspaces, dir+"/ws", dir+"/ws2")
	want(cfg.Repos, dir+"/hand", dir+"/repo1")
	if cfg.Path != cfgPath {
		t.Fatal("Path not recorded")
	}
	removed, err := RemoveManaged(mp, dir+"/repo1")
	if err != nil || !removed {
		t.Fatal("remove", removed, err)
	}
	if removed, _ := RemoveManaged(mp, dir+"/hand"); removed {
		t.Fatal("entries from config.toml must not be removable through repos.toml")
	}
	cfg, _ = Load(cfgPath)
	want(cfg.Repos, dir+"/hand")
	want(cfg.Workspaces, dir+"/ws", dir+"/ws2")
}

func TestLoadWithoutFiles(t *testing.T) {
	cfg, err := Load(filepath.Join(t.TempDir(), "config.toml"))
	if err != nil {
		t.Fatal(err)
	}
	if cfg.Port != 7433 || len(cfg.Workspaces) != 0 || len(cfg.Repos) != 0 {
		t.Fatal("defaults", cfg.Port, cfg.Workspaces, cfg.Repos)
	}
}
