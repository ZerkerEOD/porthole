package core

import (
	"sync"
	"time"

	"github.com/ZerkerEOD/porthole/daemon/internal/transcript"
)

// doneDelay is how long a turn end must hold before it counts: a prompt
// chained within it belongs to the same wait and sends nothing.
const doneDelay = 2 * time.Second

// waitState is what has been sent since the session last went busy. A
// wait starts when the session stops working and ends on the next prompt,
// permission answer, question answer or other transition to busy.
type waitState struct {
	permission, input, done bool
	gen                     int // bumped on reset; a pending done timer checks it
	timer                   *time.Timer
}

// AttentionGate sends each kind of notice at most once per wait: one done
// for a turn end (after doneDelay, unless the session went busy again), one
// input for a question or idle prompt, one permission per request.
type AttentionGate struct {
	mu    sync.Mutex
	waits map[string]*waitState
	delay time.Duration
	emit  func(kind, key, text string)
	idle  func(key string) bool
}

func newAttentionGate(emit func(kind, key, text string), idle func(key string) bool) *AttentionGate {
	return &AttentionGate{waits: map[string]*waitState{}, delay: doneDelay, emit: emit, idle: idle}
}

func (g *AttentionGate) state(key string) *waitState {
	st := g.waits[key]
	if st == nil {
		st = &waitState{}
		g.waits[key] = st
	}
	return st
}

// Reset starts a new wait for key: a prompt was submitted, an answer went
// in, or the session went busy. A pending done is dropped.
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
// wait is still open and the session is still idle or waiting.
func (g *AttentionGate) Stop(key, text string) {
	g.mu.Lock()
	defer g.mu.Unlock()
	st := g.state(key)
	if st.done || st.input || st.timer != nil {
		return
	}
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
	if st.done || st.input || (g.idle != nil && !g.idle(key)) {
		g.mu.Unlock()
		return
	}
	st.done = true
	g.mu.Unlock()
	g.emit("done", key, text)
}

// Input records an idle prompt or other request for input: sent unless a
// done or an input already went out in this wait.
func (g *AttentionGate) Input(key, text string) {
	g.mu.Lock()
	st := g.state(key)
	if st.done || st.input {
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
