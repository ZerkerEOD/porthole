package server

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"log/slog"
	"strings"
	"sync"
	"time"

	"github.com/coder/websocket"
	"golang.org/x/time/rate"

	"github.com/ZerkerEOD/porthole/daemon/internal/core"
	"github.com/ZerkerEOD/porthole/daemon/internal/push"
	"github.com/ZerkerEOD/porthole/daemon/internal/tmux"
	"github.com/ZerkerEOD/porthole/daemon/internal/transcript"
)

const (
	maxMessageBytes   = 64 * 1024
	sendQueue         = 512
	maxConnsPerDevice = 4
)

// hub fans registry changes out to connections and implements core.Listener.
type hub struct {
	reg   *core.Registry
	log   *slog.Logger
	mu    sync.RWMutex
	conns map[*conn]struct{}

	store *Store
	push  *push.Client
	name  string
	// lastPush dedupes pushes per device+session+kind.
	lastPush map[string]time.Time
}

func newHub(reg *core.Registry, log *slog.Logger) *hub {
	h := &hub{reg: reg, log: log, conns: map[*conn]struct{}{}, lastPush: map[string]time.Time{}}
	reg.AddListener(h)
	return h
}

// connected reports whether a device has at least one live connection.
func (h *hub) connected(deviceID string) bool {
	h.mu.RLock()
	defer h.mu.RUnlock()
	for c := range h.conns {
		if c.device.ID == deviceID {
			return true
		}
	}
	return false
}

// Notify pushes an attention event to every device that is not connected,
// has a live grant and opened the session (or the daemon spawned it).
// Connected devices already see it over the socket.
func (h *hub) Notify(kind, sessionKey, title string) {
	if h.push == nil || h.store == nil {
		return
	}
	spawned := false
	if s, ok := h.reg.Get(sessionKey); ok {
		spawned = s.Spawned
	}
	for _, d := range h.targets(kind, sessionKey, spawned) {
		key, err := hex.DecodeString(d.PushSecret)
		if err != nil {
			continue
		}
		n := push.Notification{Kind: kind, SessionKey: sessionKey, Title: title, Daemon: h.name, At: time.Now().Unix()}
		// The relay groups notices per session but must not learn session ids: send an opaque digest.
		sum := sha256.Sum256([]byte(sessionKey))
		collapse := hex.EncodeToString(sum[:])[:32]
		go func(d Device) {
			ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
			defer cancel()
			status, err := h.push.Send(ctx, d.PushGrant, key, n, collapse)
			if err != nil {
				h.log.Warn("push failed", "device", d.ID, "kind", kind, "status", status, "err", err)
				if errors.Is(err, push.ErrRejected) {
					_ = h.store.SetPushGrant(d.ID, "", time.Time{})
				}
				return
			}
			h.log.Info("push sent", "device", d.ID, "kind", kind, "status", status)
		}(d)
	}
}

// targets picks the devices a notice goes to: a live grant, no open
// socket, the session opened on that device (unless spawned here), and no
// push of the same kind for the session in the last 45 s.
func (h *hub) targets(kind, sessionKey string, spawned bool) []Device {
	var out []Device
	for _, d := range h.store.PushTargets() {
		if h.connected(d.ID) {
			continue
		}
		if !spawned && !h.store.Opened(d.ID, sessionKey) {
			h.log.Debug("push skipped", "device", d.ID, "kind", kind, "session", sessionKey, "reason", "not opened")
			continue
		}
		dk := d.ID + "|" + sessionKey + "|" + kind
		h.mu.Lock()
		if t, ok := h.lastPush[dk]; ok && time.Since(t) < 45*time.Second {
			h.mu.Unlock()
			continue
		}
		h.lastPush[dk] = time.Now()
		h.mu.Unlock()
		out = append(out, d)
	}
	return out
}

// opened records that a device opened a session, so its notices get pushed.
func (h *hub) opened(deviceID, key string) {
	if h.store != nil {
		h.store.MarkOpened(deviceID, key)
	}
}

// conn is one WebSocket client.
type conn struct {
	h      *hub
	ws     *websocket.Conn
	device Device
	log    *slog.Logger
	lim    *rate.Limiter

	mu       sync.Mutex
	subs     map[string]bool
	paneSubs map[string]bool
	send     chan []byte
	pane     map[string]*tmux.Screen // latest snapshot per key, coalesced
	paneKick chan struct{}
	closed   bool
}

func (h *hub) add(c *conn) int {
	h.mu.Lock()
	defer h.mu.Unlock()
	n := 0
	for o := range h.conns {
		if o.device.ID == c.device.ID {
			n++
		}
	}
	h.conns[c] = struct{}{}
	return n + 1
}

func (h *hub) remove(c *conn) {
	h.mu.Lock()
	delete(h.conns, c)
	h.mu.Unlock()
	c.mu.Lock()
	subs, panes := c.subs, c.paneSubs
	c.subs, c.paneSubs = map[string]bool{}, map[string]bool{}
	c.mu.Unlock()
	for k := range subs {
		h.reg.Unsubscribe(k)
	}
	for k := range panes {
		h.reg.UnsubscribePane(k)
	}
}

func (h *hub) each(fn func(c *conn)) {
	h.mu.RLock()
	cs := make([]*conn, 0, len(h.conns))
	for c := range h.conns {
		cs = append(cs, c)
	}
	h.mu.RUnlock()
	for _, c := range cs {
		fn(c)
	}
}

// closeDevice drops every connection of a revoked device.
func (h *hub) closeDevice(id string) {
	h.each(func(c *conn) {
		if c.device.ID == id {
			c.close(websocket.StatusPolicyViolation, "device revoked")
		}
	})
}

// ---- core.Listener ----

func (h *hub) SessionUpserted(s core.Session) {
	h.each(func(c *conn) { c.push("session.upsert", s) })
}
func (h *hub) SessionReplaced(oldKey, newKey string) {
	if h.store != nil {
		h.store.ReplaceOpened(oldKey, newKey)
	}
	h.each(func(c *conn) { c.push("session.replaced", ReplacedMsg{Old: oldKey, New: newKey}) })
}
func (h *hub) SessionRemoved(key string) {
	h.each(func(c *conn) {
		// The registry dropped the session's subagent followers.
		prefix := key + "#"
		c.mu.Lock()
		for k := range c.subs {
			if strings.HasPrefix(k, prefix) {
				delete(c.subs, k)
			}
		}
		c.mu.Unlock()
		c.push("session.removed", KeyReq{Key: key})
	})
}
func (h *hub) Events(key string, evs []transcript.Event) {
	if sk, agentID, ok := strings.Cut(key, "#"); ok {
		h.each(func(c *conn) {
			if c.subscribed(key) {
				c.push("agent.events", AgentEventsMsg{Key: sk, AgentID: agentID, Events: evs})
			}
		})
		return
	}
	h.each(func(c *conn) {
		if c.subscribed(key) {
			c.push("event", EventsMsg{Key: key, Events: evs})
		}
	})
}
func (h *hub) Pane(key string, scr *tmux.Screen) {
	h.each(func(c *conn) {
		if c.paneSubscribed(key) {
			c.pushPane(key, scr)
		}
	})
}
func (h *hub) PermissionPending(p core.PermissionRequest) {
	h.each(func(c *conn) { c.push("permission.pending", p) })
}
func (h *hub) PermissionResolved(id, behavior string) {
	h.each(func(c *conn) { c.push("permission.resolved", PermissionResolvedMsg{ID: id, Behavior: behavior}) })
}
func (h *hub) AccountsUpdated(a core.AccountsSnapshot) {
	h.each(func(c *conn) { c.push("accounts.update", a) })
}

// ---- conn ----

func (c *conn) subscribed(key string) bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.subs[key]
}
func (c *conn) paneSubscribed(key string) bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.paneSubs[key]
}

func (c *conn) push(typ string, payload any) {
	b, err := json.Marshal(payload)
	if err != nil {
		return
	}
	m, _ := json.Marshal(Message{Type: typ, Payload: b})
	c.mu.Lock()
	closed := c.closed
	c.mu.Unlock()
	if closed {
		return
	}
	select {
	case c.send <- m:
	default:
		// Slow consumer: drop the connection; the client reconnects and resyncs.
		c.close(websocket.StatusTryAgainLater, "send queue full")
	}
}

func (c *conn) reply(id string, ok bool, errMsg string, data any) {
	var raw json.RawMessage
	if data != nil {
		raw, _ = json.Marshal(data)
	}
	b, _ := json.Marshal(ResultMsg{OK: ok, Error: errMsg, Data: raw})
	m, _ := json.Marshal(Message{Type: "result", ID: id, Payload: b})
	select {
	case c.send <- m:
	default:
		c.close(websocket.StatusTryAgainLater, "send queue full")
	}
}

func (c *conn) pushPane(key string, scr *tmux.Screen) {
	c.mu.Lock()
	c.pane[key] = scr
	c.mu.Unlock()
	select {
	case c.paneKick <- struct{}{}:
	default:
	}
}

func (c *conn) close(code websocket.StatusCode, reason string) {
	c.mu.Lock()
	if c.closed {
		c.mu.Unlock()
		return
	}
	c.closed = true
	c.mu.Unlock()
	_ = c.ws.Close(code, reason)
}

// writer drains the send queue, then coalesced pane snapshots.
func (c *conn) writer(ctx context.Context) {
	for {
		select {
		case <-ctx.Done():
			return
		case m := <-c.send:
			wctx, cancel := context.WithTimeout(ctx, 10*time.Second)
			err := c.ws.Write(wctx, websocket.MessageText, m)
			cancel()
			if err != nil {
				c.close(websocket.StatusAbnormalClosure, "write failed")
				return
			}
		case <-c.paneKick:
			c.mu.Lock()
			snaps := c.pane
			c.pane = map[string]*tmux.Screen{}
			c.mu.Unlock()
			for k, scr := range snaps {
				b, _ := json.Marshal(PaneMsg{Key: k, Screen: scr})
				m, _ := json.Marshal(Message{Type: "pane.snapshot", Payload: b})
				wctx, cancel := context.WithTimeout(ctx, 10*time.Second)
				err := c.ws.Write(wctx, websocket.MessageText, m)
				cancel()
				if err != nil {
					c.close(websocket.StatusAbnormalClosure, "write failed")
					return
				}
			}
		}
	}
}

// handle dispatches one client message.
func (c *conn) handle(ctx context.Context, m Message) {
	if !c.lim.Allow() {
		c.reply(m.ID, false, "rate limited", nil)
		return
	}
	reg := c.h.reg
	switch m.Type {
	case "ping":
		c.reply(m.ID, true, "", map[string]any{"pong": time.Now().UTC()})
	case "session.list":
		c.reply(m.ID, true, "", reg.Sessions())
	case "session.subscribe":
		var r SubscribeReq
		if err := json.Unmarshal(m.Payload, &r); err != nil {
			c.reply(m.ID, false, "bad payload", nil)
			return
		}
		c.mu.Lock()
		already := c.subs[r.Key]
		c.subs[r.Key] = true
		c.mu.Unlock()
		evs, more, err := reg.Subscribe(r.Key, r.Before, r.Limit)
		if err != nil {
			c.mu.Lock()
			delete(c.subs, r.Key)
			c.mu.Unlock()
			c.reply(m.ID, false, err.Error(), nil)
			return
		}
		if already {
			reg.Unsubscribe(r.Key) // keep the count at one per connection
		}
		c.h.opened(c.device.ID, r.Key)
		c.reply(m.ID, true, "", HistoryMsg{Key: r.Key, Events: evs, HasMore: more})
	case "session.unsubscribe":
		var r KeyReq
		_ = json.Unmarshal(m.Payload, &r)
		c.mu.Lock()
		was := c.subs[r.Key]
		delete(c.subs, r.Key)
		c.mu.Unlock()
		if was {
			reg.Unsubscribe(r.Key)
		}
		c.reply(m.ID, true, "", nil)
	case "history.page":
		var r HistoryReq
		if err := json.Unmarshal(m.Payload, &r); err != nil {
			c.reply(m.ID, false, "bad payload", nil)
			return
		}
		var evs []transcript.Event
		var more bool
		var err error
		if r.AgentID != "" {
			evs, more, err = reg.HistoryAgent(r.Key, r.AgentID, r.Before, r.Limit)
		} else {
			evs, more, err = reg.History(r.Key, r.Before, r.Limit)
		}
		if err != nil {
			c.reply(m.ID, false, err.Error(), nil)
			return
		}
		c.reply(m.ID, true, "", HistoryMsg{Key: r.Key, AgentID: r.AgentID, Events: evs, HasMore: more})
	case "agent.subscribe":
		// Read-only: subagent transcripts have no input path.
		var r AgentSubscribeReq
		if err := json.Unmarshal(m.Payload, &r); err != nil || r.Key == "" || r.AgentID == "" {
			c.reply(m.ID, false, "bad payload", nil)
			return
		}
		ak := core.AgentKey(r.Key, r.AgentID)
		c.mu.Lock()
		already := c.subs[ak]
		c.subs[ak] = true
		c.mu.Unlock()
		evs, more, err := reg.SubscribeAgent(r.Key, r.AgentID, r.Before, r.Limit)
		if err != nil {
			if !already {
				c.mu.Lock()
				delete(c.subs, ak)
				c.mu.Unlock()
			}
			c.reply(m.ID, false, err.Error(), nil)
			return
		}
		if already {
			reg.UnsubscribeAgent(r.Key, r.AgentID) // keep the count at one per connection
		}
		c.reply(m.ID, true, "", HistoryMsg{Key: r.Key, AgentID: r.AgentID, Events: evs, HasMore: more})
	case "agent.unsubscribe":
		var r AgentKeyReq
		_ = json.Unmarshal(m.Payload, &r)
		ak := core.AgentKey(r.Key, r.AgentID)
		c.mu.Lock()
		was := c.subs[ak]
		delete(c.subs, ak)
		c.mu.Unlock()
		if was {
			reg.UnsubscribeAgent(r.Key, r.AgentID)
		}
		c.reply(m.ID, true, "", nil)
	case "session.input":
		var r InputReq
		if err := json.Unmarshal(m.Payload, &r); err != nil {
			c.reply(m.ID, false, "bad payload", nil)
			return
		}
		if err := reg.SendText(ctx, r.Key, r.Text, r.Enter); err != nil {
			c.reply(m.ID, false, err.Error(), nil)
			return
		}
		c.reply(m.ID, true, "", nil)
	case "session.keys":
		var r KeysReq
		if err := json.Unmarshal(m.Payload, &r); err != nil {
			c.reply(m.ID, false, "bad payload", nil)
			return
		}
		if err := reg.SendKeys(ctx, r.Key, r.Keys); err != nil {
			c.reply(m.ID, false, err.Error(), nil)
			return
		}
		c.reply(m.ID, true, "", nil)
	case "session.spawn":
		var r core.SpawnRequest
		if err := json.Unmarshal(m.Payload, &r); err != nil {
			c.reply(m.ID, false, "bad payload", nil)
			return
		}
		s, err := reg.Spawn(ctx, r)
		if err != nil {
			c.reply(m.ID, false, err.Error(), nil)
			return
		}
		c.h.opened(c.device.ID, s.Key)
		c.reply(m.ID, true, "", s)
	case "pane.subscribe":
		var r KeyReq
		if err := json.Unmarshal(m.Payload, &r); err != nil {
			c.reply(m.ID, false, "bad payload", nil)
			return
		}
		c.mu.Lock()
		already := c.paneSubs[r.Key]
		c.paneSubs[r.Key] = true
		c.mu.Unlock()
		scr, err := reg.SubscribePane(ctx, r.Key)
		if err != nil {
			c.mu.Lock()
			delete(c.paneSubs, r.Key)
			c.mu.Unlock()
			c.reply(m.ID, false, err.Error(), nil)
			return
		}
		if already {
			reg.UnsubscribePane(r.Key)
		}
		c.h.opened(c.device.ID, r.Key)
		c.reply(m.ID, true, "", PaneMsg{Key: r.Key, Screen: scr})
	case "pane.unsubscribe":
		var r KeyReq
		_ = json.Unmarshal(m.Payload, &r)
		c.mu.Lock()
		was := c.paneSubs[r.Key]
		delete(c.paneSubs, r.Key)
		c.mu.Unlock()
		if was {
			reg.UnsubscribePane(r.Key)
		}
		c.reply(m.ID, true, "", nil)
	case "pane.resize":
		var r ResizeReq
		if err := json.Unmarshal(m.Payload, &r); err != nil {
			c.reply(m.ID, false, "bad payload", nil)
			return
		}
		s, ok := reg.Get(r.Key)
		if !ok || !s.Controllable || !s.Spawned {
			// Only sessions Porthole spawned get resized; a user's own tmux
			// window keeps its size.
			c.reply(m.ID, false, "resize only applies to sessions Porthole started", nil)
			return
		}
		if err := reg.Tmux().Resize(ctx, s.PaneID, r.Cols, r.Rows); err != nil {
			c.reply(m.ID, false, err.Error(), nil)
			return
		}
		c.reply(m.ID, true, "", nil)
	case "permission.answer":
		var r PermissionAnswerReq
		if err := json.Unmarshal(m.Payload, &r); err != nil {
			c.reply(m.ID, false, "bad payload", nil)
			return
		}
		c.log.Info("permission answer", "id", r.ID, "behavior", r.Behavior, "option", r.Option)
		var err error
		if r.Option != nil {
			if !reg.Permissions().IsRecovered(r.ID) {
				err = errors.New("options apply to prompts read from the terminal")
			} else {
				err = reg.Permissions().AnswerRecovered(ctx, r.ID, *r.Option)
			}
		} else {
			err = reg.Permissions().AnswerAny(ctx, r.ID, r.Behavior)
		}
		if err != nil {
			c.reply(m.ID, false, err.Error(), nil)
			return
		}
		c.reply(m.ID, true, "", nil)
	case "session.mode":
		var r ModeReq
		if err := json.Unmarshal(m.Payload, &r); err != nil || r.Key == "" {
			c.reply(m.ID, false, "bad payload", nil)
			return
		}
		c.log.Info("mode request", "session", r.Key, "mode", r.Mode)
		got, err := reg.SetMode(ctx, r.Key, r.Mode)
		if err != nil {
			c.reply(m.ID, false, err.Error(), ModeMsg{Key: r.Key, Mode: got})
			return
		}
		c.reply(m.ID, true, "", ModeMsg{Key: r.Key, Mode: got})
	case "question.answer":
		var r QuestionAnswerReq
		if err := json.Unmarshal(m.Payload, &r); err != nil || r.Key == "" || r.ID == "" {
			c.reply(m.ID, false, "bad payload", nil)
			return
		}
		c.log.Info("question answer", "session", r.Key, "id", r.ID)
		res, err := reg.AnswerQuestion(ctx, r.Key, r.ID, r.Answers)
		if err != nil {
			c.reply(m.ID, false, err.Error(), nil)
			return
		}
		if !res.OK {
			c.log.Warn("question answer failed", "session", r.Key, "id", r.ID, "reason", res.Reason)
		}
		c.reply(m.ID, true, "", res)
	case "repos.list":
		c.reply(m.ID, true, "", reg.Repos())
	case "skills.list":
		var r struct {
			Provider string `json:"provider"`
			Repo     string `json:"repo"`
		}
		_ = json.Unmarshal(m.Payload, &r)
		c.reply(m.ID, true, "", reg.Skills(r.Provider, r.Repo))
	case "accounts.get":
		c.reply(m.ID, true, "", reg.Accounts())
	case "push.register":
		var r struct {
			Grant     string    `json:"grant"`
			ExpiresAt time.Time `json:"expires_at"`
		}
		if err := json.Unmarshal(m.Payload, &r); err != nil || r.Grant == "" || len(r.Grant) > 4096 {
			c.reply(m.ID, false, "bad payload", nil)
			return
		}
		if c.h.store == nil || c.h.push == nil {
			c.reply(m.ID, false, "push is not enabled on this daemon", nil)
			return
		}
		if err := c.h.store.SetPushGrant(c.device.ID, r.Grant, r.ExpiresAt); err != nil {
			c.reply(m.ID, false, err.Error(), nil)
			return
		}
		c.log.Info("push grant registered", "expires", r.ExpiresAt)
		c.reply(m.ID, true, "", nil)
	case "push.unregister":
		if c.h.store != nil {
			_ = c.h.store.SetPushGrant(c.device.ID, "", time.Time{})
		}
		c.reply(m.ID, true, "", nil)
	default:
		c.reply(m.ID, false, "unknown message type", nil)
	}
}
