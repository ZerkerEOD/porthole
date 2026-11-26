package claude

import (
	"encoding/json"
	"strings"
	"testing"

	"github.com/ZerkerEOD/porthole/daemon/internal/transcript"
)

func userLine(t *testing.T, uuid, parent, content string) []byte {
	t.Helper()
	b, err := json.Marshal(map[string]any{
		"type": "user", "uuid": uuid, "parentUuid": parent, "timestamp": "2026-11-26T10:00:00Z",
		"message": map[string]any{"role": "user", "content": content},
	})
	if err != nil {
		t.Fatal(err)
	}
	return b
}

func parseAll(t *testing.T, p *Parser, lines ...[]byte) []transcript.Event {
	t.Helper()
	var out []transcript.Event
	for _, l := range lines {
		evs, err := p.ParseLine(l)
		if err != nil {
			t.Fatal(err)
		}
		out = append(out, evs...)
	}
	return out
}

func TestBangCommandOneEvent(t *testing.T) {
	p := NewParser()
	evs := parseAll(t, p,
		userLine(t, "u1", "", "<bash-input>  ls -la\n echo 'a<b'  </bash-input>"),
		userLine(t, "u2", "u1", "<bash-stdout>total 0\nfile\n</bash-stdout><bash-stderr>warn: x\n</bash-stderr>"),
		userLine(t, "u3", "u2", "next prompt"),
	)
	if len(evs) != 2 {
		t.Fatalf("events %+v", evs)
	}
	c := evs[0]
	if c.Type != transcript.TypeCommand || c.ID != "u1" || c.Text != "ls -la\n echo 'a<b'" {
		t.Fatalf("command %+v", c)
	}
	if c.Meta["source"] != "bang" || c.Meta["stdout"] != "total 0\nfile" || c.Meta["stderr"] != "warn: x" {
		t.Fatalf("meta %+v", c.Meta)
	}
	if evs[1].Type != transcript.TypeUser || evs[1].Text != "next prompt" {
		t.Fatalf("prompt %+v", evs[1])
	}
}

func TestBangCommandWithoutOutputIsFlushed(t *testing.T) {
	p := NewParser()
	evs := parseAll(t, p,
		userLine(t, "u1", "", "<bash-input>sleep 100</bash-input>"),
	)
	if len(evs) != 0 {
		t.Fatalf("held command emitted early: %+v", evs)
	}
	evs = parseAll(t, p, userLine(t, "u2", "u1", "[Request interrupted by user]"))
	if len(evs) != 1 || evs[0].Type != transcript.TypeCommand || evs[0].Text != "sleep 100" || evs[0].Meta["stdout"] != "" {
		t.Fatalf("flush %+v", evs)
	}
}

func TestBangCommandOutputCapped(t *testing.T) {
	p := NewParser()
	big := strings.Repeat("x", 30*1024)
	evs := parseAll(t, p,
		userLine(t, "u1", "", "<bash-input>yes x</bash-input>"),
		userLine(t, "u2", "u1", "<bash-stdout>"+big+"</bash-stdout><bash-stderr></bash-stderr>"),
	)
	if len(evs) != 1 {
		t.Fatalf("events %d", len(evs))
	}
	out := evs[0].Meta["stdout"].(string)
	if !strings.HasSuffix(out, "\n[…]") || len(out) != 20*1024+len("\n[…]") {
		t.Fatalf("stdout len %d suffix %q", len(out), out[len(out)-8:])
	}
	if evs[0].Meta["stderr"] != "" {
		t.Fatalf("stderr %q", evs[0].Meta["stderr"])
	}
}

func TestSlashOutputIsCommand(t *testing.T) {
	p := NewParser()
	evs := parseAll(t, p,
		userLine(t, "u1", "", "<command-name>/model</command-name>"),
		userLine(t, "u2", "u1", "<local-command-stdout>Set model to opus</local-command-stdout>"),
	)
	if len(evs) != 1 {
		t.Fatalf("events %+v", evs)
	}
	if evs[0].Type != transcript.TypeCommand || evs[0].Text != "" || evs[0].Meta["source"] != "slash" || evs[0].Meta["stdout"] != "Set model to opus" {
		t.Fatalf("slash %+v", evs[0])
	}
}
