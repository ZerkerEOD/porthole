package server

import (
	"context"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"net"
	"net/http"
	"net/netip"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/coder/websocket"
	"golang.org/x/time/rate"

	"github.com/ZerkerEOD/porthole/daemon/internal/config"
	"github.com/ZerkerEOD/porthole/daemon/internal/core"
	"github.com/ZerkerEOD/porthole/daemon/internal/push"
	"github.com/ZerkerEOD/porthole/daemon/internal/version"
)

// Server is the TLS edge for phones.
type Server struct {
	cfg         *config.Config
	reg         *core.Registry
	store       *Store
	hub         *hub
	log         *slog.Logger
	allowPublic bool
	cert        string // fingerprint
	conns       *connLog

	mu        sync.Mutex
	listeners map[netip.Addr]net.Listener
}

// New builds the server.
func New(cfg *config.Config, reg *core.Registry, store *Store, log *slog.Logger, allowPublic bool) *Server {
	h := newHub(reg, log)
	h.store, h.name = store, cfg.Name
	reg.Permissions().SetPolicy(store.OpenedAny, reg.Tmux().Attached, time.Duration(cfg.Hooks.PermissionTimeoutDetachedS)*time.Second)
	if cfg.Push.RelayURL != "" {
		pc, err := push.NewClient(cfg.Push.RelayURL)
		if err != nil {
			log.Error("push disabled", "err", err)
		} else {
			h.push = pc
			log.Info("push relay enabled", "url", cfg.Push.RelayURL)
		}
	}
	return &Server{cfg: cfg, reg: reg, store: store, hub: h, log: log, allowPublic: allowPublic, conns: newConnLog(connLogSize), listeners: map[netip.Addr]net.Listener{}}
}

// Notify forwards an attention event to the push path.
func (s *Server) Notify(kind, sessionKey, title string) { s.hub.Notify(kind, sessionKey, title) }

// Fingerprint returns the pinned certificate fingerprint.
func (s *Server) Fingerprint() string { return s.cert }

// RecentConnections lists the latest connection attempts, newest first.
func (s *Server) RecentConnections() []ConnAttempt { return s.conns.recent() }

// BoundAddrs lists the addresses currently listened on.
func (s *Server) BoundAddrs() []netip.Addr {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := make([]netip.Addr, 0, len(s.listeners))
	for a := range s.listeners {
		out = append(out, a)
	}
	return out
}

func (s *Server) routes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("POST /v1/pair", s.handlePair)
	mux.Handle("GET /v1/ws", s.auth(http.HandlerFunc(s.handleWS)))
	mux.Handle("GET /v1/health", s.auth(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, map[string]any{"ok": true, "version": version.Version, "protocol": version.Protocol, "name": s.cfg.Name})
	})))
	mux.Handle("GET /v1/sessions", s.auth(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, s.reg.Sessions())
	})))
	mux.Handle("GET /v1/sessions/{key}/history", s.auth(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		before, _ := strconv.ParseInt(r.URL.Query().Get("before"), 10, 64)
		limit, _ := strconv.Atoi(r.URL.Query().Get("limit"))
		evs, more, err := s.reg.History(r.PathValue("key"), before, limit)
		if err != nil {
			http.Error(w, "not found", http.StatusNotFound)
			return
		}
		writeJSON(w, HistoryMsg{Key: r.PathValue("key"), Events: evs, HasMore: more})
	})))
	mux.Handle("GET /v1/repos", s.auth(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { writeJSON(w, s.reg.Repos()) })))
	mux.Handle("GET /v1/skills", s.auth(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, s.reg.Skills(r.URL.Query().Get("provider"), r.URL.Query().Get("repo")))
	})))
	mux.Handle("GET /v1/accounts", s.auth(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { writeJSON(w, s.reg.Accounts()) })))
	mux.Handle("POST /v1/sessions/spawn", s.auth(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var req core.SpawnRequest
		if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 64*1024)).Decode(&req); err != nil {
			http.Error(w, "bad request", http.StatusBadRequest)
			return
		}
		sess, err := s.reg.Spawn(r.Context(), req)
		if err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
		writeJSON(w, sess)
	})))
	return s.guard(mux)
}

// guard rejects non-private sources before anything else and sets headers.
func (s *Server) guard(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !RemoteAllowed(r.RemoteAddr, s.allowPublic) {
			s.conns.add(ConnAttempt{From: remoteHost(r.RemoteAddr), Path: pathKind(r.URL.Path), Result: ResultRejectedPublic})
			s.log.Warn("rejected public source", "from", remoteHost(r.RemoteAddr), "path", r.URL.Path)
			http.Error(w, "forbidden", http.StatusForbidden)
			return
		}
		w.Header().Set("Cache-Control", "no-store")
		w.Header().Set("X-Content-Type-Options", "nosniff")
		next.ServeHTTP(w, r)
	})
}

type ctxKey int

const deviceKey ctxKey = 1

func (s *Server) auth(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		tok := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
		if tok == "" {
			// WebSocket clients that cannot set headers may use a subprotocol
			// "porthole.token.<token>"; browsers are not a target so this is
			// only a convenience for some client libraries.
			for _, p := range strings.Split(r.Header.Get("Sec-WebSocket-Protocol"), ",") {
				p = strings.TrimSpace(p)
				if strings.HasPrefix(p, "porthole.token.") {
					tok = strings.TrimPrefix(p, "porthole.token.")
				}
			}
		}
		d, ok := s.store.Authenticate(tok)
		if !ok {
			s.conns.add(ConnAttempt{From: remoteHost(r.RemoteAddr), Path: pathKind(r.URL.Path), Result: ResultUnauthorized})
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		next.ServeHTTP(w, r.WithContext(context.WithValue(r.Context(), deviceKey, d)))
	})
}

func writeJSON(w http.ResponseWriter, v any) {
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(v)
}

var pairLimiter = rate.NewLimiter(rate.Every(2*time.Second), 10)

func (s *Server) handlePair(w http.ResponseWriter, r *http.Request) {
	if !pairLimiter.Allow() {
		s.conns.add(ConnAttempt{From: remoteHost(r.RemoteAddr), Path: PathPair, Result: ResultRateLimited})
		http.Error(w, "slow down", http.StatusTooManyRequests)
		return
	}
	var req struct {
		Code       string `json:"code"`
		DeviceName string `json:"device_name"`
		PushKey    string `json:"push_key,omitempty"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4096)).Decode(&req); err != nil {
		http.Error(w, "bad request", http.StatusBadRequest)
		return
	}
	host, _, _ := net.SplitHostPort(r.RemoteAddr)
	var pushSecret, pushPub string
	if req.PushKey != "" {
		peer, err := base64.RawURLEncoding.DecodeString(strings.TrimRight(req.PushKey, "="))
		if err != nil || len(peer) != 32 {
			http.Error(w, "bad push_key", http.StatusBadRequest)
			return
		}
		priv, pub, err := push.Keypair()
		if err != nil {
			http.Error(w, "internal", http.StatusInternalServerError)
			return
		}
		key, err := push.DeriveKey(priv, peer)
		if err != nil {
			http.Error(w, "bad push_key", http.StatusBadRequest)
			return
		}
		pushSecret, pushPub = hex.EncodeToString(key), base64.RawURLEncoding.EncodeToString(pub)
	}
	d, tok, err := s.store.Pair(host, req.Code, req.DeviceName, pushSecret)
	if err != nil {
		s.log.Warn("pairing failed", "from", host, "err", err)
		switch {
		case errors.Is(err, ErrRateLimited):
			s.conns.add(ConnAttempt{From: host, Path: PathPair, Result: ResultRateLimited, Name: req.DeviceName})
			http.Error(w, "too many attempts", http.StatusTooManyRequests)
		default:
			s.conns.add(ConnAttempt{From: host, Path: PathPair, Result: ResultUnauthorized, Name: req.DeviceName})
			http.Error(w, "invalid code", http.StatusUnauthorized)
		}
		return
	}
	s.conns.add(ConnAttempt{From: host, Path: PathPair, Result: ResultAccepted, Device: d.ID, Name: d.Name})
	s.log.Info("device paired", "device", d.ID, "name", d.Name, "from", host)
	resp := map[string]any{"device_id": d.ID, "token": tok, "name": s.cfg.Name, "version": version.Version, "protocol": version.Protocol, "push": s.cfg.Push.RelayURL != ""}
	if pushPub != "" {
		resp["push_pub"] = pushPub
	}
	writeJSON(w, resp)
}

// readDeadline is how long a connection may stay silent. The app pings
// every 20 s; a peer that misses two is gone and its subscriptions are
// released.
const readDeadline = 45 * time.Second

func (s *Server) handleWS(w http.ResponseWriter, r *http.Request) {
	d := r.Context().Value(deviceKey).(Device)
	var c *conn
	idle := time.AfterFunc(readDeadline, func() {
		if c != nil {
			c.close(websocket.StatusGoingAway, "keepalive timeout")
		}
	})
	defer idle.Stop()
	ws, err := websocket.Accept(w, r, &websocket.AcceptOptions{
		Subprotocols: []string{"porthole.v1"},
		// Ping frames are answered by the library inside Read; they only
		// need to refresh the deadline here.
		OnPingReceived: func(context.Context, []byte) bool { idle.Reset(readDeadline); return true },
	})
	if err != nil {
		return
	}
	ws.SetReadLimit(maxMessageBytes)
	c = &conn{h: s.hub, ws: ws, device: d, log: s.log.With("device", d.ID), lim: rate.NewLimiter(60, 120),
		subs: map[string]bool{}, paneSubs: map[string]bool{}, send: make(chan []byte, sendQueue), pane: map[string]*tmux0{}, paneKick: make(chan struct{}, 1)}
	if n := s.hub.add(c); n > maxConnsPerDevice {
		s.hub.remove(c)
		_ = ws.Close(websocket.StatusPolicyViolation, "too many connections")
		return
	}
	defer s.hub.remove(c)
	ctx, cancel := context.WithCancel(r.Context())
	defer cancel()
	go c.writer(ctx)
	s.conns.add(ConnAttempt{From: remoteHost(r.RemoteAddr), Path: PathWebSocket, Result: ResultAccepted, Device: d.ID, Name: d.Name})
	c.log.Info("connected", "from", r.RemoteAddr)
	hello := Hello{Name: s.cfg.Name, Version: version.Version, Protocol: version.Protocol, Device: d.ID, Hosts: AdvertiseAddrs(s.BoundAddrs()), Sessions: s.reg.Sessions(), Accounts: s.reg.Accounts(), Permissions: s.reg.Permissions().Pending(), Runs: s.reg.AllRuns(),
		Features: map[string]bool{"claude": s.cfg.Claude.On(), "codex": s.cfg.Codex.On(), "push": s.cfg.Push.RelayURL != "", "tmux": s.reg.Tmux().Available(ctx)}}
	c.push("hello", hello)
	for {
		_, data, err := ws.Read(ctx)
		if err != nil {
			c.log.Info("disconnected", "reason", err.Error())
			return
		}
		idle.Reset(readDeadline)
		var m Message
		if err := json.Unmarshal(data, &m); err != nil {
			c.reply("", false, "bad json", nil)
			continue
		}
		c.handle(ctx, m)
	}
}

// Run binds every allowed address, re-evaluating the list every 10 s so VPN
// interfaces that come and go are picked up, and serves until ctx ends.
func (s *Server) Run(ctx context.Context) error {
	cert, err := LoadOrCreateCert(config.StateDir(), s.cfg.Name)
	if err != nil {
		return fmt.Errorf("tls: %w", err)
	}
	s.cert = Fingerprint(cert)
	tcfg := TLSConfig(cert)
	handler := s.routes()
	srv := &http.Server{Handler: handler, ReadHeaderTimeout: 10 * time.Second, IdleTimeout: 2 * time.Minute}
	go func() {
		<-ctx.Done()
		sctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		defer cancel()
		_ = srv.Shutdown(sctx)
	}()
	go s.revocationLoop(ctx)
	rebind := func() {
		addrs, err := ListenAddrs(s.cfg.Listen, s.allowPublic)
		if err != nil {
			s.log.Error("listen policy", "err", err)
			return
		}
		want := map[netip.Addr]bool{}
		for _, a := range addrs {
			want[a] = true
		}
		s.mu.Lock()
		defer s.mu.Unlock()
		for a, l := range s.listeners {
			if !want[a] {
				_ = l.Close()
				delete(s.listeners, a)
				s.log.Info("stopped listening", "addr", a)
			}
		}
		for a := range want {
			if _, ok := s.listeners[a]; ok {
				continue
			}
			ap := netip.AddrPortFrom(a, uint16(s.cfg.Port))
			l, err := net.Listen("tcp", ap.String())
			if err != nil {
				s.log.Warn("listen failed", "addr", ap, "err", err)
				continue
			}
			tl := tls0(l, tcfg)
			s.listeners[a] = tl
			s.log.Info("listening", "addr", ap)
			go func() { _ = srv.Serve(tl) }()
		}
	}
	rebind()
	t := time.NewTicker(10 * time.Second)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			s.mu.Lock()
			for _, l := range s.listeners {
				_ = l.Close()
			}
			s.mu.Unlock()
			return nil
		case <-t.C:
			rebind()
		}
	}
}

func (s *Server) revocationLoop(ctx context.Context) {
	t := time.NewTicker(time.Second)
	defer t.Stop()
	touch := time.NewTicker(5 * time.Minute)
	defer touch.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			for _, id := range s.store.DrainRevoked() {
				s.hub.closeDevice(id)
			}
		case <-touch.C:
			s.store.Touch()
		}
	}
}
