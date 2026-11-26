package claude

import (
	"os"
	"path/filepath"
	"testing"
)

func TestPendingTasks(t *testing.T) {
	path := filepath.Join(t.TempDir(), "s.jsonl")
	write := func(lines ...string) {
		f, err := os.OpenFile(path, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o600)
		if err != nil {
			t.Fatal(err)
		}
		for _, l := range lines {
			if _, err := f.WriteString(l + "\n"); err != nil {
				t.Fatal(err)
			}
		}
		f.Close()
	}
	ids := func() []string {
		t.Helper()
		ps, err := PendingTasks(path)
		if err != nil {
			t.Fatal(err)
		}
		var out []string
		for _, p := range ps {
			out = append(out, p.ID)
		}
		return out
	}
	write(
		`{"type":"user","timestamp":"2026-11-26T10:00:00Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"launched"}]},"toolUseResult":{"isAsync":true,"status":"async_launched","agentId":"a1"}}`,
		`{"type":"user","timestamp":"2026-11-26T10:00:01Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t2","content":"bg"}]},"toolUseResult":{"stdout":"","backgroundTaskId":"b2"}}`,
		`{"type":"user","timestamp":"2026-11-26T10:00:02Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t3","content":"done"}]},"toolUseResult":{"agentId":"a3","status":"completed"}}`,
	)
	if got := ids(); len(got) != 2 || got[0] != "a1" || got[1] != "b2" {
		t.Fatalf("pending %v", got)
	}
	write(`{"type":"queue-operation","operation":"enqueue","timestamp":"2026-11-26T10:01:00Z","content":"<task-notification>\n<task-id>b2</task-id>\n<status>completed</status>\n</task-notification>"}`)
	if got := ids(); len(got) != 1 || got[0] != "a1" {
		t.Fatalf("after bash notice %v", got)
	}
	write(`{"type":"user","timestamp":"2026-11-26T10:02:00Z","message":{"role":"user","content":"<task-notification><task-id>a1</task-id><status>completed</status></task-notification>"}}`)
	if got := ids(); len(got) != 0 {
		t.Fatalf("after agent notice %v", got)
	}
}
