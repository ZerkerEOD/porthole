package core

import (
	"log/slog"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/ZerkerEOD/porthole/daemon/internal/config"
	"github.com/ZerkerEOD/porthole/daemon/internal/tmux"
	"github.com/ZerkerEOD/porthole/daemon/internal/transcript"
)

const fixtureDir = "../provider/claude/testdata/agents"
const fixtureID = "99999999-aaaa-bbbb-cccc-000000000001"
const fixtureAgentID = "a0123456789abcdef"

// copyAgentFixture copies the parent and subagent fixture into a temp dir,
// marking the subagent unfinished, and returns the parent and agent paths.
func copyAgentFixture(t *testing.T) (parent, agent string) {
	t.Helper()
	dir := t.TempDir()
	sub := filepath.Join(dir, fixtureID, "subagents")
	if err := os.MkdirAll(sub, 0o700); err != nil {
		t.Fatal(err)
	}
	cp := func(from, to string, edit func(string) string) {
		b, err := os.ReadFile(from)
		if err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(to, []byte(edit(string(b))), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	same := func(s string) string { return s }
	parent = filepath.Join(dir, fixtureID+".jsonl")
	agent = filepath.Join(sub, "agent-"+fixtureAgentID+".jsonl")
	cp(filepath.Join(fixtureDir, fixtureID+".jsonl"), parent, same)
	cp(filepath.Join(fixtureDir, fixtureID, "subagents", "agent-"+fixtureAgentID+".jsonl"), agent, same)
	cp(filepath.Join(fixtureDir, fixtureID, "subagents", "agent-"+fixtureAgentID+".meta.json"), strings.TrimSuffix(agent, ".jsonl")+".meta.json",
		func(s string) string { return strings.Replace(s, `"finished":true`, `"finished":false`, 1) })
	return parent, agent
}

type eventRec struct {
	recorder
	events  map[string]int
	upserts int
}

func (e *eventRec) SessionUpserted(Session) { e.upserts++ }
func (e *eventRec) Events(key string, evs []transcript.Event) {
	e.events[key] += len(evs)
}
func (e *eventRec) Pane(string, *tmux.Screen) {}

func TestAgentsOnSessionAndFollow(t *testing.T) {
	parent, agent := copyAgentFixture(t)
	r := New(config.Default(), slog.New(slog.NewTextHandler(os.Stderr, nil)))
	rec := &eventRec{events: map[string]int{}}
	r.AddListener(rec)

	key := "claude:" + fixtureID
	s := Session{Key: key, ID: fixtureID, Provider: "claude", TranscriptPath: parent, Running: true, Status: transcript.StatusBusy}
	r.finishLive(&s, parent)
	got, _ := r.Get(key)
	if len(got.Agents) != 1 || got.Agents[0].ID != fixtureAgentID {
		t.Fatalf("agents %+v", got.Agents)
	}
	if !got.Agents[0].Running {
		t.Fatal("unfinished agent of a running session should be running")
	}
	if got.Usage == nil || got.Usage.InputTokens != 5 || got.Usage.CacheReadTokens != 130 {
		t.Fatalf("usage %+v", got.Usage)
	}
	// An unchanged rescan is not news.
	n := rec.upserts
	s2 := Session{Key: key, ID: fixtureID, Provider: "claude", TranscriptPath: parent, Running: true, Status: transcript.StatusBusy}
	r.finishLive(&s2, parent)
	if rec.upserts != n {
		t.Fatal("unchanged session upserted again")
	}

	if _, _, err := r.SubscribeAgent(key, "nope", 0, 0); err == nil {
		t.Fatal("unknown agent accepted")
	}
	if _, _, err := r.SubscribeAgent(key, "../../etc", 0, 0); err == nil {
		t.Fatal("path-like agent id accepted")
	}
	evs, _, err := r.SubscribeAgent(key, fixtureAgentID, 0, 0)
	if err != nil || len(evs) == 0 {
		t.Fatalf("subscribe: %d events, %v", len(evs), err)
	}
	f, err := os.OpenFile(agent, os.O_APPEND|os.O_WRONLY, 0)
	if err != nil {
		t.Fatal(err)
	}
	_, _ = f.WriteString(`{"type":"assistant","isSidechain":true,"uuid":"s7","message":{"id":"msg_A3","content":[{"type":"text","text":"More."}]},"timestamp":"2026-11-20T10:00:09.000Z"}` + "\n")
	f.Close()
	r.pumpAll()
	ak := AgentKey(key, fixtureAgentID)
	if rec.events[ak] != 1 {
		t.Fatalf("live agent events %v", rec.events)
	}
	if rec.events[key] != 0 {
		t.Fatal("agent events delivered under the session key")
	}

	r.remove(key)
	r.mu.RLock()
	_, still := r.followers[ak]
	r.mu.RUnlock()
	if still {
		t.Fatal("agent follower survived its session")
	}
}
