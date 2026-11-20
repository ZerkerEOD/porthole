package codex

import (
	"bufio"
	"os"
	"testing"

	"github.com/ZerkerEOD/porthole/daemon/internal/transcript"
)

func TestParseRollout(t *testing.T) {
	f, err := os.Open("testdata/rollout.jsonl")
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	p := NewParser()
	var evs []transcript.Event
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		e, err := p.ParseLine(sc.Bytes())
		if err != nil {
			t.Fatal(err)
		}
		evs = append(evs, e...)
	}
	var types []string
	for _, e := range evs {
		types = append(types, e.Type)
	}
	want := []string{
		transcript.TypeMeta,        // session_meta
		transcript.TypeModelSwitch, // first model seen
		transcript.TypeMeta,        // turn_context
		transcript.TypeUser,
		transcript.TypeStatus, // busy
		transcript.TypeThinking,
		transcript.TypeToolUse,
		transcript.TypeToolResult,
		transcript.TypeText, // from response_item only, not agent_message
		transcript.TypeUsage,
		transcript.TypeStatus, // idle
	}
	if len(types) != len(want) {
		t.Fatalf("got %v want %v", types, want)
	}
	for i := range want {
		if types[i] != want[i] {
			t.Errorf("%d: got %s want %s", i, types[i], want[i])
		}
	}
	if evs[6].Tool.Name != "shell" || string(evs[6].Tool.Input) != `{"command":["ls"]}` {
		t.Errorf("tool: %+v %s", evs[6].Tool, evs[6].Tool.Input)
	}
	if evs[7].Text != "a.txt\nb.txt\n" || evs[7].Meta["tool"] != "shell" {
		t.Errorf("result: %q %v", evs[7].Text, evs[7].Meta)
	}
	u := evs[9].Usage
	if u == nil || u.RateLimits == nil || u.RateLimits.Primary.UsedPercent != 1.0 || u.RateLimits.Plan != "plus" || u.InputTokens != 100 {
		t.Errorf("usage: %+v", u)
	}
	if evs[8].Model != "gpt-5.5" {
		t.Errorf("model not carried: %q", evs[8].Model)
	}
}

func TestSessionIDFromFilename(t *testing.T) {
	got := SessionIDFromFilename("rollout-2026-05-08T11-53-56-019e0738-fdee-7f73-8499-2f32eb007778.jsonl")
	if got != "019e0738-fdee-7f73-8499-2f32eb007778" {
		t.Fatalf("got %q", got)
	}
}
