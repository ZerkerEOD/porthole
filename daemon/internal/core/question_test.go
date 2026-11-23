package core

import (
	"log/slog"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/ZerkerEOD/porthole/daemon/internal/config"
	"github.com/ZerkerEOD/porthole/daemon/internal/tmux"
	"github.com/ZerkerEOD/porthole/daemon/internal/transcript"
)

const askUse = `{"type":"assistant","uuid":"a1","timestamp":"2026-11-22T20:31:00Z","message":{"id":"m1","role":"assistant","model":"m","content":[{"type":"tool_use","id":"toolu_1","name":"AskUserQuestion","input":{"questions":[{"question":"Which option do you pick?","header":"Pick","multiSelect":false,"options":[{"label":"A","description":"Option A"},{"label":"B","description":"Option B"}]},{"question":"Which of these?","header":"Multi","multiSelect":true,"options":[{"label":"P","description":""},{"label":"Q","description":""}]}]}}]}}
`
const askResult = `{"type":"user","uuid":"u1","parentUuid":"a1","timestamp":"2026-11-22T20:31:10Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_1","content":"Your questions have been answered: \"Which option do you pick?\"=\"B\"."}]}}
`

func TestQuestionLifecycle(t *testing.T) {
	path := filepath.Join(t.TempDir(), "s.jsonl")
	if err := os.WriteFile(path, []byte(askUse), 0o600); err != nil {
		t.Fatal(err)
	}
	r := New(config.Default(), slog.New(slog.NewTextHandler(os.Stderr, nil)))
	var notices []string
	r.OnAttention(func(kind, key, text string) { notices = append(notices, kind+"|"+key+"|"+text) })
	r.upsert(Session{Key: "claude:s", ID: "s", Provider: "claude", Running: true, Status: transcript.StatusBusy, TranscriptPath: path, PaneID: "%1", Controllable: true})
	if _, _, err := r.Subscribe("claude:s", 0, 10); err != nil {
		t.Fatal(err)
	}
	items := []QuestionItem{{Question: "Which option do you pick?", Header: "Pick", Options: []QuestionOption{{Label: "A"}, {Label: "B"}}}}
	q := r.SetQuestion("claude:s", items)
	if q == nil || q.ID == "" {
		t.Fatal("no question")
	}
	if s, _ := r.Get("claude:s"); s.Question != q || s.Status != transcript.StatusWaitingInput {
		t.Fatalf("session %+v", s)
	}
	if len(notices) != 1 || notices[0] != "input|claude:s|Which option do you pick?" {
		t.Fatalf("notices %v", notices)
	}
	// The hook may repeat the same dialog: same id, no second notice.
	if r.SetQuestion("claude:s", items) != q || len(notices) != 1 {
		t.Fatal("repeat dialog changed id or notified again")
	}
	// The 3 s scan keeps it while the transcript is silent.
	live := Session{Key: "claude:s", ID: "s", Provider: "claude", Running: true, Status: transcript.StatusBusy, TranscriptPath: path, PaneID: "%1", Controllable: true}
	r.finishLive(&live, path)
	if s, _ := r.Get("claude:s"); s.Question != q || s.Status != transcript.StatusWaitingInput {
		t.Fatalf("scan dropped the question: %+v", s)
	}
	// A result stamped after the dialog opened closes it.
	fh, _ := os.OpenFile(path, os.O_APPEND|os.O_WRONLY, 0o600)
	_, _ = fh.WriteString(strings.Replace(askResult, "2026-11-22T20:31:10Z", "2031-01-01T00:00:00Z", 1))
	_ = fh.Close()
	r.pumpAll()
	if s, _ := r.Get("claude:s"); s.Question != nil || s.Status != transcript.StatusBusy {
		t.Fatalf("result did not clear the question: %+v", s)
	}
	// Hook-driven statuses clear it too.
	r.SetQuestion("claude:s", items)
	r.SetStatus("claude:s", transcript.StatusIdle)
	if s, _ := r.Get("claude:s"); s.Question != nil {
		t.Fatal("SetStatus kept the question")
	}
	r.SetQuestion("claude:s", items)
	r.ClearQuestion("claude:s", "other")
	if s, _ := r.Get("claude:s"); s.Question == nil {
		t.Fatal("ClearQuestion with a foreign id cleared")
	}
	r.ClearQuestion("claude:s", "")
	if s, _ := r.Get("claude:s"); s.Question != nil || s.Status != transcript.StatusBusy {
		t.Fatalf("ClearQuestion: %+v", s)
	}
	if len(notices) != 3 {
		t.Fatalf("one notice per dialog, got %v", notices)
	}
}

func TestQuestionClosedBy(t *testing.T) {
	at := time.Date(2030, 1, 1, 0, 0, 0, 0, time.UTC)
	before := transcript.Event{Type: transcript.TypeToolResult, TS: at.Add(-time.Second)}
	after := transcript.Event{Type: transcript.TypeToolResult, TS: at.Add(time.Second)}
	use := transcript.Event{Type: transcript.TypeToolUse, TS: at.Add(time.Second)}
	side := transcript.Event{Type: transcript.TypeUser, TS: at.Add(time.Second), Sidechain: true}
	if questionClosedBy([]transcript.Event{before, use, side}, at) {
		t.Fatal("closed by events that do not end the dialog")
	}
	if !questionClosedBy([]transcript.Event{before, after}, at) {
		t.Fatal("a later result must close it")
	}
}

func TestValidateAnswers(t *testing.T) {
	one := 1
	three := 3
	q := &Question{ID: "x", Questions: []QuestionItem{
		{Question: "a", Options: []QuestionOption{{Label: "A"}, {Label: "B"}}},
		{Question: "b", MultiSelect: true, Options: []QuestionOption{{Label: "P"}, {Label: "Q"}}},
	}}
	good := []Answer{{Index: &one}, {Indices: []int{0, 1}}}
	if err := validateAnswers(q, good); err != nil {
		t.Fatal(err)
	}
	if err := validateAnswers(q, []Answer{{Text: "other"}, {Text: "typed"}}); err != nil {
		t.Fatal(err)
	}
	bad := [][]Answer{
		{{Index: &one}},
		{{Index: &three}, {Indices: []int{0}}},
		{{Index: &one, Text: "both"}, {Indices: []int{0}}},
		{{}, {Indices: []int{0}}},
		{{Indices: []int{0}}, {Indices: []int{0}}},
		{{Index: &one}, {Index: &one}},
		{{Index: &one}, {}},
		{{Index: &one}, {Indices: []int{0, 0}}},
		{{Index: &one}, {Indices: []int{2}}},
	}
	for i, b := range bad {
		if err := validateAnswers(q, b); err == nil {
			t.Errorf("case %d accepted", i)
		}
	}
}

func TestScreenChecks(t *testing.T) {
	scr := &tmux.Screen{Lines: []string{
		"\x1b[38;5;16m\x1b[48;5;153m ☐ Pick \x1b[39m\x1b[49m",
		"\x1b[1mWhich option do you pick, given everything we",
		"discussed?\x1b[0m",
		"\x1b[38;5;153m❯\x1b[39m \x1b[38;5;246m1.\x1b[39m Alpha",
		"     Option A",
		"  2. [✔] Beta",
		"",
		"Enter to select · ↑/↓ to navigate · Esc to cancel",
	}}
	text := screenText(scr)
	if strings.Contains(text, "\x1b") || !strings.Contains(text, "Which option do you pick, given everything we discussed?") {
		t.Fatalf("text %q", text)
	}
	q := QuestionItem{Question: "Which option do you pick, given everything we discussed?", Header: "Pick", Options: []QuestionOption{{Label: "Alpha"}, {Label: "Beta"}}}
	if !questionShown(text, q) {
		t.Fatal("question not detected")
	}
	if questionShown(text, QuestionItem{Question: "Another?", Header: "Other", Options: []QuestionOption{{Label: "Alpha"}}}) {
		t.Fatal("wrong question matched")
	}
	if questionShown(text, QuestionItem{Question: "Which option do you pick, given everything we discussed?", Options: []QuestionOption{{Label: "Gamma"}}}) {
		t.Fatal("matched without an option row")
	}
	if checkedCount(text) != 1 {
		t.Fatalf("checked %d", checkedCount(text))
	}
	if got := lastLines(scr, 2); got != "  2. [✔] Beta\nEnter to select · ↑/↓ to navigate · Esc to cancel" {
		t.Fatalf("last lines %q", got)
	}
}
