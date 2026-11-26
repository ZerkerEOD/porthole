package core

import (
	"sync"
	"testing"
	"time"
)

type gateRec struct {
	mu      sync.Mutex
	kinds   []string
	idle    bool
	pending bool
	now     time.Time
}

func (g *gateRec) emit(kind, key, text string) {
	g.mu.Lock()
	g.kinds = append(g.kinds, kind)
	g.mu.Unlock()
}

func (g *gateRec) got() []string {
	g.mu.Lock()
	defer g.mu.Unlock()
	return append([]string(nil), g.kinds...)
}

func (g *gateRec) setIdle(v bool)    { g.mu.Lock(); g.idle = v; g.mu.Unlock() }
func (g *gateRec) setPending(v bool) { g.mu.Lock(); g.pending = v; g.mu.Unlock() }
func (g *gateRec) advance(d time.Duration) {
	g.mu.Lock()
	g.now = g.now.Add(d)
	g.mu.Unlock()
}

func newTestGate() (*AttentionGate, *gateRec) {
	rec := &gateRec{idle: true, now: time.Unix(1_000_000, 0)}
	g := newAttentionGate(rec.emit,
		func(string) bool { rec.mu.Lock(); defer rec.mu.Unlock(); return rec.idle },
		func(string) bool { rec.mu.Lock(); defer rec.mu.Unlock(); return rec.pending })
	g.delay = 20 * time.Millisecond
	g.now = func() time.Time { rec.mu.Lock(); defer rec.mu.Unlock(); return rec.now }
	return g, rec
}

func expectKinds(t *testing.T, rec *gateRec, want ...string) {
	t.Helper()
	got := rec.got()
	if len(got) != len(want) {
		t.Fatalf("notices %v, want %v", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("notices %v, want %v", got, want)
		}
	}
}

func settle(g *AttentionGate) { time.Sleep(4 * g.delay) }

func TestAttentionTurnEndThenIdlePrompt(t *testing.T) {
	g, rec := newTestGate()
	g.Stop("k", "t")
	g.Stop("k", "t") // a repeated Stop in the same wait
	settle(g)
	expectKinds(t, rec, "done")
	// The idle_prompt that follows a turn end adds nothing.
	g.Input("k", "idle")
	g.Stop("k", "t")
	settle(g)
	expectKinds(t, rec, "done")
}

func TestAttentionNewPromptAndPermission(t *testing.T) {
	g, rec := newTestGate()
	g.Stop("k", "t")
	settle(g)
	g.Reset("k") // UserPromptSubmit
	g.Permission("k", "Bash")
	g.Permission("k", "Bash")
	expectKinds(t, rec, "done", "permission")
	g.Reset("k") // the permission was answered
	g.Permission("k", "Edit")
	expectKinds(t, rec, "done", "permission", "permission")
	// The turn ends in a new wait: one done again.
	g.Reset("k")
	g.Stop("k", "t")
	settle(g)
	expectKinds(t, rec, "done", "permission", "permission", "done")
}

func TestAttentionChainedTurnNoDone(t *testing.T) {
	g, rec := newTestGate()
	g.Stop("k", "t")
	g.Reset("k") // a chained prompt inside the delay
	settle(g)
	expectKinds(t, rec)
	// A session that went busy without a reset (status no longer idle)
	// also drops the pending done.
	g.Stop("k", "t")
	rec.setIdle(false)
	settle(g)
	expectKinds(t, rec)
}

func TestAttentionInputAndQuestion(t *testing.T) {
	g, rec := newTestGate()
	g.Input("k", "idle")
	g.Input("k", "idle")
	g.Stop("k", "t") // after an input, a turn end is not news
	settle(g)
	expectKinds(t, rec, "input")
	g.Reset("k")
	// A question cancels a pending done and notifies once per wait.
	g.Stop("k", "t")
	g.Question("k", "q")
	g.Question("k", "q2")
	settle(g)
	expectKinds(t, rec, "input", "input")
	// A dialog recovered after a turn end still notifies.
	g.Reset("k")
	g.Stop("k", "t")
	settle(g)
	g.Question("k", "q")
	expectKinds(t, rec, "input", "input", "done", "input")
	// Keys are independent; Forget drops a pending done.
	g.Stop("other", "t")
	g.Forget("other")
	settle(g)
	expectKinds(t, rec, "input", "input", "done", "input")
}

// An auto-mode session resumes on its own: Stop, busy, Stop again with no
// prompt in between sends one done.
func TestAttentionResumeWithoutPromptOneDone(t *testing.T) {
	g, rec := newTestGate()
	g.Stop("k", "t")
	settle(g)
	rec.setIdle(false) // resumed; no Reset, no prompt
	rec.setIdle(true)
	g.Stop("k", "t")
	settle(g)
	expectKinds(t, rec, "done")
}

// A turn end with background work is held until the work is finished and
// the session has stayed out of busy for the quiet period; the idle prompt
// after it adds nothing.
func TestAttentionHeldForBackgroundWork(t *testing.T) {
	g, rec := newTestGate()
	rec.setPending(true)
	g.Stop("k", "t")
	settle(g)
	expectKinds(t, rec)
	g.Input("k", "idle") // idle_prompt while the done is held
	rec.advance(time.Minute)
	g.Tick()
	expectKinds(t, rec)
	rec.setPending(false)
	g.Tick() // quiet period starts now
	rec.advance(g.quiet / 2)
	g.Tick()
	expectKinds(t, rec)
	rec.setIdle(false) // the model woke on the completion notice
	rec.advance(g.quiet)
	g.Tick()
	expectKinds(t, rec)
	rec.setIdle(true)
	g.Tick()
	rec.advance(g.quiet)
	g.Tick()
	expectKinds(t, rec, "done")
	g.Tick()
	g.Input("k", "idle")
	expectKinds(t, rec, "done")
}

// A Stop while a done is held drops it and evaluates the new turn end.
func TestAttentionHeldDoneReplacedByNewStop(t *testing.T) {
	g, rec := newTestGate()
	rec.setPending(true)
	g.Stop("k", "first")
	settle(g)
	rec.setPending(false)
	g.Stop("k", "second") // resumed and stopped again, nothing pending now
	settle(g)
	expectKinds(t, rec, "done")
	rec.advance(time.Hour)
	g.Tick()
	expectKinds(t, rec, "done")
	// A new prompt starts a new wait.
	g.Reset("k")
	g.Stop("k", "t")
	settle(g)
	expectKinds(t, rec, "done", "done")
}
