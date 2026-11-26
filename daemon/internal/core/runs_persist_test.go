package core

import (
	"context"
	"encoding/json"
	"log/slog"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/ZerkerEOD/porthole/daemon/internal/config"
	"github.com/ZerkerEOD/porthole/daemon/internal/tmux"
	"github.com/ZerkerEOD/porthole/daemon/internal/transcript"
)

func TestRunFileRoundTrip(t *testing.T) {
	exit := 2
	rf := runFile{
		Run:     Run{Key: "claude:a", ID: "0123abcd", Command: "make test", State: RunDone, Exit: &exit, Tail: "x", StartedAt: time.Now().Round(0).UTC(), EndedAt: time.Now().Round(0).UTC(), Fed: true, Queued: true, PaneID: "%3", Device: "dev1"},
		Feed:    true,
		LogPath: "/x/0123abcd.log",
		Device:  "dev1",
	}
	path := filepath.Join(t.TempDir(), "0123abcd.json")
	if err := writeRunFile(path, rf); err != nil {
		t.Fatal(err)
	}
	if fi, err := os.Stat(path); err != nil || fi.Mode().Perm() != 0o600 {
		t.Fatalf("mode %v %v", fi, err)
	}
	got, err := readRunFile(path)
	if err != nil {
		t.Fatal(err)
	}
	a, _ := json.Marshal(rf)
	b, _ := json.Marshal(got)
	if string(a) != string(b) {
		t.Fatalf("round trip\n%s\n%s", a, b)
	}
	if strings.Contains(string(a), "recovered") {
		t.Fatal("recovered written when false")
	}
	if raw, _ := json.Marshal(Run{Recovered: true}); !strings.Contains(string(raw), `"recovered":true`) {
		t.Fatalf("recovered missing: %s", raw)
	}
}

// newRunTestRegistry returns a registry on a private tmux server with one
// session whose pane writes what is typed into it to a file.
func newRunTestRegistry(t *testing.T, socket string) (*Registry, *tmux.Client, string, string) {
	t.Helper()
	if _, err := exec.LookPath("tmux"); err != nil {
		t.Skip("tmux not installed")
	}
	tm := tmux.NewPrivateClient("tmux", socket)
	t.Cleanup(func() { _ = exec.Command("tmux", "-L", socket, "kill-server").Run() })
	work := t.TempDir()
	typed := filepath.Join(work, "typed.txt")
	pane, err := tm.NewSession(context.Background(), "rs1", work, []string{"sh", "-c", "cat > " + typed}, nil)
	if err != nil {
		t.Fatal(err)
	}
	r := newRunRegistry(tm, filepath.Join(t.TempDir(), "runs"))
	r.upsert(Session{Key: "claude:abc", ID: "abc", Provider: "claude", Running: true, Controllable: true, PaneID: pane, TmuxSession: "rs1", Cwd: work, Status: transcript.StatusIdle})
	return r, tm, pane, typed
}

func newRunRegistry(tm *tmux.Client, dir string) *Registry {
	r := New(config.Default(), slog.New(slog.NewTextHandler(os.Stderr, nil)))
	r.tm = tm
	r.runDir = dir
	r.runPoll = 50 * time.Millisecond
	return r
}

func waitFor(t *testing.T, what string, cond func() bool) {
	t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	for !cond() {
		if time.Now().After(deadline) {
			t.Fatalf("timed out waiting for %s", what)
		}
		time.Sleep(50 * time.Millisecond)
	}
}

// A run that finished while the daemon was down, with its output still to
// be fed, is fed once after the restart and never again.
func TestReloadFinishedRunFeedsOnce(t *testing.T) {
	r, tm, pane, typed := newRunTestRegistry(t, "porthole-test-reload-fed")
	key, id := "claude:abc", "0a0b0c0d"
	dir := r.runsDir()
	_ = os.MkdirAll(dir, 0o700)
	logPath := filepath.Join(dir, id+".log")
	_ = os.WriteFile(logPath, []byte("built ok\n\n[exit 0]\n"), 0o600)
	_ = os.WriteFile(logPath+".rc", []byte("0\n"), 0o600)
	ended := time.Now().Add(-20 * time.Minute)
	_ = os.Chtimes(logPath, ended, ended)
	// The stored pane id is the session's own pane: the window must not be
	// killed, since it is not the run's window.
	rf := runFile{Run: Run{Key: key, ID: id, Command: "make", State: RunRunning, StartedAt: ended.Add(-time.Minute), PaneID: pane, Device: "dev1"}, Feed: true, LogPath: logPath, Device: "dev1"}
	if err := writeRunFile(r.runFilePath(id), rf); err != nil {
		t.Fatal(err)
	}
	rec := &runRec{}
	r.AddListener(rec)
	r.LoadRuns(context.Background())

	waitFor(t, "fed", func() bool { got, _ := rec.last(); return got.Fed })
	got, _ := rec.last()
	if got.State != RunDone || got.Exit == nil || *got.Exit != 0 || !got.Recovered || got.EndedAt.Sub(ended).Abs() > time.Second {
		t.Fatalf("recovered run %+v", got)
	}
	if _, err := os.Stat(logPath + ".rc"); !os.IsNotExist(err) {
		t.Fatal("status file left behind")
	}
	var b []byte
	waitFor(t, "typed text", func() bool {
		b, _ = os.ReadFile(typed)
		return strings.Contains(string(b), "[exit 0]")
	})
	waitFor(t, "fed persisted", func() bool {
		f, err := readRunFile(r.runFilePath(id))
		return err == nil && f.Run.Fed && f.FeedSettled
	})
	// A second restart reads fed:true and does not type again.
	r2 := newRunRegistry(tm, r.runsDir())
	r2.upsert(Session{Key: key, ID: "abc", Provider: "claude", Running: true, Controllable: true, PaneID: pane, TmuxSession: "rs1", Status: transcript.StatusIdle})
	r2.LoadRuns(context.Background())
	if rs := r2.AllRuns(); len(rs) != 1 || !rs[0].Recovered || !rs[0].Fed {
		t.Fatalf("runs after second load %+v", rs)
	}
	time.Sleep(500 * time.Millisecond)
	b, _ = os.ReadFile(typed)
	if n := strings.Count(string(b), "I ran this in a separate window:"); n != 1 {
		t.Fatalf("fed %d times: %q", n, b)
	}
	if !strings.Contains(string(b), "$ make\nbuilt ok\n[exit 0]") {
		t.Fatalf("typed %q", b)
	}
	// The session's pane survived the window clean-up.
	panes, _ := tm.ListPanes(context.Background())
	found := false
	for _, p := range panes {
		found = found || p.PaneID == pane
	}
	if !found {
		t.Fatal("session pane killed by a stale run pane id")
	}
	if text, trunc, err := r2.RunLog(key, id); err != nil || trunc || !strings.HasPrefix(text, "built ok") {
		t.Fatalf("run log %q %v %v", text, trunc, err)
	}
}

// A run still going at restart is tailed again and ends normally.
func TestReloadRunningRunResumes(t *testing.T) {
	r, tm, _, _ := newRunTestRegistry(t, "porthole-test-reload-run")
	key, id := "claude:abc", "1a2b3c4d"
	dir := r.runsDir()
	_ = os.MkdirAll(dir, 0o700)
	logPath := filepath.Join(dir, id+".log")
	_ = os.WriteFile(logPath, []byte("step 1\n"), 0o600)
	runPane, err := tm.NewWindow(context.Background(), "rs1", runWindowPrefix+id, dir, []string{"sh", "-c", "sleep 30"})
	if err != nil {
		t.Fatal(err)
	}
	rf := runFile{Run: Run{Key: key, ID: id, Command: "long", State: RunRunning, StartedAt: time.Now().Add(-time.Minute), PaneID: runPane}, LogPath: logPath}
	_ = writeRunFile(r.runFilePath(id), rf)
	rec := &runRec{}
	r.AddListener(rec)
	r.runKillAfter = 100 * time.Millisecond
	r.LoadRuns(context.Background())
	if rs := r.AllRuns(); len(rs) != 1 || rs[0].State != RunRunning || !rs[0].Recovered {
		t.Fatalf("runs after load %+v", rs)
	}
	waitFor(t, "tail", func() bool { got, _ := rec.last(); return strings.Contains(got.Tail, "step 1") })

	f, _ := os.OpenFile(logPath, os.O_APPEND|os.O_WRONLY, 0o600)
	_, _ = f.WriteString("step 2\n\n[exit 4]\n")
	f.Close()
	_ = os.WriteFile(logPath+".rc", []byte("4\n"), 0o600)
	waitFor(t, "done", func() bool { got, _ := rec.last(); return got.State == RunDone })
	got, _ := rec.last()
	if got.Exit == nil || *got.Exit != 4 || !strings.Contains(got.Tail, "step 2") || got.EndedAt.IsZero() {
		t.Fatalf("ended run %+v", got)
	}
	// The run's own window is closed after the (shortened) delay.
	waitFor(t, "window closed", func() bool {
		panes, _ := tm.ListPanes(context.Background())
		for _, p := range panes {
			if p.PaneID == runPane {
				return false
			}
		}
		return true
	})
	if fr, err := readRunFile(r.runFilePath(id)); err != nil || fr.Run.State != RunDone || fr.Run.PaneID != "" {
		t.Fatalf("persisted %+v %v", fr, err)
	}
}

// Runs that ended more than a day ago are dropped; a running run whose
// window vanished is marked stopped.
func TestReloadDropsOldAndLostRuns(t *testing.T) {
	r := newRunRegistry(tmux.NewPrivateClient("tmux", "porthole-test-reload-none"), filepath.Join(t.TempDir(), "runs"))
	dir := r.runsDir()
	_ = os.MkdirAll(dir, 0o700)
	exit := 0
	old := runFile{Run: Run{Key: "claude:x", ID: "00000001", State: RunDone, Exit: &exit, EndedAt: time.Now().Add(-25 * time.Hour)}}
	_ = writeRunFile(r.runFilePath("00000001"), old)
	_ = os.WriteFile(filepath.Join(dir, "00000002.log"), []byte("half\n"), 0o600)
	lost := runFile{Run: Run{Key: "claude:x", ID: "00000002", State: RunRunning, PaneID: "%77"}}
	_ = writeRunFile(r.runFilePath("00000002"), lost)
	_ = os.WriteFile(filepath.Join(dir, "garbage.json"), []byte("{"), 0o600)
	r.LoadRuns(context.Background())
	rs := r.AllRuns()
	if len(rs) != 1 || rs[0].ID != "00000002" || rs[0].State != RunStopped || rs[0].Tail != "half" {
		t.Fatalf("runs %+v", rs)
	}
	if _, err := os.Stat(r.runFilePath("00000001")); !os.IsNotExist(err) {
		t.Fatal("old run state kept")
	}
	if _, _, err := r.RunLog("claude:x", "nope"); err == nil {
		t.Fatal("unknown run log served")
	}
}

func TestRunLogTruncates(t *testing.T) {
	r := newRunRegistry(nil, t.TempDir())
	logPath := filepath.Join(r.runsDir(), "0000000a.log")
	body := strings.Repeat("é", runLogMax) // two bytes each
	_ = os.WriteFile(logPath, []byte(body), 0o600)
	r.runs["claude:x"] = map[string]*runState{"0000000a": {run: Run{Key: "claude:x", ID: "0000000a"}, logPath: logPath, quit: make(chan struct{})}}
	text, trunc, err := r.RunLog("claude:x", "0000000a")
	if err != nil || !trunc || len(text) != runLogMax || !strings.HasPrefix(body, text) {
		t.Fatalf("log %d %v %v", len(text), trunc, err)
	}
}
