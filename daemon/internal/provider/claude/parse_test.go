package claude

import (
	"bufio"
	"os"
	"testing"

	"github.com/ZerkerEOD/porthole/daemon/internal/transcript"
)

func parseFixture(t *testing.T, path string) []transcript.Event {
	t.Helper()
	f, err := os.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	p := NewParser()
	var out []transcript.Event
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 1<<20), 1<<20)
	for sc.Scan() {
		evs, err := p.ParseLine(sc.Bytes())
		if err != nil {
			t.Fatalf("parse: %v", err)
		}
		out = append(out, evs...)
	}
	return out
}

func TestParseSession(t *testing.T) {
	evs := parseFixture(t, "testdata/session.jsonl")
	var types []string
	for _, e := range evs {
		types = append(types, e.Type)
	}
	want := []string{
		transcript.TypeMeta,     // permission-mode
		transcript.TypeUser,     // Fix the login bug
		transcript.TypeThinking, // msg_1 block 1
		transcript.TypeUsage,    // msg_1 usage (once)
		transcript.TypeText,     // msg_1 text
		transcript.TypeToolUse,  // msg_1 tool_use
		transcript.TypeToolResult,
		transcript.TypeMeta,    // ai-title
		transcript.TypeText,    // Done.
		transcript.TypeUsage,   // msg_2 usage
		transcript.TypeCompact, // compact boundary
		transcript.TypeUsage,   // cost-state
	}
	if len(types) != len(want) {
		t.Fatalf("got %d events %v, want %d %v", len(types), types, len(want), want)
	}
	for i := range want {
		if types[i] != want[i] {
			t.Errorf("event %d: got %s want %s (all: %v)", i, types[i], want[i], types)
		}
	}
	if evs[1].Text != "Fix the login bug" {
		t.Errorf("user text: %q", evs[1].Text)
	}
	if evs[5].Tool == nil || evs[5].Tool.Name != "Read" || evs[5].Tool.ID != "toolu_1" {
		t.Errorf("tool use: %+v", evs[5].Tool)
	}
	if evs[6].Result == nil || evs[6].Result.ToolUseID != "toolu_1" || evs[6].Text != "package main\n" {
		t.Errorf("tool result: %+v %q", evs[6].Result, evs[6].Text)
	}
	if evs[7].Meta["title"] != "fix-login-bug" {
		t.Errorf("title: %v", evs[7].Meta)
	}
	if evs[3].Usage == nil || evs[3].Usage.CacheReadTokens != 100 {
		t.Errorf("usage: %+v", evs[3].Usage)
	}
	if evs[11].Usage == nil || evs[11].Usage.TotalCostUSD != 0.12 {
		t.Errorf("cost: %+v", evs[11].Usage)
	}
}

func TestClipLargeText(t *testing.T) {
	big := make([]byte, transcript.MaxInlineText+100)
	for i := range big {
		big[i] = 'a'
	}
	s, trunc := transcript.Clip(string(big))
	if !trunc || len(s) != transcript.MaxInlineText {
		t.Fatalf("clip: trunc=%v len=%d", trunc, len(s))
	}
}

func TestUnknownTypeIgnored(t *testing.T) {
	p := NewParser()
	evs, err := p.ParseLine([]byte(`{"type":"something-new","foo":1}`))
	if err != nil || len(evs) != 0 {
		t.Fatalf("got %v %v", evs, err)
	}
	if _, err := p.ParseLine([]byte(`{not json`)); err == nil {
		t.Fatal("expected error for bad json")
	}
}
