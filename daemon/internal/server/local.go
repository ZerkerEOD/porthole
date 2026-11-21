package server

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/ZerkerEOD/porthole/daemon/internal/config"
	"github.com/ZerkerEOD/porthole/daemon/internal/core"
	"github.com/ZerkerEOD/porthole/daemon/internal/transcript"
	"github.com/ZerkerEOD/porthole/daemon/internal/version"
)

// Local is the control API on a unix socket (0600) used by the porthole CLI
// and by the Claude/Codex hook subcommands. Any process of the same user may
// call it; that is equivalent to that user's shell access, see threat model.
type Local struct {
	cfg   *config.Config
	reg   *core.Registry
	store *Store
	srv   *Server
	log   *slog.Logger
	start time.Time
	// notifications is the ring of recent "needs attention" events, read by
	// the push path (M7) and the status command.
	notes []Note
}

// Note is an attention event derived from hooks.
type Note struct {
	At         time.Time `json:"at"`
	Provider   string    `json:"provider"`
	SessionKey string    `json:"session_key,omitempty"`
	Kind       string    `json:"kind"` // permission|input|done|error
	Text       string    `json:"text,omitempty"`
}

// NewLocal builds the local API.
func NewLocal(cfg *config.Config, reg *core.Registry, store *Store, srv *Server, log *slog.Logger) *Local {
	return &Local{cfg: cfg, reg: reg, store: store, srv: srv, log: log, start: time.Now()}
}

// PairInfo is what `porthole pair` renders as a QR code.
type PairInfo struct {
	V           int       `json:"v"`
	Name        string    `json:"name"`
	Hosts       []string  `json:"hosts"`
	Port        int       `json:"port"`
	Fingerprint string    `json:"fp"`
	Code        string    `json:"code"`
	ExpiresAt   time.Time `json:"exp"`
}

// ReloadResult is what a config reload applied.
type ReloadResult struct {
	Workspaces []string `json:"workspaces"`
	Repos      []string `json:"repos"`
}

// Status is the daemon's self-report.
type Status struct {
	Version   string    `json:"version"`
	Name      string    `json:"name"`
	PID       int       `json:"pid"`
	Uptime    string    `json:"uptime"`
	Bound     []string  `json:"bound"`
	Sessions  int       `json:"sessions"`
	Running   int       `json:"running"`
	Devices   int       `json:"devices"`
	Tmux      bool      `json:"tmux"`
	Cswap     bool      `json:"cswap"`
	StartedAt time.Time `json:"started_at"`
}

func (l *Local) routes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /status", func(w http.ResponseWriter, r *http.Request) {
		var bound []string
		for _, a := range l.srv.BoundAddrs() {
			bound = append(bound, a.String())
		}
		ss := l.reg.Sessions()
		running := 0
		for _, s := range ss {
			if s.Running {
				running++
			}
		}
		writeJSON(w, Status{Version: version.Version, Name: l.cfg.Name, PID: os.Getpid(), Uptime: time.Since(l.start).Round(time.Second).String(), Bound: bound, Sessions: len(ss), Running: running, Devices: len(l.store.Devices()), Tmux: l.reg.Tmux().Available(r.Context()), Cswap: l.reg.Accounts().Claude != nil, StartedAt: l.start})
	})
	mux.HandleFunc("POST /pair/new", func(w http.ResponseWriter, r *http.Request) {
		var req struct {
			Label string `json:"label"`
		}
		_ = json.NewDecoder(http.MaxBytesReader(w, r.Body, 4096)).Decode(&req)
		code, exp, err := l.store.NewPairingCode(req.Label)
		if err != nil {
			http.Error(w, err.Error(), 500)
			return
		}
		writeJSON(w, PairInfo{V: 1, Name: l.cfg.Name, Hosts: AdvertiseAddrs(l.srv.BoundAddrs()), Port: l.cfg.Port, Fingerprint: l.srv.Fingerprint(), Code: code, ExpiresAt: exp})
	})
	mux.HandleFunc("GET /devices", func(w http.ResponseWriter, r *http.Request) { writeJSON(w, l.store.Devices()) })
	mux.HandleFunc("POST /devices/revoke", func(w http.ResponseWriter, r *http.Request) {
		var req struct {
			ID string `json:"id"`
		}
		_ = json.NewDecoder(http.MaxBytesReader(w, r.Body, 4096)).Decode(&req)
		if err := l.store.Revoke(req.ID); err != nil {
			http.Error(w, err.Error(), 404)
			return
		}
		l.log.Info("device revoked", "device", req.ID)
		writeJSON(w, map[string]bool{"ok": true})
	})
	mux.HandleFunc("GET /sessions", func(w http.ResponseWriter, r *http.Request) { writeJSON(w, l.reg.Sessions()) })
	mux.HandleFunc("GET /repos", func(w http.ResponseWriter, r *http.Request) { writeJSON(w, l.reg.Repos()) })
	mux.HandleFunc("POST /config/reload", func(w http.ResponseWriter, r *http.Request) {
		ws, rs, err := l.reg.Reload()
		if err != nil {
			http.Error(w, err.Error(), 400)
			return
		}
		writeJSON(w, ReloadResult{Workspaces: ws, Repos: rs})
	})
	mux.HandleFunc("GET /notes", func(w http.ResponseWriter, r *http.Request) { writeJSON(w, l.notes) })
	mux.HandleFunc("POST /hook", l.handleClaudeHook)
	mux.HandleFunc("POST /codex-notify", l.handleCodexNotify)
	return mux
}

func (l *Local) note(n Note) {
	n.At = time.Now()
	l.notes = append(l.notes, n)
	if len(l.notes) > 100 {
		l.notes = l.notes[len(l.notes)-100:]
	}
	title := n.Text
	if s, ok := l.reg.Get(n.SessionKey); ok && s.Title != "" {
		title = s.Title
	}
	if n.Kind == "permission" || n.Kind == "input" || n.Kind == "done" {
		l.srv.Notify(n.Kind, n.SessionKey, title)
	}
}

// claudeHook is the common hook input (docs: code.claude.com/docs/en/hooks).
type claudeHook struct {
	SessionID        string         `json:"session_id"`
	TranscriptPath   string         `json:"transcript_path"`
	Cwd              string         `json:"cwd"`
	HookEventName    string         `json:"hook_event_name"`
	PermissionMode   string         `json:"permission_mode"`
	ToolName         string         `json:"tool_name"`
	ToolInput        map[string]any `json:"tool_input"`
	NotificationType string         `json:"notification_type"`
	Message          string         `json:"message"`
	Prompt           string         `json:"prompt"`
	Source           string         `json:"source"`
	Reason           string         `json:"reason"`
}

func (l *Local) handleClaudeHook(w http.ResponseWriter, r *http.Request) {
	var h claudeHook
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<20)).Decode(&h); err != nil {
		http.Error(w, "bad hook payload", 400)
		return
	}
	if h.SessionID == "" || h.TranscriptPath == "" {
		http.Error(w, "missing session", 400)
		return
	}
	if !l.transcriptAllowed(h.TranscriptPath) {
		l.log.Warn("hook for transcript outside watched profiles", "path", h.TranscriptPath)
		writeJSON(w, map[string]any{})
		return
	}
	sess := l.reg.RegisterFromHook("claude", h.SessionID, h.TranscriptPath, h.Cwd)
	key := sess.Key
	l.log.Debug("hook", "event", h.HookEventName, "session", key)
	switch h.HookEventName {
	case "SessionStart":
		l.reg.SetStatus(key, transcript.StatusIdle)
		go l.reg.RefreshAccounts(context.Background())
	case "SessionEnd":
		l.reg.SetStatus(key, transcript.StatusExited)
	case "UserPromptSubmit":
		l.reg.SetStatus(key, transcript.StatusBusy)
	case "Stop":
		l.reg.SetStatus(key, transcript.StatusIdle)
		l.note(Note{Provider: "claude", SessionKey: key, Kind: "done", Text: sess.Title})
	case "PostModelSwitch":
		go l.reg.RefreshAccounts(context.Background())
	case "Notification":
		switch h.NotificationType {
		case "permission_prompt":
			l.reg.SetStatus(key, transcript.StatusWaitingPermission)
			l.note(Note{Provider: "claude", SessionKey: key, Kind: "permission", Text: h.Message})
		case "idle_prompt", "agent_needs_input", "elicitation_dialog":
			l.reg.SetStatus(key, transcript.StatusWaitingInput)
			l.note(Note{Provider: "claude", SessionKey: key, Kind: "input", Text: h.Message})
		case "agent_completed":
			l.note(Note{Provider: "claude", SessionKey: key, Kind: "done", Text: h.Message})
		}
	case "PermissionRequest":
		l.note(Note{Provider: "claude", SessionKey: key, Kind: "permission", Text: h.ToolName})
		timeout := time.Duration(l.cfg.Hooks.PermissionTimeoutS) * time.Second
		if timeout <= 0 {
			timeout = 60 * time.Second
		}
		ans := l.reg.Permissions().Ask(r.Context(), key, h.ToolName, h.ToolInput, h.Cwd, timeout)
		if ans == "" {
			writeJSON(w, map[string]any{})
			return
		}
		writeJSON(w, map[string]any{
			"hookSpecificOutput": map[string]any{
				"hookEventName": "PermissionRequest",
				"decision":      map[string]any{"behavior": ans},
			},
		})
		return
	}
	writeJSON(w, map[string]any{})
}

// transcriptAllowed checks the hook's transcript lives under a known profile.
func (l *Local) transcriptAllowed(p string) bool {
	real, err := filepath.EvalSymlinks(p)
	if err != nil {
		return false
	}
	for _, s := range l.reg.Sessions() {
		if s.Profile != "" {
			if proj, err := filepath.EvalSymlinks(filepath.Join(s.Profile, "projects")); err == nil && strings.HasPrefix(real, proj+string(filepath.Separator)) {
				return true
			}
		}
	}
	// No sessions yet: accept the default profile and configured extras.
	cands := append([]string{config.Expand("~/.claude")}, l.cfg.Profiles...)
	if v := os.Getenv("CLAUDE_CONFIG_DIR"); v != "" {
		cands = append(cands, v)
	}
	for _, c := range cands {
		if proj, err := filepath.EvalSymlinks(filepath.Join(c, "projects")); err == nil && strings.HasPrefix(real, proj+string(filepath.Separator)) {
			return true
		}
	}
	return false
}

func (l *Local) handleCodexNotify(w http.ResponseWriter, r *http.Request) {
	var n struct {
		Type                 string   `json:"type"`
		TurnID               string   `json:"turn-id"`
		ThreadID             string   `json:"thread-id"`
		InputMessages        []string `json:"input-messages"`
		LastAssistantMessage string   `json:"last-assistant-message"`
		Cwd                  string   `json:"cwd"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<20)).Decode(&n); err != nil {
		http.Error(w, "bad payload", 400)
		return
	}
	key := ""
	if n.ThreadID != "" {
		key = "codex:" + n.ThreadID
	}
	l.note(Note{Provider: "codex", SessionKey: key, Kind: "done", Text: firstLine(n.LastAssistantMessage, 140)})
	writeJSON(w, map[string]any{})
}

func firstLine(s string, max int) string {
	s = strings.TrimSpace(s)
	if i := strings.IndexByte(s, '\n'); i >= 0 {
		s = s[:i]
	}
	rs := []rune(s)
	if len(rs) > max {
		return string(rs[:max]) + "…"
	}
	return s
}

// Run serves the unix socket until ctx ends.
func (l *Local) Run(ctx context.Context) error {
	path := config.SocketPath()
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	// Refuse to clobber a live daemon.
	if c, err := net.DialTimeout("unix", path, 500*time.Millisecond); err == nil {
		_ = c.Close()
		return fmt.Errorf("another porthole daemon is already listening on %s", path)
	}
	_ = os.Remove(path)
	ln, err := net.Listen("unix", path)
	if err != nil {
		return err
	}
	if err := os.Chmod(path, 0o600); err != nil {
		_ = ln.Close()
		return err
	}
	srv := &http.Server{Handler: l.routes(), ReadHeaderTimeout: 5 * time.Second}
	go func() {
		<-ctx.Done()
		sctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		defer cancel()
		_ = srv.Shutdown(sctx)
		_ = os.Remove(path)
	}()
	l.log.Info("control socket", "path", path)
	if err := srv.Serve(ln); err != nil && !errors.Is(err, http.ErrServerClosed) {
		return err
	}
	return nil
}

// LocalClient talks to a running daemon over the unix socket.
type LocalClient struct{ http *http.Client }

// NewLocalClient dials the control socket.
func NewLocalClient() *LocalClient {
	path := config.SocketPath()
	return &LocalClient{http: &http.Client{
		Transport: &http.Transport{DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
			var d net.Dialer
			return d.DialContext(ctx, "unix", path)
		}},
		Timeout: 0,
	}}
}

// Call performs one request; out may be nil.
func (c *LocalClient) Call(ctx context.Context, method, route string, in, out any, timeout time.Duration) error {
	var body *strings.Reader
	if in != nil {
		b, err := json.Marshal(in)
		if err != nil {
			return err
		}
		body = strings.NewReader(string(b))
	} else {
		body = strings.NewReader("")
	}
	if timeout > 0 {
		var cancel context.CancelFunc
		ctx, cancel = context.WithTimeout(ctx, timeout)
		defer cancel()
	}
	req, err := http.NewRequestWithContext(ctx, method, "http://porthole"+route, body)
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := c.http.Do(req)
	if err != nil {
		return fmt.Errorf("daemon not reachable (is `porthole serve` running?): %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 300 {
		var msg strings.Builder
		_, _ = fmt.Fprintf(&msg, "daemon returned %s", resp.Status)
		b := make([]byte, 512)
		if n, _ := resp.Body.Read(b); n > 0 {
			msg.WriteString(": " + strings.TrimSpace(string(b[:n])))
		}
		return errors.New(msg.String())
	}
	if out != nil {
		return json.NewDecoder(resp.Body).Decode(out)
	}
	return nil
}
