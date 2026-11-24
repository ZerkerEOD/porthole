package server

import (
	"io"
	"log/slog"
	"testing"
	"time"

	"github.com/ZerkerEOD/porthole/daemon/internal/config"
	"github.com/ZerkerEOD/porthole/daemon/internal/core"
)

func TestNotifyTargetsOpenedOnly(t *testing.T) {
	dir := t.TempDir()
	st, err := OpenStore(dir)
	if err != nil {
		t.Fatal(err)
	}
	pair := func(name string) Device {
		code, _, err := st.NewPairingCode(name)
		if err != nil {
			t.Fatal(err)
		}
		d, _, err := st.Pair("1.2.3.4", code, name, "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff")
		if err != nil {
			t.Fatal(err)
		}
		if err := st.SetPushGrant(d.ID, "grant", time.Now().Add(time.Hour)); err != nil {
			t.Fatal(err)
		}
		return d
	}
	a, b := pair("a"), pair("b")
	log := slog.New(slog.NewTextHandler(io.Discard, nil))
	h := newHub(core.New(config.Default(), log), log)
	h.store = st

	ids := func(ds []Device) map[string]bool {
		m := map[string]bool{}
		for _, d := range ds {
			m[d.ID] = true
		}
		return m
	}
	if got := h.targets("done", "claude:x", false); len(got) != 0 {
		t.Fatalf("no device opened the session, got %v", ids(got))
	}
	st.MarkOpened(a.ID, "claude:x")
	if got := ids(h.targets("done", "claude:x", false)); !got[a.ID] || got[b.ID] {
		t.Fatalf("only the opener gets it, got %v", got)
	}
	// The 45 s backstop holds a repeat of the same kind.
	if got := h.targets("done", "claude:x", false); len(got) != 0 {
		t.Fatal("repeat within 45 s pushed")
	}
	// A session the daemon spawned goes to every device.
	if got := ids(h.targets("input", "claude:y", true)); !got[a.ID] || !got[b.ID] {
		t.Fatalf("spawned session should reach all, got %v", got)
	}
	// A replaced placeholder carries its opened entry to the real key.
	st.MarkOpened(b.ID, "claude:pending:%1")
	st.ReplaceOpened("claude:pending:%1", "claude:z")
	if !st.Opened(b.ID, "claude:z") || st.Opened(b.ID, "claude:pending:%1") {
		t.Fatal("opened entry not carried across the replace")
	}
	// Opened sets persist (after the coalesced save) and expire after a week.
	st.Flush()
	st2, err := OpenStore(dir)
	if err != nil {
		t.Fatal(err)
	}
	if !st2.Opened(a.ID, "claude:x") || !st2.Opened(b.ID, "claude:z") {
		t.Fatal("opened set lost on reload")
	}
	st2.mu.Lock()
	for i := range st2.devs {
		if st2.devs[i].ID == a.ID {
			st2.devs[i].Opened["claude:x"] = time.Now().Add(-openedTTL - time.Minute)
		}
	}
	st2.pruneOpened(time.Now())
	st2.mu.Unlock()
	if st2.Opened(a.ID, "claude:x") {
		t.Fatal("stale entry kept")
	}
}
