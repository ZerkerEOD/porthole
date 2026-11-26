package core

import (
	"context"
	"log/slog"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/ZerkerEOD/porthole/daemon/internal/config"
	"github.com/ZerkerEOD/porthole/daemon/internal/tmux"
	"github.com/ZerkerEOD/porthole/daemon/internal/transcript"
)

func TestRunArgvPassesCommandAsArgument(t *testing.T) {
	cmd := `echo "$(id)"; rm -rf "$HOME"`
	argv := runArgv(cmd, "/x/a1b2c3d4.log")
	if len(argv) != 6 || argv[0] != "sh" || argv[1] != "-c" || argv[4] != cmd || argv[5] != "/x/a1b2c3d4.log" {
		t.Fatalf("argv %q", argv)
	}
	if strings.Contains(argv[2], cmd) {
		t.Fatal("command spliced into the script")
	}
}

func TestParseExitAndTail(t *testing.T) {
	log := "a\nb\n[exit 0]\n\n[exit 3]\n"
	if n, ok := parseExit([]byte(log)); !ok || n != 3 {
		t.Fatalf("exit %d %v", n, ok)
	}
	if _, ok := parseExit([]byte("a\n[exit 3] trailing\n")); ok {
		t.Fatal("exit parsed from a non-exit line")
	}
	if got := stripExit("hi\n[exit 3]\n"); got != "hi" {
		t.Fatalf("strip %q", got)
	}
	if got := stripExit("[exit 0]\n"); got != "" {
		t.Fatalf("strip only %q", got)
	}
	if got := tailLines("1\n2\n3\n4\n", 2, 100); got != "3\n4" {
		t.Fatalf("tail %q", got)
	}
	if got := tailLines("1\n2", 5, 100); got != "1\n2" {
		t.Fatalf("tail short %q", got)
	}
	if got := tailLines("abcdef", 5, 3); got != "def" {
		t.Fatalf("tail bytes %q", got)
	}
	want := "I ran this in a separate window:\n```\n$ ls\na\nb\n[exit 0]\n```"
	if got := feedText("ls", "a\nb", 0); got != want {
		t.Fatalf("feed %q", got)
	}
	if got := feedText("cat x.md", "```go\n```", 1); !strings.HasPrefix(got, "I ran this in a separate window:\n````\n") {
		t.Fatalf("fence %q", got)
	}
}

type runRec struct {
	recorder
	mu   sync.Mutex
	runs []Run
}

func (r *runRec) RunUpdated(run Run) { r.mu.Lock(); r.runs = append(r.runs, run); r.mu.Unlock() }
func (r *runRec) last() (Run, int) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if len(r.runs) == 0 {
		return Run{}, 0
	}
	return r.runs[len(r.runs)-1], len(r.runs)
}

func TestRunCommandEndToEnd(t *testing.T) {
	if _, err := exec.LookPath("tmux"); err != nil {
		t.Skip("tmux not installed")
	}
	tm := tmux.NewPrivateClient("tmux", "porthole-test-runs")
	ctx := context.Background()
	t.Cleanup(func() { _ = exec.Command("tmux", "-L", "porthole-test-runs", "kill-server").Run() })
	work := t.TempDir()
	typed := filepath.Join(work, "typed.txt")
	pane, err := tm.NewSession(ctx, "rt1", work, []string{"sh", "-c", "cat > " + typed}, nil)
	if err != nil {
		t.Fatal(err)
	}
	r := New(config.Default(), slog.New(slog.NewTextHandler(os.Stderr, nil)))
	r.tm = tm
	r.runDir = filepath.Join(t.TempDir(), "runs")
	r.runPoll = 50 * time.Millisecond
	rec := &runRec{}
	r.AddListener(rec)
	key := "claude:abc"
	r.upsert(Session{Key: key, ID: "abc", Provider: "claude", Running: true, Controllable: true, PaneID: pane, TmuxSession: "rt1", Cwd: work, Status: transcript.StatusIdle})

	run, err := r.RunCommand(ctx, key, "printf hi; exit 3", true, "dev1")
	if err != nil {
		t.Fatal(err)
	}
	if len(run.ID) != 8 || run.State != RunRunning || !tmux.ValidPaneID(run.PaneID) || run.Device != "dev1" {
		t.Fatalf("run %+v", run)
	}
	if fi, err := os.Stat(r.runDir); err != nil || fi.Mode().Perm() != 0o700 {
		t.Fatalf("run dir %v %v", fi, err)
	}
	if fi, err := os.Stat(filepath.Join(r.runDir, run.ID+".log")); err != nil || fi.Mode().Perm() != 0o600 {
		t.Fatalf("log %v %v", fi, err)
	}
	deadline := time.Now().Add(10 * time.Second)
	var got Run
	for time.Now().Before(deadline) {
		got, _ = rec.last()
		if got.Fed {
			break
		}
		time.Sleep(50 * time.Millisecond)
	}
	if got.State != RunDone || got.Exit == nil || *got.Exit != 3 || !strings.Contains(got.Tail, "hi") || !got.Fed || got.Queued || got.EndedAt.IsZero() {
		t.Fatalf("final run %+v", got)
	}
	var b []byte
	for time.Now().Before(deadline) {
		b, _ = os.ReadFile(typed)
		if strings.Contains(string(b), "[exit 3]") {
			break
		}
		time.Sleep(50 * time.Millisecond)
	}
	if !strings.Contains(string(b), "I ran this in a separate window:") || !strings.Contains(string(b), "$ printf hi; exit 3\nhi\n[exit 3]") {
		t.Fatalf("typed %q", b)
	}
	if rs := r.Runs(key); len(rs) != 1 || rs[0].ID != run.ID {
		t.Fatalf("runs %+v", rs)
	}

	// Stop a long command: Ctrl-C ends it and the run is marked stopped.
	run2, err := r.RunCommand(ctx, key, "sleep 30", false, "dev1")
	if err != nil {
		t.Fatal(err)
	}
	time.Sleep(300 * time.Millisecond)
	if err := r.StopRun(ctx, key, run2.ID); err != nil {
		t.Fatal(err)
	}
	for time.Now().Before(deadline) {
		got, _ = rec.last()
		if got.ID == run2.ID && got.State != RunRunning {
			break
		}
		time.Sleep(50 * time.Millisecond)
	}
	if got.ID != run2.ID || got.State != RunStopped || got.Exit == nil || *got.Exit != 130 {
		t.Fatalf("stopped run %+v", got)
	}

	// Dismiss closes the window and forgets the run.
	if err := r.DismissRun(ctx, key, run2.ID); err != nil {
		t.Fatal(err)
	}
	panes, _ := tm.ListPanes(ctx)
	for _, p := range panes {
		if p.PaneID == run2.PaneID {
			t.Fatal("window of a dismissed run still open")
		}
	}
	if rs := r.Runs(key); len(rs) != 1 {
		t.Fatalf("runs after dismiss %+v", rs)
	}

	// Validation.
	if _, err := r.RunCommand(ctx, key, "  ", false, ""); err == nil {
		t.Fatal("empty command accepted")
	}
	if _, err := r.RunCommand(ctx, key, strings.Repeat("x", 4097), false, ""); err == nil {
		t.Fatal("long command accepted")
	}
	if _, err := r.RunCommand(ctx, "claude:none", "true", false, ""); err == nil {
		t.Fatal("unknown session accepted")
	}
	// Forgetting the session drops its runs.
	r.remove(key)
	if rs := r.Runs(key); len(rs) != 0 {
		t.Fatalf("runs after remove %+v", rs)
	}
}

// A session that looks idle while a subagent or a background task runs is
// reported busy; a permission prompt still shows.
func TestHoldBusyWithBackgroundWork(t *testing.T) {
	s := Session{Running: true, Status: transcript.StatusIdle, PendingTasks: 1}
	holdBusy(&s)
	if s.Status != transcript.StatusBusy {
		t.Fatalf("pending task: %s", s.Status)
	}
	s = Session{Running: true, Status: transcript.StatusWaitingInput, Agents: []transcript.AgentInfo{{ID: "a", Running: true}}}
	holdBusy(&s)
	if s.Status != transcript.StatusBusy {
		t.Fatalf("running agent: %s", s.Status)
	}
	s = Session{Running: true, Status: transcript.StatusWaitingPermission, PendingTasks: 1}
	holdBusy(&s)
	if s.Status != transcript.StatusWaitingPermission {
		t.Fatalf("permission: %s", s.Status)
	}
	s = Session{Running: true, Status: transcript.StatusWaitingInput, PendingTasks: 1, Question: &Question{ID: "q"}}
	holdBusy(&s)
	if s.Status != transcript.StatusWaitingInput {
		t.Fatalf("question: %s", s.Status)
	}
	s = Session{Running: true, Status: transcript.StatusIdle, Agents: []transcript.AgentInfo{{ID: "a"}}}
	holdBusy(&s)
	if s.Status != transcript.StatusIdle {
		t.Fatalf("finished agent: %s", s.Status)
	}
}

// The registry no longer resets the notice gate when a Claude session turns
// busy, so a resume without a prompt keeps the wait; SetStatus from the
// Stop hook keeps a session with background work busy.
func TestRegistryStopBusyStopOneDone(t *testing.T) {
	r := New(config.Default(), slog.New(slog.NewTextHandler(os.Stderr, nil)))
	var mu sync.Mutex
	var kinds []string
	r.OnAttention(func(kind, key, text string) { mu.Lock(); kinds = append(kinds, kind); mu.Unlock() })
	r.gate.delay = 10 * time.Millisecond
	key := "claude:s1"
	r.upsert(Session{Key: key, ID: "s1", Provider: "claude", Running: true, Status: transcript.StatusBusy})
	r.SetStatus(key, transcript.StatusIdle)
	r.gate.Stop(key, "t")
	time.Sleep(50 * time.Millisecond)
	r.SetStatus(key, transcript.StatusBusy) // resumed on its own
	r.SetStatus(key, transcript.StatusIdle)
	r.gate.Stop(key, "t")
	time.Sleep(50 * time.Millisecond)
	mu.Lock()
	got := append([]string(nil), kinds...)
	mu.Unlock()
	if len(got) != 1 || got[0] != "done" {
		t.Fatalf("notices %v", got)
	}

	s, _ := r.Get(key)
	s.PendingTasks = 1
	r.upsert(s)
	r.SetStatus(key, transcript.StatusIdle)
	if s, _ := r.Get(key); s.Status != transcript.StatusBusy {
		t.Fatalf("status with a pending task: %s", s.Status)
	}
}
