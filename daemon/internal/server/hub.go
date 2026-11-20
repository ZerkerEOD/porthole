package server

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"log/slog"
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

// Notify pushes an attention event to every device that is not connected
// and has a live grant. Connected devices already see it over the socket.
func (h *hub) Notify(kind, sessionKey, title string) {
	if h.push == nil || h.store == nil {
		return
	}
	for _, d := range h.store.PushTargets() {
		if h.connected(d.ID) {
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
			if err := h.push.Send(ctx, d.PushGrant, key, n, collapse); err != nil {
				h.log.Warn("push failed", "device", d.ID, "err", err)
				if errors.Is(err, push.ErrRejected) {
					_ = h.store.SetPushGrant(d.ID, "", time.Time{})
				}
			}
		}(d)
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
func (h *hub) SessionRemoved(key string) {
	h.each(func(c *conn) { c.push("session.removed", KeyReq{Key: key}) })
}
func (h *hub) Events(key string, evs []transcript.Event) {
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
		evs, more, err := reg.History(r.Key, r.Before, r.Limit)
		if err != nil {
			c.reply(m.ID, false, err.Error(), nil)
			return
		}
		c.reply(m.ID, true, "", HistoryMsg{Key: r.Key, Events: evs, HasMore: more})
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
		c.log.Info("permission answer", "id", r.ID, "behavior", r.Behavior)
		if err := reg.Permissions().Answer(r.ID, r.Behavior); err != nil {
			c.reply(m.ID, false, err.Error(), nil)
			return
		}
		c.reply(m.ID, true, "", nil)
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
