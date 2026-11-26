package claude

import (
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/ZerkerEOD/porthole/daemon/internal/transcript"
)

const fixtureParent = "testdata/agents/99999999-aaaa-bbbb-cccc-000000000001.jsonl"
const fixtureAgent = "testdata/agents/99999999-aaaa-bbbb-cccc-000000000001/subagents/agent-a0123456789abcdef.jsonl"

func TestListAgents(t *testing.T) {
	agents, err := ListAgents(fixtureParent)
	if err != nil {
		t.Fatal(err)
	}
	if len(agents) != 1 {
		t.Fatalf("want 1 agent, got %d", len(agents))
	}
	a := agents[0]
	if a.ID != "a0123456789abcdef" || a.Type != "Explore" || a.Description != "Count Go files" || a.ToolUseID != "toolu_P1" {
		t.Fatalf("meta not applied: %+v", a)
	}
	if !a.Background || !a.Finished || a.Running || !a.ReportsFinish {
		t.Fatalf("flags: background=%v finished=%v running=%v", a.Background, a.Finished, a.Running)
	}
	if a.Turns != 2 || a.ToolUses != 1 {
		t.Fatalf("turns=%d tool_uses=%d", a.Turns, a.ToolUses)
	}
	// msg_A1 appears twice; its larger output count (20) wins over the first (5).
	want := transcript.Usage{InputTokens: 13, OutputTokens: 27, CacheCreationTokens: 100, CacheReadTokens: 500}
	if a.Usage != want {
		t.Fatalf("usage %+v, want %+v", a.Usage, want)
	}
	if a.LastText != "There are 12 Go files." {
		t.Fatalf("last text %q", a.LastText)
	}
	if a.Model != "claude-test-1" || !a.StartedAt.Equal(time.Date(2026, 11, 20, 10, 0, 0, 0, time.UTC)) {
		t.Fatalf("model %q started %v", a.Model, a.StartedAt)
	}
	if none, err := ListAgents("testdata/session.jsonl"); err != nil || none != nil {
		t.Fatalf("session without subagents: %v %v", none, err)
	}
}

func TestListAgentsNoMetaAndGrowth(t *testing.T) {
	dir := t.TempDir()
	parent := filepath.Join(dir, "sess.jsonl")
	if err := os.WriteFile(parent, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	sub := AgentsDir(parent)
	if err := os.MkdirAll(sub, 0o700); err != nil {
		t.Fatal(err)
	}
	src, err := os.ReadFile(fixtureAgent)
	if err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(sub, "agent-abc123.jsonl")
	// Leave the last record unterminated, as while it is being written.
	if err := os.WriteFile(path, src[:len(src)-1], 0o600); err != nil {
		t.Fatal(err)
	}
	agents, err := ListAgents(parent)
	if err != nil || len(agents) != 1 {
		t.Fatalf("got %v %v", agents, err)
	}
	a := agents[0]
	if a.ID != "abc123" || a.Type != "agent" || a.Description != "List the Go files in the repo and report their count." {
		t.Fatalf("fallback: %+v", a)
	}
	if a.Finished || !a.Running {
		t.Fatalf("fresh unfinished file should be running: %+v", a)
	}
	if a.Turns != 1 || a.LastText != "I will look." {
		t.Fatalf("partial line counted: turns=%d last=%q", a.Turns, a.LastText)
	}

	// Completing the line and appending another is picked up incrementally.
	f, err := os.OpenFile(path, os.O_APPEND|os.O_WRONLY, 0)
	if err != nil {
		t.Fatal(err)
	}
	_, _ = f.WriteString("\n" + `{"type":"assistant","isSidechain":true,"message":{"id":"msg_A3","content":[{"type":"text","text":"Bye."}],"usage":{"input_tokens":1,"output_tokens":1}},"timestamp":"2026-11-20T10:00:09.000Z"}` + "\n")
	f.Close()
	agents, _ = ListAgents(parent)
	if a = agents[0]; a.Turns != 3 || a.LastText != "Bye." || a.Usage.InputTokens != 14 {
		t.Fatalf("after growth: %+v", a)
	}

	// A quiet file is no longer running.
	old := time.Now().Add(-time.Minute)
	if err := os.Chtimes(path, old, old); err != nil {
		t.Fatal(err)
	}
	agents, _ = ListAgents(parent)
	if agents[0].Running {
		t.Fatal("quiet unfinished agent reported running")
	}
}

func TestTranscriptUsage(t *testing.T) {
	u, err := TranscriptUsage(fixtureParent)
	if err != nil {
		t.Fatal(err)
	}
	want := transcript.Usage{InputTokens: 5, OutputTokens: 11, CacheCreationTokens: 50, CacheReadTokens: 130}
	if u != want {
		t.Fatalf("usage %+v, want %+v", u, want)
	}
}

func TestTaskNotice(t *testing.T) {
	evs := parseFixture(t, fixtureParent)
	var notices, users int
	var linked bool
	for _, e := range evs {
		switch e.Type {
		case transcript.TypeSystem:
			notices++
			if want := `Agent "Count Go files" finished · 64k tokens · 15 tool uses · 1m 32s`; e.Text != want {
				t.Fatalf("notice %q, want %q", e.Text, want)
			}
			if e.AgentID != "a0123456789abcdef" || e.Level != "info" || e.Meta["tool_use_id"] != "toolu_P1" {
				t.Fatalf("notice fields: %+v", e)
			}
		case transcript.TypeUser:
			users++
		case transcript.TypeToolResult:
			linked = e.Meta["agent_id"] == "a0123456789abcdef"
		case transcript.TypeToolUse:
			if e.Tool == nil || e.Tool.Name != "Agent" {
				t.Fatalf("agent tool use: %+v", e)
			}
		}
	}
	if notices != 1 {
		t.Fatalf("want one notice, got %d", notices)
	}
	if users != 1 {
		t.Fatalf("the delivered task-notification should be hidden, users=%d", users)
	}
	if !linked {
		t.Fatal("Agent tool result not linked to its agent")
	}
}

func TestHumanUnits(t *testing.T) {
	for n, want := range map[int64]string{850: "850", 63818: "64k", 999_499: "999k", 999_500: "1M", 1_250_000: "1.2M"} {
		if got := humanTokens(n); got != want {
			t.Errorf("humanTokens(%d)=%q want %q", n, got, want)
		}
	}
	for ms, want := range map[int64]string{4_200: "4s", 92_014: "1m 32s", 3_725_000: "1h 2m"} {
		if got := humanDuration(ms); got != want {
			t.Errorf("humanDuration(%d)=%q want %q", ms, got, want)
		}
	}
}
