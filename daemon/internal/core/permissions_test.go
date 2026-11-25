package core

import (
	"context"
	"log/slog"
	"os"
	"testing"
	"time"

	"github.com/ZerkerEOD/porthole/daemon/internal/config"
	"github.com/ZerkerEOD/porthole/daemon/internal/tmux"
	"github.com/ZerkerEOD/porthole/daemon/internal/transcript"
)

func TestHoldForPolicy(t *testing.T) {
	r := New(config.Default(), slog.New(slog.NewTextHandler(os.Stderr, nil)))
	opened := map[string]bool{}
	attached := true
	r.perm.SetPolicy(func(k string) bool { return opened[k] }, func(context.Context, string) bool { return attached }, 5*time.Minute)
	s := Session{Key: "claude:s", ID: "s", Provider: "claude", Running: true, Controllable: true, PaneID: "%1", TmuxSession: "ph-claude-1", Status: transcript.StatusBusy}
	r.upsert(s)
	ctx := context.Background()

	if d, why := r.perm.holdFor(ctx, s, time.Minute); d != 0 {
		t.Fatalf("never opened: hold %v (%s)", d, why)
	}
	opened[s.Key] = true
	if d, why := r.perm.holdFor(ctx, s, time.Minute); d != 0 {
		t.Fatalf("terminal attached: hold %v (%s)", d, why)
	}
	attached = false
	if d, why := r.perm.holdFor(ctx, s, time.Minute); d != 5*time.Minute {
		t.Fatalf("detached and opened: hold %v (%s)", d, why)
	}
	delete(opened, s.Key)
	s.Spawned = true
	if d, _ := r.perm.holdFor(ctx, s, time.Minute); d != 5*time.Minute {
		t.Fatalf("spawned from the app counts as opened: %v", d)
	}
	// A phone watching the session gets the normal timeout whatever else.
	attached = true
	r.mu.Lock()
	r.subs[s.Key] = 1
	r.mu.Unlock()
	if d, why := r.perm.holdFor(ctx, s, time.Minute); d != time.Minute {
		t.Fatalf("subscribed: hold %v (%s)", d, why)
	}
}

func TestOptionFor(t *testing.T) {
	bash := []string{"Yes", "Yes, and always allow access to /x from this project", "Yes, and switch to auto mode", "No"}
	if i, err := optionFor(bash, "allow"); err != nil || i != 0 {
		t.Fatalf("allow: %d %v", i, err)
	}
	if i, err := optionFor(bash, "deny"); err != nil || i != 3 {
		t.Fatalf("deny: %d %v", i, err)
	}
	plan := []string{"Yes, and use auto mode", "Yes, manually approve edits", "Tell Claude what to change"}
	if i, err := optionFor(plan, "deny"); err != nil || i != -1 {
		t.Fatalf("plan deny should press Esc: %d %v", i, err)
	}
	if _, err := optionFor([]string{"Tell Claude what to change"}, "allow"); err == nil {
		t.Fatal("no Yes option must fail")
	}
}

func TestRecoveredRequestLifecycle(t *testing.T) {
	r := New(config.Default(), slog.New(slog.NewTextHandler(os.Stderr, nil)))
	var pending, resolved []string
	r.AddListener(listenerFuncs{
		pending:  func(p PermissionRequest) { pending = append(pending, p.ID) },
		resolved: func(id, why string) { resolved = append(resolved, id+"|"+why) },
	})
	r.upsert(Session{Key: "claude:s", ID: "s", Provider: "claude", Running: true, Controllable: true, PaneID: "%1", Status: transcript.StatusIdle})
	scr := screenOf(readLines(t, "perm_bash.txt"))
	r.recoverPermission("claude:s", scr)
	if len(pending) != 1 || !r.perm.HasPending("claude:s") {
		t.Fatalf("pending %v", pending)
	}
	if s, _ := r.Get("claude:s"); s.Status != transcript.StatusWaitingPermission {
		t.Fatalf("status %s", s.Status)
	}
	// The same screen again is not a new request.
	r.recoverPermission("claude:s", scr)
	if len(pending) != 1 {
		t.Fatalf("duplicate publish: %v", pending)
	}
	// A different dialog replaces it; an idle screen clears it.
	r.recoverPermission("claude:s", screenOf(readLines(t, "perm_write.txt")))
	if len(pending) != 2 || len(resolved) != 1 || resolved[0] != pending[0]+"|replaced" {
		t.Fatalf("replace: pending %v resolved %v", pending, resolved)
	}
	r.recoverPermission("claude:s", screenOf(readLines(t, "mode_manual.ansi")))
	if r.perm.HasPending("claude:s") || len(resolved) != 2 || resolved[1] != pending[1]+"|gone" {
		t.Fatalf("clear: resolved %v", resolved)
	}
}

// listenerFuncs adapts closures to Listener for tests.
type listenerFuncs struct {
	pending  func(PermissionRequest)
	resolved func(id, why string)
}

func (l listenerFuncs) SessionUpserted(Session)               {}
func (l listenerFuncs) SessionReplaced(string, string)        {}
func (l listenerFuncs) SessionRemoved(string)                 {}
func (l listenerFuncs) Events(string, []transcript.Event)     {}
func (l listenerFuncs) Pane(string, *tmux.Screen)             {}
func (l listenerFuncs) PermissionPending(p PermissionRequest) { l.pending(p) }
func (l listenerFuncs) PermissionResolved(id, why string)     { l.resolved(id, why) }
func (l listenerFuncs) AccountsUpdated(AccountsSnapshot)      {}
