package claude

import (
	"encoding/base64"
	"encoding/json"
	"strings"
	"testing"

	"github.com/ZerkerEOD/porthole/daemon/internal/transcript"
)

// A 1x1 PNG.
const tinyPNG = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="

func imgUserLine(t *testing.T, content any, toolUseResult any) []byte {
	t.Helper()
	e := map[string]any{"type": "user", "uuid": "u1", "timestamp": "2026-11-26T10:00:00Z",
		"message": map[string]any{"role": "user", "content": content}}
	if toolUseResult != nil {
		e["toolUseResult"] = toolUseResult
	}
	b, err := json.Marshal(e)
	if err != nil {
		t.Fatal(err)
	}
	return b
}

func imageBlock(data string) map[string]any {
	return map[string]any{"type": "image", "source": map[string]any{"type": "base64", "media_type": "image/png", "data": data}}
}

func TestParseUserImages(t *testing.T) {
	big := base64.StdEncoding.EncodeToString(make([]byte, transcript.MaxImageBytes+1))
	line := imgUserLine(t, []any{
		map[string]any{"type": "text", "text": "look at this"},
		imageBlock(tinyPNG), imageBlock(big), imageBlock(tinyPNG), imageBlock(tinyPNG),
	}, nil)
	evs, err := NewParser().ParseLine(line)
	if err != nil || len(evs) != 1 {
		t.Fatalf("events %+v %v", evs, err)
	}
	ev := evs[0]
	if ev.Type != transcript.TypeUser || !strings.Contains(ev.Text, "_[image attached]_") {
		t.Fatalf("user event %+v", ev)
	}
	if len(ev.Images) != 3 {
		t.Fatalf("images %d", len(ev.Images))
	}
	if ev.Images[0].Data != tinyPNG || ev.Images[0].MediaType != "image/png" || ev.Images[0].Omitted || ev.Images[0].Bytes != 70 {
		t.Fatalf("small image %+v", ev.Images[0])
	}
	if !ev.Images[1].Omitted || ev.Images[1].Data != "" || ev.Images[1].Bytes != transcript.MaxImageBytes+1 {
		t.Fatalf("big image %+v", ev.Images[1])
	}
	b, _ := json.Marshal(ev.Images[1])
	if string(b) != `{"media_type":"image/png","omitted":true,"bytes":1572865}` {
		t.Fatalf("omitted json %s", b)
	}

	// An image-only prompt still has the text marker.
	evs, _ = NewParser().ParseLine(imgUserLine(t, []any{imageBlock(tinyPNG)}, nil))
	if len(evs) != 1 || evs[0].Text != "_[image attached]_" || len(evs[0].Images) != 1 {
		t.Fatalf("image only %+v", evs)
	}
}

func TestParseToolResultImages(t *testing.T) {
	line := imgUserLine(t, []any{map[string]any{"type": "tool_result", "tool_use_id": "t1", "content": []any{
		map[string]any{"type": "text", "text": "screenshot"}, imageBlock(tinyPNG),
	}}}, nil)
	evs, err := NewParser().ParseLine(line)
	if err != nil || len(evs) != 1 {
		t.Fatalf("events %+v %v", evs, err)
	}
	if evs[0].Type != transcript.TypeToolResult || len(evs[0].Images) != 1 || evs[0].Images[0].Data != tinyPNG {
		t.Fatalf("tool result %+v", evs[0])
	}
	// A tool result without images carries none.
	evs, _ = NewParser().ParseLine(imgUserLine(t, []any{map[string]any{"type": "tool_result", "tool_use_id": "t2", "content": "ok"}}, nil))
	if len(evs) != 1 || evs[0].Images != nil {
		t.Fatalf("plain result %+v", evs)
	}
}

func TestBase64Size(t *testing.T) {
	for _, n := range []int{0, 1, 2, 3, 4, 5, 100, 1001} {
		s := base64.StdEncoding.EncodeToString(make([]byte, n))
		if got := transcript.Base64Size(s); got != n {
			t.Fatalf("size of %d bytes: %d", n, got)
		}
		r := base64.RawStdEncoding.EncodeToString(make([]byte, n))
		if got := transcript.Base64Size(r); got != n {
			t.Fatalf("raw size of %d bytes: %d", n, got)
		}
	}
}
