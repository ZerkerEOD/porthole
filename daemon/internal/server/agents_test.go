package server

import (
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"path/filepath"
	"testing"

	"golang.org/x/time/rate"

	"github.com/ZerkerEOD/porthole/daemon/internal/config"
	"github.com/ZerkerEOD/porthole/daemon/internal/core"
	"github.com/ZerkerEOD/porthole/daemon/internal/tmux"
	"github.com/ZerkerEOD/porthole/daemon/internal/transcript"
)

func TestAgentSubscribeRoundTrip(t *testing.T) {
	const sid = "99999999-aaaa-bbbb-cccc-000000000001"
	const aid = "a0123456789abcdef"
	parent, err := filepath.Abs(filepath.Join("..", "provider", "claude", "testdata", "agents", sid+".jsonl"))
	if err != nil {
		t.Fatal(err)
	}
	log := slog.New(slog.NewTextHandler(io.Discard, nil))
	reg := core.New(config.Default(), log)
	h := newHub(reg, log)
	key := reg.RegisterFromHook("claude", sid, parent, "/home/me/proj").Key

	c := &conn{h: h, log: log, lim: rate.NewLimiter(rate.Inf, 1), subs: map[string]bool{}, paneSubs: map[string]bool{},
		send: make(chan []byte, 64), pane: map[string]*tmux.Screen{}, paneKick: make(chan struct{}, 1)}
	h.add(c)
	defer h.remove(c)

	call := func(typ string, payload any) ResultMsg {
		t.Helper()
		b, _ := json.Marshal(payload)
		c.handle(context.Background(), Message{Type: typ, ID: "1", Payload: b})
		for {
			var m Message
			if err := json.Unmarshal(<-c.send, &m); err != nil {
				t.Fatal(err)
			}
			if m.Type != "result" {
				continue // session.upsert and other pushes
			}
			var res ResultMsg
			_ = json.Unmarshal(m.Payload, &res)
			return res
		}
	}

	res := call("agent.subscribe", AgentSubscribeReq{Key: key, AgentID: "missing"})
	if res.OK || res.Error == "" {
		t.Fatalf("unknown agent: %+v", res)
	}
	res = call("agent.subscribe", AgentSubscribeReq{Key: key, AgentID: aid, Limit: 50})
	if !res.OK {
		t.Fatalf("subscribe failed: %s", res.Error)
	}
	var hist HistoryMsg
	if err := json.Unmarshal(res.Data, &hist); err != nil {
		t.Fatal(err)
	}
	if hist.Key != key || hist.AgentID != aid || len(hist.Events) == 0 || hist.HasMore {
		t.Fatalf("reply %+v", hist)
	}
	for _, ev := range hist.Events {
		if !ev.Sidechain {
			t.Fatalf("non-subagent event in agent stream: %+v", ev)
		}
	}

	res = call("history.page", HistoryReq{Key: key, AgentID: aid, Before: hist.Events[len(hist.Events)-1].Seq, Limit: 1})
	if !res.OK {
		t.Fatalf("history.page: %s", res.Error)
	}
	_ = json.Unmarshal(res.Data, &hist)
	if hist.AgentID != aid || len(hist.Events) != 1 || !hist.HasMore {
		t.Fatalf("history page %+v", hist)
	}

	// Live events for the agent key go out as agent.events.
	h.Events(core.AgentKey(key, aid), []transcript.Event{{Type: transcript.TypeText, Text: "x"}})
	var m Message
	_ = json.Unmarshal(<-c.send, &m)
	var push AgentEventsMsg
	_ = json.Unmarshal(m.Payload, &push)
	if m.Type != "agent.events" || push.Key != key || push.AgentID != aid || len(push.Events) != 1 {
		t.Fatalf("push %s %+v", m.Type, push)
	}

	if res = call("agent.unsubscribe", AgentKeyReq{Key: key, AgentID: aid}); !res.OK {
		t.Fatal(res.Error)
	}
	h.Events(core.AgentKey(key, aid), []transcript.Event{{Type: transcript.TypeText}})
	select {
	case b := <-c.send:
		t.Fatalf("event after unsubscribe: %s", b)
	default:
	}
}
