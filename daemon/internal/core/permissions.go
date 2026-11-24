package core

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"sync"
	"time"

	"github.com/ZerkerEOD/porthole/daemon/internal/transcript"
)

// permissionBroker holds PermissionRequest hooks open until a phone answers
// or the timeout elapses, in which case the hook returns no decision and the
// terminal prompt appears as usual.
type permissionBroker struct {
	r       *Registry
	mu      sync.Mutex
	pending map[string]*pendingPerm
}

type pendingPerm struct {
	req  PermissionRequest
	done chan string // "allow" | "deny"
}

func newPermissionBroker(r *Registry) *permissionBroker {
	return &permissionBroker{r: r, pending: map[string]*pendingPerm{}}
}

// Pending lists open requests.
func (b *permissionBroker) Pending() []PermissionRequest {
	b.mu.Lock()
	defer b.mu.Unlock()
	out := make([]PermissionRequest, 0, len(b.pending))
	for _, p := range b.pending {
		out = append(out, p.req)
	}
	return out
}

// HasSubscribers reports whether any client is watching this session, which
// is the condition for holding the hook open at all.
func (b *permissionBroker) hasSubscribers(key string) bool {
	b.r.mu.RLock()
	defer b.r.mu.RUnlock()
	return b.r.subs[key] > 0 || b.r.paneSubs[key] > 0
}

// Ask publishes a request and waits for an answer. It returns "" when nobody
// answered in time (caller then emits no decision).
func (b *permissionBroker) Ask(ctx context.Context, sessionKey, tool string, input map[string]any, cwd string, timeout time.Duration) string {
	if !b.hasSubscribers(sessionKey) {
		// Nobody is watching: don't stall the terminal. Still flag the status.
		b.r.SetStatus(sessionKey, transcript.StatusWaitingPermission)
		return ""
	}
	var rnd [8]byte
	_, _ = rand.Read(rnd[:])
	req := PermissionRequest{ID: hex.EncodeToString(rnd[:]), SessionKey: sessionKey, ToolName: tool, ToolInput: input, Cwd: cwd, CreatedAt: time.Now(), ExpiresAt: time.Now().Add(timeout)}
	p := &pendingPerm{req: req, done: make(chan string, 1)}
	b.mu.Lock()
	b.pending[req.ID] = p
	b.mu.Unlock()
	b.r.SetStatus(sessionKey, transcript.StatusWaitingPermission)
	b.r.each(func(l Listener) { l.PermissionPending(req) })
	defer func() {
		b.mu.Lock()
		delete(b.pending, req.ID)
		b.mu.Unlock()
	}()
	select {
	case ans := <-p.done:
		b.r.each(func(l Listener) { l.PermissionResolved(req.ID, ans) })
		b.r.gate.Reset(sessionKey)
		b.r.SetStatus(sessionKey, transcript.StatusBusy)
		return ans
	case <-time.After(timeout):
		b.r.each(func(l Listener) { l.PermissionResolved(req.ID, "timeout") })
		return ""
	case <-ctx.Done():
		b.r.each(func(l Listener) { l.PermissionResolved(req.ID, "cancelled") })
		return ""
	}
}

// Answer resolves a pending request.
func (b *permissionBroker) Answer(id, behavior string) error {
	if behavior != "allow" && behavior != "deny" {
		return errors.New("behavior must be allow or deny")
	}
	b.mu.Lock()
	p, ok := b.pending[id]
	b.mu.Unlock()
	if !ok {
		return errors.New("no such pending permission")
	}
	select {
	case p.done <- behavior:
	default:
	}
	return nil
}
