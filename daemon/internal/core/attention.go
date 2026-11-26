package core

import (
	"sync"
	"time"

	"github.com/ZerkerEOD/porthole/daemon/internal/transcript"
)

// doneDelay is how long a turn end must hold before it counts: a prompt
// chained within it belongs to the same wait and sends nothing.
const doneDelay = 2 * time.Second

// quietPeriod is how long a session whose background work has finished
// must stay out of busy before a held done goes out. The model usually
// resumes on the completion notice within seconds; a resumed turn ends in
// a new Stop that starts the evaluation again.
const quietPeriod = 20 * time.Second

// waitState is what has been sent in the current wait. A wait ends on the
// next prompt, permission answer or question answer (Reset). A session that
// resumes on its own (auto mode, background work finishing) stays in the
// same wait, so its repeated turn ends send one done.
type waitState struct {
	permission, input, done bool
	gen                     int // bumped on reset; a pending done timer checks it
	timer                   *time.Timer
	// held is set while a turn end waits for background work (running
	// subagents or background tasks). Tick sends the done once nothing is
	// pending and the session has been out of busy for the quiet period,
	// counted from quietSince.
	held       bool
	heldText   string
	quietSince time.Time
}

// AttentionGate sends each kind of notice at most once per wait: one done
// for a turn end (after doneDelay, unless the session went busy again), one
// input for a question or idle prompt, one permission per request.
//
// A turn end while the session still has background work is held rather
// than sent: the work finishing usually wakes the model, and the turn that
// follows ends in its own Stop.
type AttentionGate struct {
	mu      sync.Mutex
	waits   map[string]*waitState
	delay   time.Duration
	quiet   time.Duration
	now     func() time.Time
	emit    func(kind, key, text string)
	idle    func(key string) bool
	pending func(key string) bool
}

func newAttentionGate(emit func(kind, key, text string), idle, pending func(key string) bool) *AttentionGate {
	return &AttentionGate{waits: map[string]*waitState{}, delay: doneDelay, quiet: quietPeriod, now: time.Now, emit: emit, idle: idle, pending: pending}
}

func (g *AttentionGate) state(key string) *waitState {
	st := g.waits[key]
	if st == nil {
		st = &waitState{}
		g.waits[key] = st
	}
	return st
}

// Reset starts a new wait for key: a prompt was submitted or an answer went
// in. A pending or held done is dropped.
func (g *AttentionGate) Reset(key string) {
	g.mu.Lock()
	defer g.mu.Unlock()
	st := g.waits[key]
	if st == nil {
		return
	}
	if st.timer != nil {
		st.timer.Stop()
	}
	g.waits[key] = &waitState{gen: st.gen + 1}
}

// Forget drops the state of a removed session.
func (g *AttentionGate) Forget(key string) {
	g.mu.Lock()
	defer g.mu.Unlock()
	if st := g.waits[key]; st != nil && st.timer != nil {
		st.timer.Stop()
	}
	delete(g.waits, key)
}

// Stop records a turn end. The done notice goes out after the delay if the
// wait is still open and the session is still idle or waiting; with
// background work pending it is held for Tick. A Stop while a done is held
// means the model resumed and stopped again: the held done is dropped and
// this turn end is evaluated afresh.
func (g *AttentionGate) Stop(key, text string) {
	g.mu.Lock()
	defer g.mu.Unlock()
	st := g.state(key)
	if st.done || st.input || st.timer != nil {
		return
	}
	st.held = false
	gen := st.gen
	st.timer = time.AfterFunc(g.delay, func() { g.fireDone(key, gen, text) })
}

func (g *AttentionGate) fireDone(key string, gen int, text string) {
	g.mu.Lock()
	st := g.waits[key]
	if st == nil || st.gen != gen {
		g.mu.Unlock()
		return
	}
	st.timer = nil
	if st.done || st.input {
		g.mu.Unlock()
		return
	}
	if g.pending != nil && g.pending(key) {
		st.held, st.heldText, st.quietSince = true, text, g.now()
		g.mu.Unlock()
		return
	}
	if g.idle != nil && !g.idle(key) {
		g.mu.Unlock()
		return
	}
	st.done = true
	g.mu.Unlock()
	g.emit("done", key, text)
}

// Tick re-evaluates held turn ends; the registry calls it on every scan. A
// held done goes out once the session has had no pending background work
// and has not been busy for the quiet period.
func (g *AttentionGate) Tick() {
	type notice struct{ key, text string }
	var out []notice
	g.mu.Lock()
	now := g.now()
	for key, st := range g.waits {
		if !st.held {
			continue
		}
		if st.done || st.input {
			st.held = false
			continue
		}
		if (g.pending != nil && g.pending(key)) || (g.idle != nil && !g.idle(key)) {
			st.quietSince = now
			continue
		}
		if now.Sub(st.quietSince) < g.quiet {
			continue
		}
		st.held, st.done = false, true
		out = append(out, notice{key, st.heldText})
	}
	g.mu.Unlock()
	for _, n := range out {
		g.emit("done", n.key, n.text)
	}
}

// Input records an idle prompt or other request for input: sent unless a
// done or an input already went out in this wait, or a done is held for
// background work (the idle prompt then only means the model is waiting on
// that work, and the held done covers it).
func (g *AttentionGate) Input(key, text string) {
	g.mu.Lock()
	st := g.state(key)
	if st.done || st.input || st.held {
		g.mu.Unlock()
		return
	}
	st.input = true
	g.cancelDone(st)
	g.mu.Unlock()
	g.emit("input", key, text)
}

// Question records a pending question dialog: one input per wait, sent
// even after a done (a recovered dialog may follow a turn end).
func (g *AttentionGate) Question(key, text string) {
	g.mu.Lock()
	st := g.state(key)
	if st.input {
		g.mu.Unlock()
		return
	}
	st.input = true
	g.cancelDone(st)
	g.mu.Unlock()
	g.emit("input", key, text)
}

// Permission records a permission request: one per wait.
func (g *AttentionGate) Permission(key, text string) {
	g.mu.Lock()
	st := g.state(key)
	if st.permission {
		g.mu.Unlock()
		return
	}
	st.permission = true
	g.mu.Unlock()
	g.emit("permission", key, text)
}

func (g *AttentionGate) cancelDone(st *waitState) {
	st.held = false
	if st.timer != nil {
		st.timer.Stop()
		st.timer = nil
	}
}

// waiting reports whether a session is idle or waiting on the user, the
// states in which a turn end is worth a notice.
func waiting(status string) bool {
	switch status {
	case transcript.StatusIdle, transcript.StatusWaitingInput, transcript.StatusWaitingPermission:
		return true
	}
	return false
}
