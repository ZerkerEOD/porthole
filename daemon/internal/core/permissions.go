package core

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"strings"
	"sync"
	"time"

	"github.com/ZerkerEOD/porthole/daemon/internal/transcript"
)

// permissionBroker holds PermissionRequest hooks open until a phone answers
// or the timeout elapses, in which case the hook returns no decision and the
// terminal prompt appears as usual. Terminal prompts read back off the pane
// are kept here too, as recovered requests answered with keystrokes.
type permissionBroker struct {
	r         *Registry
	mu        sync.Mutex
	pending   map[string]*pendingPerm
	recovered map[string]*PermissionRequest // by request id
	// Policy hooks set by the server: whether any device opened the session
	// (so a push can reach someone), and whether a terminal is attached to
	// its tmux session (so someone at the keyboard could answer).
	openedBy func(sessionKey string) bool
	attached func(ctx context.Context, tmuxSession string) bool
	// detachedTimeout is how long to hold the hook when no phone is watching
	// but the phone is the only way to answer.
	detachedTimeout time.Duration
}

type pendingPerm struct {
	req  PermissionRequest
	done chan string // "allow" | "deny"
}

func newPermissionBroker(r *Registry) *permissionBroker {
	return &permissionBroker{r: r, pending: map[string]*pendingPerm{}, recovered: map[string]*PermissionRequest{}, detachedTimeout: 5 * time.Minute}
}

// SetPolicy wires the device store and tmux checks used to decide how long
// a hook is held.
func (b *permissionBroker) SetPolicy(openedBy func(string) bool, attached func(context.Context, string) bool, detached time.Duration) {
	b.mu.Lock()
	defer b.mu.Unlock()
	b.openedBy, b.attached = openedBy, attached
	if detached > 0 {
		b.detachedTimeout = detached
	}
}

// Pending lists open requests, hook-held and recovered.
func (b *permissionBroker) Pending() []PermissionRequest {
	b.mu.Lock()
	defer b.mu.Unlock()
	out := make([]PermissionRequest, 0, len(b.pending)+len(b.recovered))
	for _, p := range b.pending {
		out = append(out, p.req)
	}
	for _, p := range b.recovered {
		out = append(out, *p)
	}
	return out
}

// HasPending reports whether the session has any open request.
func (b *permissionBroker) HasPending(key string) bool {
	b.mu.Lock()
	defer b.mu.Unlock()
	for _, p := range b.pending {
		if p.req.SessionKey == key {
			return true
		}
	}
	for _, p := range b.recovered {
		if p.SessionKey == key {
			return true
		}
	}
	return false
}

func (b *permissionBroker) hasHookPending(key string) bool {
	b.mu.Lock()
	defer b.mu.Unlock()
	for _, p := range b.pending {
		if p.req.SessionKey == key {
			return true
		}
	}
	return false
}

func (b *permissionBroker) recoveredFor(key string) *PermissionRequest {
	b.mu.Lock()
	defer b.mu.Unlock()
	for _, p := range b.recovered {
		if p.SessionKey == key {
			cp := *p
			return &cp
		}
	}
	return nil
}

func (b *permissionBroker) addRecovered(req PermissionRequest) {
	b.mu.Lock()
	b.recovered[req.ID] = &req
	b.mu.Unlock()
	b.r.each(func(l Listener) { l.PermissionPending(req) })
}

func (b *permissionBroker) dropRecovered(id, why string) {
	b.mu.Lock()
	_, had := b.recovered[id]
	delete(b.recovered, id)
	b.mu.Unlock()
	if had {
		b.r.each(func(l Listener) { l.PermissionResolved(id, why) })
	}
}

// hasSubscribers reports whether any client is watching this session.
func (b *permissionBroker) hasSubscribers(key string) bool {
	b.r.mu.RLock()
	defer b.r.mu.RUnlock()
	return b.r.subs[key] > 0 || b.r.paneSubs[key] > 0
}

// holdFor decides how long the hook waits for a phone: the normal timeout
// while a phone is watching; the longer detached timeout when nobody is
// watching, a device has opened the session (so a push reaches it) and no
// terminal is attached to answer instead; zero when someone at the keyboard
// is the better answerer.
func (b *permissionBroker) holdFor(ctx context.Context, s Session, timeout time.Duration) (time.Duration, string) {
	if b.hasSubscribers(s.Key) {
		return timeout, "phone watching"
	}
	b.mu.Lock()
	openedBy, attached, detached := b.openedBy, b.attached, b.detachedTimeout
	b.mu.Unlock()
	opened := s.Spawned || (openedBy != nil && openedBy(s.Key))
	if !opened {
		return 0, "never opened from a phone"
	}
	if attached != nil && s.TmuxSession != "" && attached(ctx, s.TmuxSession) {
		return 0, "terminal attached"
	}
	return detached, "phone is the only way to answer"
}

// Ask publishes a request and waits for an answer. It returns "" when nobody
// answered in time (caller then emits no decision).
func (b *permissionBroker) Ask(ctx context.Context, sessionKey, tool string, input map[string]any, cwd string, timeout time.Duration) string {
	s, _ := b.r.Get(sessionKey)
	hold, why := b.holdFor(ctx, s, timeout)
	b.r.log.Info("permission request", "session", sessionKey, "tool", tool, "hold", hold, "reason", why)
	if hold <= 0 {
		// Don't stall the terminal. Still flag the status; the dialog the CLI
		// draws is recovered from the screen on the next scan.
		b.r.SetStatus(sessionKey, transcript.StatusWaitingPermission)
		return ""
	}
	var rnd [8]byte
	_, _ = rand.Read(rnd[:])
	req := PermissionRequest{ID: hex.EncodeToString(rnd[:]), SessionKey: sessionKey, ToolName: tool, ToolInput: input, Cwd: cwd, CreatedAt: time.Now(), ExpiresAt: time.Now().Add(hold)}
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
	case <-time.After(hold):
		b.r.each(func(l Listener) { l.PermissionResolved(req.ID, "timeout") })
		return ""
	case <-ctx.Done():
		b.r.each(func(l Listener) { l.PermissionResolved(req.ID, "cancelled") })
		return ""
	}
}

// Answer resolves a hook-held request.
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

// IsRecovered reports whether id names a dialog read off the screen.
func (b *permissionBroker) IsRecovered(id string) bool {
	b.mu.Lock()
	defer b.mu.Unlock()
	_, ok := b.recovered[id]
	return ok
}

// optionFor maps allow/deny onto a recovered dialog's options: the first
// "Yes" for allow; "No" for deny, or -1 when the dialog has no plain No (the
// plan dialog), which the caller answers with Esc.
func optionFor(opts []string, behavior string) (int, error) {
	for i, o := range opts {
		if behavior == "allow" && strings.HasPrefix(o, "Yes") {
			return i, nil
		}
		if behavior == "deny" && o == "No" {
			return i, nil
		}
	}
	if behavior == "deny" {
		return -1, nil
	}
	return 0, fmt.Errorf("dialog has no %s option", behavior)
}

// AnswerRecovered presses the keys for one option of a dialog on screen:
// Down to the option, then Enter; option -1 presses Esc. It checks the
// dialog is still the one the phone saw before touching the keyboard.
func (b *permissionBroker) AnswerRecovered(ctx context.Context, id string, option int) error {
	b.mu.Lock()
	req, ok := b.recovered[id]
	if ok {
		cp := *req
		req = &cp
	}
	b.mu.Unlock()
	if !ok {
		return errors.New("that prompt is no longer on screen")
	}
	if option < -1 || option >= len(req.Options) {
		return errors.New("option out of range")
	}
	s, ok := b.r.Get(req.SessionKey)
	if !ok || !s.Controllable {
		return errors.New("session is not controllable")
	}
	b.r.mu.Lock()
	if b.r.answering[s.Key] {
		b.r.mu.Unlock()
		return errors.New("session is busy answering a dialog")
	}
	b.r.answering[s.Key] = true
	b.r.mu.Unlock()
	defer func() {
		b.r.mu.Lock()
		delete(b.r.answering, s.Key)
		b.r.mu.Unlock()
	}()
	scr, err := b.r.tm.Capture(ctx, s.PaneID, 0)
	if err != nil {
		return err
	}
	d, shown := parsePermissionDialog(scr.Lines)
	if !shown || "screen:"+s.Key+":"+d.hash() != id {
		b.dropRecovered(id, "gone")
		return errors.New("the prompt on screen has changed; look again")
	}
	var keys []string
	if option < 0 {
		keys = []string{"Escape"}
	} else {
		// The cursor starts on option 1.
		for i := 0; i < option; i++ {
			keys = append(keys, "Down")
		}
		keys = append(keys, "Enter")
	}
	b.r.log.Info("permission answered on screen", "session", s.Key, "option", option, "tool", req.ToolName)
	if err := b.r.tm.SendKeys(ctx, s.PaneID, keys); err != nil {
		return err
	}
	why := "deny"
	if option >= 0 && strings.HasPrefix(req.Options[option], "Yes") {
		why = "allow"
	}
	b.dropRecovered(id, why)
	b.r.gate.Reset(s.Key)
	b.r.SetStatus(s.Key, transcript.StatusBusy)
	return nil
}

// AnswerAny resolves a request by behavior whichever kind it is.
func (b *permissionBroker) AnswerAny(ctx context.Context, id, behavior string) error {
	if !b.IsRecovered(id) {
		return b.Answer(id, behavior)
	}
	b.mu.Lock()
	req := b.recovered[id]
	var opts []string
	if req != nil {
		opts = req.Options
	}
	b.mu.Unlock()
	if behavior != "allow" && behavior != "deny" {
		return errors.New("behavior must be allow or deny")
	}
	i, err := optionFor(opts, behavior)
	if err != nil {
		return err
	}
	return b.AnswerRecovered(ctx, id, i)
}
