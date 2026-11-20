package transcript

import (
	"os"
	"path/filepath"
	"testing"
)

func TestTailerPartialLines(t *testing.T) {
	p := filepath.Join(t.TempDir(), "t.jsonl")
	f, _ := os.Create(p)
	f.WriteString("{\"a\":1}\n{\"b\":")
	f.Sync()
	tl := &Tailer{Path: p}
	var got []string
	off, err := tl.ReadAvailable(func(l []byte) error { got = append(got, string(l)); return nil })
	if err != nil || len(got) != 1 || got[0] != `{"a":1}` {
		t.Fatalf("first read: %v %v", got, err)
	}
	f.WriteString("2}\n")
	f.Sync()
	off2, _ := tl.ReadAvailable(func(l []byte) error { got = append(got, string(l)); return nil })
	if len(got) != 2 || got[1] != `{"b":2}` || off2 <= off {
		t.Fatalf("second read: %v off=%d off2=%d", got, off, off2)
	}
	// Truncation restarts.
	f.Close()
	os.WriteFile(p, []byte("{\"c\":3}\n"), 0o600)
	tl.ReadAvailable(func(l []byte) error { got = append(got, string(l)); return nil })
	if got[len(got)-1] != `{"c":3}` {
		t.Fatalf("after truncate: %v", got)
	}
}
