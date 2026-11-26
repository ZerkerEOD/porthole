package core

import (
	"context"
	"log/slog"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/ZerkerEOD/porthole/daemon/internal/config"
	"github.com/ZerkerEOD/porthole/daemon/internal/tmux"
	"github.com/ZerkerEOD/porthole/daemon/internal/transcript"
)

var queueTwo = []string{
	"first queued message from the keyboard",
	"second queued one with a longer body that should still be read as a single queued message",
}

func TestParseQueuedFixtures(t *testing.T) {
	for _, tc := range []struct {
		file string
		want []string
	}{
		{"queue_none.ansi", nil},
		{"queue_two.ansi", queueTwo},
		{"queue_two_draft.ansi", queueTwo},
		// A narrow pane: one message wrapped by the CLI, one pasted with
		// its own newlines; both come back as one message each.
		{"queue_wrap_paste.ansi", []string{
			"a single queued message that is quite long so that it has to wrap onto a second line of the narrow pane here",
			"line one of a pasted message line two of it line three",
		}},
		{"prompt_draft.txt", nil},
		{"prompt_shell.txt", nil},
		{"mode_plan.ansi", nil},
	} {
		if got := parseQueued(readLines(t, tc.file)); !reflect.DeepEqual(got, tc.want) {
			t.Errorf("%s: got %q want %q", tc.file, got, tc.want)
		}
	}
}

func TestParseQueuedWrapsAndCaps(t *testing.T) {
	const dim = "\x1b[38;5;246m"
	scr := []string{
		dim + "\x1b[48;5;237m❯ \x1b[38;5;231mthe submitted prompt that",
		"  wrapped as well\x1b[39m",
		"",
		dim + "❯ a queued message that wraps onto",
		"  a second line\x1b[39m",
		"\x1b[49m",
		dim + "\x1b[48;5;237m❯ another\x1b[39m",
		"\x1b[49m  " + dim + "ctrl+x ctrl+s to send now\x1b[39m",
		"",
		"✻ Crystallizing… (6s)",
	}
	want := []string{"a queued message that wraps onto a second line", "another"}
	if got := parseQueued(scr); !reflect.DeepEqual(got, want) {
		t.Fatalf("got %q want %q", got, want)
	}

	// Output above the block ends it; it is not read as a continuation.
	scr = []string{"⏺ Some answer text", dim + "❯ only one", "  ctrl+x ctrl+s to send now"}
	if got := parseQueued(scr); !reflect.DeepEqual(got, []string{"only one"}) {
		t.Fatalf("got %q", got)
	}

	var many []string
	for i := 0; i < 30; i++ {
		many = append(many, dim+"❯ m", "")
	}
	many[len(many)-1] = "  ctrl+x ctrl+s to send now"
	if got := parseQueued(many); len(got) != queueMax {
		t.Fatalf("cap: %d messages", len(got))
	}
	long := parseQueued([]string{dim + "❯ " + strings.Repeat("é", 3000), "  ctrl+x ctrl+s to send now"})
	if len(long) != 1 || len(long[0]) > queueMaxBytes || !strings.HasSuffix(long[0], "…") {
		t.Fatalf("long message: %d bytes", len(long[0]))
	}
}

func TestSetQueuedPublishesChanges(t *testing.T) {
	r := New(config.Default(), slog.New(slog.NewTextHandler(os.Stderr, nil)))
	rec := &recorder{}
	r.AddListener(rec)
	r.upsert(Session{Key: "claude:s", ID: "s", Provider: "claude", Running: true, Controllable: true, PaneID: "%1", Status: transcript.StatusBusy})
	rec.calls = nil

	r.SetQueued("claude:s", queueTwo)
	if s, _ := r.Get("claude:s"); !reflect.DeepEqual(s.Queued, queueTwo) || len(rec.calls) != 1 {
		t.Fatalf("set: %q, calls %v", s.Queued, rec.calls)
	}
	r.SetQueued("claude:s", append([]string(nil), queueTwo...))
	if len(rec.calls) != 1 {
		t.Fatalf("same list published again: %v", rec.calls)
	}
	// The scan's merge keeps the queue while the session runs.
	live := Session{Key: "claude:s", ID: "s", Provider: "claude", Running: true, Controllable: true, PaneID: "%1", Status: transcript.StatusBusy}
	r.finishLive(&live, "")
	if s, _ := r.Get("claude:s"); !reflect.DeepEqual(s.Queued, queueTwo) {
		t.Fatalf("scan dropped the queue: %q", s.Queued)
	}
	r.SetQueued("claude:s", nil)
	if s, _ := r.Get("claude:s"); s.Queued != nil || len(rec.calls) != 3 {
		t.Fatalf("clear: %q, calls %v", s.Queued, rec.calls)
	}
	r.SetQueued("claude:s", []string{})
	if len(rec.calls) != 3 {
		t.Fatalf("empty after nil published: %v", rec.calls)
	}
	// Codex sessions never hold a queue.
	r.upsert(Session{Key: "codex:c", ID: "c", Provider: "codex", Running: true, Controllable: true, PaneID: "%2"})
	r.SetQueued("codex:c", queueTwo)
	if s, _ := r.Get("codex:c"); s.Queued != nil {
		t.Fatalf("codex queue %q", s.Queued)
	}
}

func TestSendBangRefusesBehindQueue(t *testing.T) {
	if _, err := exec.LookPath("tmux"); err != nil {
		t.Skip("tmux not installed")
	}
	tm := tmux.NewPrivateClient("tmux", "porthole-test-queue")
	ctx := context.Background()
	t.Cleanup(func() { _ = exec.Command("tmux", "-L", "porthole-test-queue", "kill-server").Run() })
	work := t.TempDir()
	typed := filepath.Join(work, "typed.txt")
	script := `printf '\033[38;5;246m\342\235\257 one queued\033[39m\n\n\033[38;5;246m\342\235\257 two queued\033[39m\n  ctrl+x ctrl+s to send now\n'; stty raw -echo; exec cat > ` + typed
	pane, err := tm.NewSession(ctx, "q1", work, []string{"sh", "-c", script}, nil)
	if err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(5 * time.Second)
	for {
		scr, err := tm.Capture(ctx, pane, 0)
		if err == nil && len(parseQueued(scr.Lines)) == 2 {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("queue never showed: %v", err)
		}
		time.Sleep(50 * time.Millisecond)
	}
	time.Sleep(100 * time.Millisecond) // let stty and cat start
	r := New(config.Default(), slog.New(slog.NewTextHandler(os.Stderr, nil)))
	r.tm = tm
	err = r.sendBang(ctx, "claude:q", pane, "ls")
	if err == nil || err.Error() != "2 messages are queued ahead of this; the command would only be queued behind them" {
		t.Fatalf("err %v", err)
	}
	time.Sleep(200 * time.Millisecond)
	if b, _ := os.ReadFile(typed); len(b) != 0 {
		t.Fatalf("typed %q", b)
	}
}

// A leading line equal to the transcript's last prompt is the submitted
// prompt, whatever the theme drew it in.
func TestSetQueuedDropsSubmittedPrompt(t *testing.T) {
	r := New(config.Default(), slog.New(slog.NewTextHandler(os.Stderr, nil)))
	r.upsert(Session{Key: "claude:p", ID: "p", Provider: "claude", Running: true, Controllable: true, PaneID: "%1", Status: transcript.StatusBusy, LastPrompt: "Write a story."})
	r.SetQueued("claude:p", []string{"Write a story.", "then this"})
	if s, _ := r.Get("claude:p"); !reflect.DeepEqual(s.Queued, []string{"then this"}) {
		t.Fatalf("prompt kept: %q", s.Queued)
	}
	r.SetQueued("claude:p", []string{"Write a story."})
	if s, _ := r.Get("claude:p"); s.Queued != nil {
		t.Fatalf("lone prompt kept: %q", s.Queued)
	}
}
