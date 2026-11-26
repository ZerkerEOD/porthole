package core

import (
	"log/slog"
	"os"
	"testing"
	"time"

	"github.com/ZerkerEOD/porthole/daemon/internal/config"
	"github.com/ZerkerEOD/porthole/daemon/internal/tmux"
	"github.com/ZerkerEOD/porthole/daemon/internal/transcript"
)

// recorder logs listener calls in order.
type recorder struct{ calls []string }

func (r *recorder) SessionUpserted(s Session) { r.calls = append(r.calls, "upsert:"+s.Key) }
func (r *recorder) SessionReplaced(oldKey, newKey string) {
	r.calls = append(r.calls, "replaced:"+oldKey+">"+newKey)
}
func (r *recorder) SessionRemoved(key string)           { r.calls = append(r.calls, "removed:"+key) }
func (r *recorder) Events(string, []transcript.Event)   {}
func (r *recorder) Pane(string, *tmux.Screen)           {}
func (r *recorder) PermissionPending(PermissionRequest) {}
func (r *recorder) PermissionResolved(string, string)   {}
func (r *recorder) AccountsUpdated(AccountsSnapshot)    {}
func (r *recorder) RunUpdated(Run)                      {}

func TestSpawnPlaceholderReplacedBeforeRemoved(t *testing.T) {
	r := New(config.Default(), slog.New(slog.NewTextHandler(os.Stderr, nil)))
	rec := &recorder{}
	r.AddListener(rec)
	ph := Session{Key: "claude:pending:%7", ID: "pending", Provider: "claude", PaneID: "%7", Pending: true, Running: true, StartedAt: time.Now()}
	r.spawned["%7"] = spawnInfo{Provider: "claude", Dir: "/x", At: time.Now()}
	r.upsert(ph)
	rec.calls = nil

	s := Session{Key: "claude:abc", ID: "abc", Provider: "claude", PaneID: "%7", Running: true, Controllable: true, Status: transcript.StatusBusy}
	r.finishLive(&s, "")
	want := []string{"upsert:claude:abc", "replaced:claude:pending:%7>claude:abc", "removed:claude:pending:%7"}
	if len(rec.calls) != len(want) {
		t.Fatalf("calls %v, want %v", rec.calls, want)
	}
	for i := range want {
		if rec.calls[i] != want[i] {
			t.Fatalf("calls %v, want %v", rec.calls, want)
		}
	}
	if got, ok := r.Get("claude:abc"); !ok || !got.Spawned {
		t.Fatalf("real session %+v %v", got, ok)
	}
	if _, ok := r.Get(ph.Key); ok {
		t.Fatal("placeholder still present")
	}
	if _, ok := r.spawned["%7"]; ok {
		t.Fatal("spawn bookkeeping not cleared")
	}
}
