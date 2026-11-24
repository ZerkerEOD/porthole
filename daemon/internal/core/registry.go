package core

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"hash/fnv"
	"log/slog"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/ZerkerEOD/porthole/daemon/internal/accounts/cswap"
	"github.com/ZerkerEOD/porthole/daemon/internal/config"
	"github.com/ZerkerEOD/porthole/daemon/internal/provider"
	"github.com/ZerkerEOD/porthole/daemon/internal/provider/claude"
	"github.com/ZerkerEOD/porthole/daemon/internal/provider/codex"
	"github.com/ZerkerEOD/porthole/daemon/internal/tmux"
	"github.com/ZerkerEOD/porthole/daemon/internal/transcript"
)

// Registry discovers sessions and streams their transcripts.
type Registry struct {
	cfg *config.Config
	tm  *tmux.Client
	log *slog.Logger

	mu        sync.RWMutex
	sessions  map[string]*Session
	followers map[string]*follower
	subs      map[string]int // transcript subscribers per key
	paneSubs  map[string]int // pane subscribers per key
	paneHash  map[string]uint64
	spawned   map[string]spawnInfo // pane id -> info
	answering map[string]bool      // keys whose dialog question.answer is driving
	listeners []Listener
	attention []func(kind, key, text string)
	gate      *AttentionGate

	perm   *permissionBroker
	cs     *cswap.Client
	accts  AccountsSnapshot
	acctMu sync.RWMutex

	claudeProfiles []claude.Profile
	codexProfiles  []codex.Profile
	summaries      map[string]summaryEntry

	// dirMu guards the reloadable directory lists (workspaces, repos).
	dirMu      sync.RWMutex
	workspaces []string
	repos      []string
}

type spawnInfo struct {
	Provider    string
	TmuxSession string
	Dir         string
	At          time.Time
}

type summaryEntry struct {
	size  int64
	mtime time.Time
	sess  Session
}

// New creates a registry. Call Run to start scanning.
func New(cfg *config.Config, log *slog.Logger) *Registry {
	r := &Registry{
		cfg:        cfg,
		tm:         &tmux.Client{Binary: cfg.Tmux.Binary},
		log:        log,
		sessions:   map[string]*Session{},
		followers:  map[string]*follower{},
		subs:       map[string]int{},
		paneSubs:   map[string]int{},
		paneHash:   map[string]uint64{},
		spawned:    map[string]spawnInfo{},
		answering:  map[string]bool{},
		summaries:  map[string]summaryEntry{},
		cs:         &cswap.Client{Binary: cfg.Cswap.Binary},
		workspaces: append([]string(nil), cfg.Workspaces...),
		repos:      append([]string(nil), cfg.Repos...),
	}
	r.perm = newPermissionBroker(r)
	r.gate = newAttentionGate(r.attend, func(key string) bool {
		s, ok := r.Get(key)
		return ok && waiting(s.Status)
	})
	return r
}

// Dirs returns the configured workspaces and repositories.
func (r *Registry) Dirs() (workspaces, repos []string) {
	r.dirMu.RLock()
	defer r.dirMu.RUnlock()
	return append([]string(nil), r.workspaces...), append([]string(nil), r.repos...)
}

// Reload re-reads config.toml and repos.toml and applies the directory
// lists. Other settings need a restart. It returns the new lists.
func (r *Registry) Reload() (workspaces, repos []string, err error) {
	fresh, err := config.Load(r.cfg.Path)
	if err != nil {
		return nil, nil, err
	}
	r.dirMu.Lock()
	r.workspaces = append([]string(nil), fresh.Workspaces...)
	r.repos = append([]string(nil), fresh.Repos...)
	r.dirMu.Unlock()
	r.log.Info("config reloaded", "workspaces", fresh.Workspaces, "repos", fresh.Repos)
	return fresh.Workspaces, fresh.Repos, nil
}

// AddListener registers a listener for registry changes.
func (r *Registry) AddListener(l Listener) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.listeners = append(r.listeners, l)
}

// OnAttention registers a callback for attention events the registry raises
// itself, such as a pending question (kind input).
func (r *Registry) OnAttention(fn func(kind, key, text string)) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.attention = append(r.attention, fn)
}

func (r *Registry) attend(kind, key, text string) {
	r.mu.RLock()
	fns := make([]func(kind, key, text string), len(r.attention))
	copy(fns, r.attention)
	r.mu.RUnlock()
	for _, fn := range fns {
		fn(kind, key, text)
	}
}

func (r *Registry) each(fn func(l Listener)) {
	r.mu.RLock()
	ls := append([]Listener(nil), r.listeners...)
	r.mu.RUnlock()
	for _, l := range ls {
		fn(l)
	}
}

// Tmux exposes the tmux client for the server layer.
func (r *Registry) Tmux() *tmux.Client { return r.tm }

// Config exposes the configuration.
func (r *Registry) Config() *config.Config { return r.cfg }

// Permissions exposes the permission broker.
func (r *Registry) Permissions() *permissionBroker { return r.perm }

// Attention exposes the once-per-wait notice gate the hooks feed.
func (r *Registry) Attention() *AttentionGate { return r.gate }

// Run scans until ctx is done.
func (r *Registry) Run(ctx context.Context) {
	r.scan(ctx)
	r.indexHistory()
	go r.accountsLoop(ctx)
	scanT := time.NewTicker(3 * time.Second)
	tailT := time.NewTicker(300 * time.Millisecond)
	paneT := time.NewTicker(250 * time.Millisecond)
	histT := time.NewTicker(60 * time.Second)
	defer scanT.Stop()
	defer tailT.Stop()
	defer paneT.Stop()
	defer histT.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-scanT.C:
			r.scan(ctx)
		case <-tailT.C:
			r.pumpAll()
		case <-paneT.C:
			r.pollPanes(ctx)
		case <-histT.C:
			r.indexHistory()
			r.gcFollowers()
		}
	}
}

// Sessions returns a sorted snapshot: running first, then by UpdatedAt desc.
func (r *Registry) Sessions() []Session {
	r.mu.RLock()
	defer r.mu.RUnlock()
	out := make([]Session, 0, len(r.sessions))
	for _, s := range r.sessions {
		out = append(out, *s)
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].Running != out[j].Running {
			return out[i].Running
		}
		return out[i].UpdatedAt.After(out[j].UpdatedAt)
	})
	return out
}

// Get returns one session.
func (r *Registry) Get(key string) (Session, bool) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	s, ok := r.sessions[key]
	if !ok {
		return Session{}, false
	}
	return *s, true
}

// upsert stores s and notifies listeners when it changed.
func (r *Registry) upsert(s Session) {
	r.mu.Lock()
	old, had := r.sessions[s.Key]
	changed := !had || *old != s
	cp := s
	r.sessions[s.Key] = &cp
	r.mu.Unlock()
	if had && old.Status != s.Status && s.Status == transcript.StatusBusy {
		// Back to work: the next idle, question or permission is news again.
		r.gate.Reset(s.Key)
	}
	if changed {
		r.each(func(l Listener) { l.SessionUpserted(s) })
	}
}

func (r *Registry) remove(key string) {
	r.mu.Lock()
	_, had := r.sessions[key]
	delete(r.sessions, key)
	r.mu.Unlock()
	r.gate.Forget(key)
	if had {
		r.each(func(l Listener) { l.SessionRemoved(key) })
	}
}

// ---- discovery ----

type liveProc struct {
	pane     tmux.Pane
	proc     tmux.Process
	provider string
}

func isClaude(p tmux.Process) bool {
	if p.Name == "claude" {
		return true
	}
	// Native install may run via node: "node /path/claude ..." or "claude-code".
	f := strings.Fields(p.Args)
	return len(f) >= 2 && (p.Name == "node" || p.Name == "bun") && strings.HasSuffix(f[1], "/claude")
}

func isCodex(p tmux.Process) bool {
	if p.Name == "codex" {
		return true
	}
	f := strings.Fields(p.Args)
	return len(f) >= 2 && p.Name == "node" && strings.HasSuffix(f[1], "/codex")
}

func (r *Registry) scan(ctx context.Context) {
	procs, err := tmux.Processes(ctx)
	if err != nil {
		r.log.Warn("process scan failed", "err", err)
		return
	}
	panes, err := r.tm.ListPanes(ctx)
	if err != nil && !errors.Is(err, tmux.ErrNoServer) {
		r.log.Debug("tmux list-panes", "err", err)
	}
	// Map CLI pid -> pane.
	byPID := map[int]liveProc{}
	for _, pn := range panes {
		for _, d := range append(tmux.Descendants(procs, pn.PID), procs[pn.PID]) {
			switch {
			case r.cfg.Claude.On() && isClaude(d):
				byPID[d.PID] = liveProc{pane: pn, proc: d, provider: "claude"}
			case r.cfg.Codex.On() && isCodex(d):
				byPID[d.PID] = liveProc{pane: pn, proc: d, provider: "codex"}
			}
		}
	}
	// CLI processes outside tmux are visible but not controllable.
	for pid, p := range procs {
		if _, ok := byPID[pid]; ok {
			continue
		}
		if r.cfg.Claude.On() && isClaude(p) {
			byPID[pid] = liveProc{proc: p, provider: "claude"}
		} else if r.cfg.Codex.On() && isCodex(p) {
			byPID[pid] = liveProc{proc: p, provider: "codex"}
		}
	}

	seen := map[string]bool{}
	r.mu.Lock()
	r.claudeProfiles = claude.Profiles(r.cfg.Profiles, procs)
	r.codexProfiles = codex.Profiles(r.cfg.Profiles, procs)
	cps, xps := r.claudeProfiles, r.codexProfiles
	r.mu.Unlock()

	if r.cfg.Claude.On() {
		claimed := map[int]bool{}
		for _, prof := range cps {
			agents, err := claude.Agents(ctx, r.cfg.Claude.Binary, prof.Dir)
			if err != nil {
				r.log.Debug("claude agents --json", "profile", prof.Dir, "err", err)
				continue
			}
			for _, a := range agents {
				if a.SessionID == "" {
					continue
				}
				path := claude.TranscriptPath(prof, a.Cwd, a.SessionID)
				s := Session{Key: "claude:" + a.SessionID, ID: a.SessionID, Provider: "claude", Cwd: a.Cwd, Repo: filepath.Base(a.Cwd), Profile: prof.Dir, TranscriptPath: path, Running: true, PID: a.PID, Kind: a.Kind, Title: a.Name}
				if a.StartedAt > 0 {
					s.StartedAt = time.UnixMilli(a.StartedAt)
				}
				switch a.Status {
				case "busy":
					s.Status = transcript.StatusBusy
				case "idle":
					s.Status = transcript.StatusIdle
				case "waiting":
					s.Status = transcript.StatusWaitingInput
				default:
					s.Status = transcript.StatusUnknown
				}
				if lp, ok := byPID[a.PID]; ok && lp.pane.PaneID != "" {
					s.PaneID, s.TmuxSession, s.Controllable = lp.pane.PaneID, lp.pane.SessionName, true
				}
				claimed[a.PID] = true
				r.finishLive(&s, path)
				seen[s.Key] = true
			}
		}
		// Claude processes not reported by `agents` (older builds): newest
		// transcript in the cwd's project dir modified after process start.
		for pid, lp := range byPID {
			if lp.provider != "claude" || claimed[pid] {
				continue
			}
			cwd := lp.pane.Path
			if cwd == "" {
				cwd = tmux.Cwd(pid)
			}
			started := tmux.StartTime(pid)
			for _, prof := range cps {
				dir := filepath.Join(prof.Projects, claude.EscapeCwd(cwd))
				m, _ := filepath.Glob(filepath.Join(dir, "*.jsonl"))
				var best string
				var bestT time.Time
				for _, p := range m {
					st, err := os.Stat(p)
					if err != nil || st.ModTime().Before(started.Add(-5*time.Second)) {
						continue
					}
					if st.ModTime().After(bestT) {
						best, bestT = p, st.ModTime()
					}
				}
				if best == "" {
					continue
				}
				id := strings.TrimSuffix(filepath.Base(best), ".jsonl")
				if seen["claude:"+id] {
					break
				}
				s := Session{Key: "claude:" + id, ID: id, Provider: "claude", Cwd: cwd, Repo: filepath.Base(cwd), Profile: prof.Dir, TranscriptPath: best, Running: true, PID: pid, Kind: "interactive", Status: transcript.StatusUnknown, StartedAt: started}
				if lp.pane.PaneID != "" {
					s.PaneID, s.TmuxSession, s.Controllable = lp.pane.PaneID, lp.pane.SessionName, true
				}
				r.finishLive(&s, best)
				seen[s.Key] = true
				break
			}
		}
	}
	if r.cfg.Codex.On() {
		for pid, lp := range byPID {
			if lp.provider != "codex" {
				continue
			}
			cwd := lp.pane.Path
			if cwd == "" {
				cwd = tmux.Cwd(pid)
			}
			started := tmux.StartTime(pid)
			for _, prof := range xps {
				path := codex.RolloutForPID(prof, pid, cwd, started)
				if path == "" {
					continue
				}
				id := codex.SessionIDFromFilename(filepath.Base(path))
				s := Session{Key: "codex:" + id, ID: id, Provider: "codex", Cwd: cwd, Repo: filepath.Base(cwd), Profile: prof.Dir, TranscriptPath: path, Running: true, PID: pid, Kind: "interactive", Status: transcript.StatusUnknown, StartedAt: started}
				if lp.pane.PaneID != "" {
					s.PaneID, s.TmuxSession, s.Controllable = lp.pane.PaneID, lp.pane.SessionName, true
				}
				r.finishLive(&s, path)
				seen[s.Key] = true
				break
			}
		}
	}
	// Sessions that were running and are gone: mark exited (keep in history).
	r.mu.RLock()
	var gone []Session
	var pendings []string
	for k, s := range r.sessions {
		if s.Pending {
			if time.Since(s.StartedAt) > 2*time.Minute {
				pendings = append(pendings, k)
			}
			continue
		}
		if s.Running && !seen[k] {
			cp := *s
			gone = append(gone, cp)
		}
	}
	r.mu.RUnlock()
	for _, s := range gone {
		s.Running, s.Controllable, s.PaneID, s.PID, s.Status = false, false, "", 0, transcript.StatusExited
		s.Question = nil
		r.upsert(s)
	}
	for _, k := range pendings {
		r.remove(k)
	}
	r.recoverQuestions(ctx)
}

// finishLive merges summary data and spawn bookkeeping into a live session
// and stores it.
func (r *Registry) finishLive(s *Session, path string) {
	r.mu.RLock()
	prev := r.sessions[s.Key]
	sp, spawnedHere := r.spawned[s.PaneID]
	acct := r.accts
	fl := r.followers[s.Key]
	r.mu.RUnlock()
	if prev != nil {
		s.Account, s.Title = prev.Account, firstNonEmpty(s.Title, prev.Title)
		s.Model, s.LastPrompt, s.Branch = prev.Model, prev.LastPrompt, prev.Branch
		if prev.Status == transcript.StatusWaitingPermission && s.Status == transcript.StatusBusy {
			s.Status = prev.Status
		}
		s.Spawned = prev.Spawned
		// The dialog stays until a hook or the transcript says it closed;
		// the CLI touches the file while one is open.
		if q := prev.Question; q != nil {
			s.Question, s.Status = q, transcript.StatusWaitingInput
		}
	}
	placeholder := ""
	if spawnedHere && sp.Provider == s.Provider {
		s.Spawned = true
		placeholder = s.Provider + ":pending:" + s.PaneID
		r.mu.Lock()
		delete(r.spawned, s.PaneID)
		r.mu.Unlock()
	}
	if s.Account == "" {
		s.Account = r.accountFor(s.Provider, acct)
	}
	if path != "" {
		if sum, ok := r.summarize(s.Provider, path); ok {
			if s.Title == "" || s.Title == s.ID {
				s.Title = sum.Title
			}
			s.LastPrompt, s.Branch, s.Size = sum.LastPrompt, sum.Branch, sum.Size
			if s.Model == "" {
				s.Model = sum.Model
			}
			if s.StartedAt.IsZero() {
				s.StartedAt = sum.StartedAt
			}
			s.UpdatedAt = sum.UpdatedAt
			if s.Cwd == "" {
				s.Cwd, s.Repo = sum.Cwd, filepath.Base(sum.Cwd)
			}
		}
	}
	if fl != nil {
		if s.Provider == "codex" && (s.Status == transcript.StatusUnknown) {
			s.Status = fl.status
		}
		if fl.model != "" {
			s.Model = fl.model
		}
	}
	if s.UpdatedAt.IsZero() {
		if prev != nil && !prev.UpdatedAt.IsZero() {
			s.UpdatedAt = prev.UpdatedAt
		} else {
			s.UpdatedAt = s.StartedAt
		}
		if s.UpdatedAt.IsZero() {
			s.UpdatedAt = time.Now()
		}
	}
	r.upsert(*s)
	if placeholder != "" {
		// The real session is in place; tell clients, then drop the placeholder.
		r.each(func(l Listener) { l.SessionReplaced(placeholder, s.Key) })
		r.remove(placeholder)
	}
}

func (r *Registry) accountFor(prov string, a AccountsSnapshot) string {
	switch prov {
	case "claude":
		if cs, ok := a.Claude.(*cswap.Snapshot); ok && cs != nil {
			return cs.Active
		}
	case "codex":
		if a.Codex != nil {
			return a.Codex.Email
		}
	}
	return ""
}

func firstNonEmpty(ss ...string) string {
	for _, s := range ss {
		if s != "" {
			return s
		}
	}
	return ""
}

// summarize caches transcript summaries by (size, mtime).
func (r *Registry) summarize(prov, path string) (Session, bool) {
	st, err := os.Stat(path)
	if err != nil {
		return Session{}, false
	}
	r.mu.RLock()
	e, ok := r.summaries[path]
	r.mu.RUnlock()
	if ok && e.size == st.Size() && e.mtime.Equal(st.ModTime()) {
		return e.sess, true
	}
	var s Session
	if prov == "codex" {
		in, err := codex.Summarize(path)
		if err != nil {
			return Session{}, false
		}
		s = Session{ID: in.SessionID, Provider: "codex", Title: in.Title, Cwd: in.Cwd, Branch: in.GitBranch, LastPrompt: in.LastPrompt, Model: in.Model, StartedAt: in.StartedAt, UpdatedAt: in.UpdatedAt, Size: in.Size}
	} else {
		in, err := claude.Summarize(path)
		if err != nil {
			return Session{}, false
		}
		s = Session{ID: in.SessionID, Provider: "claude", Title: in.Title, Cwd: in.Cwd, Branch: in.GitBranch, LastPrompt: in.LastPrompt, Model: in.Model, StartedAt: in.StartedAt, UpdatedAt: in.UpdatedAt, Size: in.Size, Sidechain: in.Sidechain}
	}
	s.Key = s.Provider + ":" + s.ID
	s.Repo = filepath.Base(s.Cwd)
	s.TranscriptPath = path
	r.mu.Lock()
	r.summaries[path] = summaryEntry{size: st.Size(), mtime: st.ModTime(), sess: s}
	r.mu.Unlock()
	return s, true
}

// indexHistory lists past transcripts (bounded) so the app can browse them.
func (r *Registry) indexHistory() {
	const maxPerProfile = 300
	r.mu.RLock()
	cps, xps := r.claudeProfiles, r.codexProfiles
	r.mu.RUnlock()
	for _, prof := range cps {
		infos, err := claude.ListTranscripts(prof, 2048)
		if err != nil {
			continue
		}
		if len(infos) > maxPerProfile {
			infos = infos[:maxPerProfile]
		}
		for _, in := range infos {
			key := "claude:" + in.SessionID
			if cur, ok := r.Get(key); ok && cur.Running {
				continue
			}
			s, ok := r.summarize("claude", in.Path)
			if !ok || s.Sidechain {
				continue
			}
			s.Profile = prof.Dir
			s.Status = transcript.StatusExited
			if prev, ok := r.Get(key); ok {
				s.Account, s.Spawned = prev.Account, prev.Spawned
			}
			r.upsert(s)
		}
	}
	for _, prof := range xps {
		infos, err := codex.ListRollouts(prof, 2048)
		if err != nil {
			continue
		}
		if len(infos) > maxPerProfile {
			infos = infos[:maxPerProfile]
		}
		for _, in := range infos {
			key := "codex:" + in.SessionID
			if cur, ok := r.Get(key); ok && cur.Running {
				continue
			}
			s, ok := r.summarize("codex", in.Path)
			if !ok {
				continue
			}
			s.Profile = prof.Dir
			s.Status = transcript.StatusExited
			if prev, ok := r.Get(key); ok {
				s.Account, s.Spawned = prev.Account, prev.Spawned
			}
			r.upsert(s)
		}
	}
}

// ---- following ----

// Subscribe starts streaming a session's transcript. It returns the current
// tail of events so the client can render immediately.
func (r *Registry) Subscribe(key string, before int64, limit int) ([]transcript.Event, bool, error) {
	s, ok := r.Get(key)
	if !ok {
		return nil, false, errors.New("unknown session")
	}
	if s.TranscriptPath == "" {
		return nil, false, errors.New("session has no transcript yet")
	}
	r.mu.Lock()
	f := r.followers[key]
	if f == nil {
		f = newFollower(key, s.Provider, s.TranscriptPath)
		r.followers[key] = f
	}
	r.subs[key]++
	r.mu.Unlock()
	if _, err := f.pump(); err != nil {
		return nil, false, err
	}
	evs, more := f.page(before, limit)
	return evs, more, nil
}

// Unsubscribe decrements the subscriber count; followers are GC'd later.
func (r *Registry) Unsubscribe(key string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.subs[key] > 0 {
		r.subs[key]--
	}
}

// History pages older events for a session (subscribed or not).
func (r *Registry) History(key string, before int64, limit int) ([]transcript.Event, bool, error) {
	s, ok := r.Get(key)
	if !ok || s.TranscriptPath == "" {
		return nil, false, errors.New("unknown session")
	}
	r.mu.Lock()
	f := r.followers[key]
	if f == nil {
		f = newFollower(key, s.Provider, s.TranscriptPath)
		r.followers[key] = f
	}
	r.mu.Unlock()
	if _, err := f.pump(); err != nil {
		return nil, false, err
	}
	evs, more := f.page(before, limit)
	return evs, more, nil
}

func (r *Registry) pumpAll() {
	r.mu.RLock()
	fs := make([]*follower, 0, len(r.followers))
	for k, f := range r.followers {
		if r.subs[k] > 0 || (r.sessions[k] != nil && r.sessions[k].Running) {
			fs = append(fs, f)
		}
	}
	r.mu.RUnlock()
	for _, f := range fs {
		fresh, err := f.pump()
		if err != nil {
			continue
		}
		if len(fresh) == 0 {
			continue
		}
		r.mu.RLock()
		subscribed := r.subs[f.key] > 0
		r.mu.RUnlock()
		if subscribed {
			r.each(func(l Listener) { l.Events(f.key, fresh) })
		}
		// Reflect transcript-derived state on the session card.
		if s, ok := r.Get(f.key); ok {
			changed := false
			for _, ev := range fresh {
				switch ev.Type {
				case transcript.TypeStatus:
					if s.Provider == "codex" && s.Running && ev.Status != "" {
						s.Status, changed = ev.Status, true
					}
				case transcript.TypeMeta:
					if t, ok := ev.Meta["title"].(string); ok && t != "" {
						s.Title, changed = t, true
					}
					if lp, ok := ev.Meta["last_prompt"].(string); ok && lp != "" {
						s.LastPrompt, changed = firstLine(lp, 120), true
					}
				case transcript.TypeUser:
					s.LastPrompt, changed = firstLine(ev.Text, 120), true
				case transcript.TypeModelSwitch:
					s.Model, changed = ev.Model, true
				case transcript.TypeUsage:
					if ev.Usage != nil && ev.Usage.RateLimits != nil && s.Provider == "codex" {
						r.setCodexLimits(ev.Usage.RateLimits, ev.TS)
					}
				}
				if ev.Model != "" && ev.Model != s.Model {
					s.Model, changed = ev.Model, true
				}
			}
			if q := s.Question; q != nil && questionClosedBy(fresh, q.SetAt) {
				s.Question, changed = nil, true
				if s.Status == transcript.StatusWaitingInput {
					s.Status = transcript.StatusBusy
				}
			}
			if changed {
				s.UpdatedAt = time.Now()
				r.upsert(s)
			}
		}
	}
}

// questionClosedBy reports whether evs show the transcript moving on after
// a dialog opened at setAt: the CLI writes nothing while it is open, so a
// result or a new turn stamped later means it closed.
func questionClosedBy(evs []transcript.Event, setAt time.Time) bool {
	for _, ev := range evs {
		if ev.Sidechain || !ev.TS.After(setAt) {
			continue
		}
		switch ev.Type {
		case transcript.TypeToolResult, transcript.TypeUser, transcript.TypeText, transcript.TypeThinking, transcript.TypeCompact:
			return true
		}
	}
	return false
}

// SetQuestion records a pending AskUserQuestion dialog for a session and
// raises an input notice. A repeat of the same dialog keeps its id.
func (r *Registry) SetQuestion(key string, items []QuestionItem) *Question {
	s, ok := r.Get(key)
	if !ok || len(items) == 0 {
		return nil
	}
	if s.Question != nil && sameQuestions(s.Question.Questions, items) {
		return s.Question
	}
	q := &Question{ID: newQuestionID(), Questions: items, SetAt: time.Now()}
	s.Question, s.Status, s.UpdatedAt = q, transcript.StatusWaitingInput, time.Now()
	r.upsert(s)
	r.log.Info("question pending", "session", key, "id", q.ID, "questions", len(items))
	r.gate.Question(key, questionText(q))
	return q
}

// ClearQuestion drops the pending question; id "" matches any.
func (r *Registry) ClearQuestion(key, id string) {
	s, ok := r.Get(key)
	if !ok || s.Question == nil || (id != "" && s.Question.ID != id) {
		return
	}
	s.Question, s.UpdatedAt = nil, time.Now()
	if s.Status == transcript.StatusWaitingInput {
		s.Status = transcript.StatusBusy
	}
	r.upsert(s)
	// Answered or gone: the next notice starts a new wait.
	r.gate.Reset(key)
}

func sameQuestions(a, b []QuestionItem) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i].Question != b[i].Question || a[i].Header != b[i].Header || a[i].MultiSelect != b[i].MultiSelect || len(a[i].Options) != len(b[i].Options) {
			return false
		}
		for j := range a[i].Options {
			if a[i].Options[j] != b[i].Options[j] {
				return false
			}
		}
	}
	return true
}

// questionText is the one-line summary of a pending question for notices.
func questionText(q *Question) string {
	if q == nil || len(q.Questions) == 0 {
		return ""
	}
	return firstLine(firstNonEmpty(q.Questions[0].Question, q.Questions[0].Header), 120)
}

func (r *Registry) gcFollowers() {
	r.mu.Lock()
	defer r.mu.Unlock()
	for k, f := range r.followers {
		s := r.sessions[k]
		if r.subs[k] == 0 && (s == nil || !s.Running) && time.Since(f.lastUse) > 5*time.Minute {
			delete(r.followers, k)
		}
	}
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

// ---- panes ----

// SubscribePane starts screen polling for a session's pane.
func (r *Registry) SubscribePane(ctx context.Context, key string) (*tmux.Screen, error) {
	s, ok := r.Get(key)
	if !ok || s.PaneID == "" {
		return nil, errors.New("session has no controllable pane")
	}
	r.mu.Lock()
	r.paneSubs[key]++
	r.mu.Unlock()
	return r.tm.Capture(ctx, s.PaneID, 200)
}

// UnsubscribePane stops polling when the last subscriber leaves.
func (r *Registry) UnsubscribePane(key string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.paneSubs[key] > 0 {
		r.paneSubs[key]--
	}
	if r.paneSubs[key] == 0 {
		delete(r.paneHash, key)
	}
}

func (r *Registry) pollPanes(ctx context.Context) {
	r.mu.RLock()
	type target struct{ key, pane string }
	var ts []target
	for k, n := range r.paneSubs {
		if n > 0 && r.sessions[k] != nil && r.sessions[k].PaneID != "" {
			ts = append(ts, target{k, r.sessions[k].PaneID})
		}
	}
	r.mu.RUnlock()
	for _, t := range ts {
		scr, err := r.tm.Capture(ctx, t.pane, 200)
		if err != nil {
			continue
		}
		h := fnv.New64a()
		for _, l := range scr.Lines {
			h.Write([]byte(l))
			h.Write([]byte{0})
		}
		fmt.Fprintf(h, "%d,%d", scr.CursorX, scr.CursorY)
		sum := h.Sum64()
		r.mu.Lock()
		changed := r.paneHash[t.key] != sum
		r.paneHash[t.key] = sum
		r.mu.Unlock()
		if changed {
			r.each(func(l Listener) { l.Pane(t.key, scr) })
		}
	}
}

// ---- control ----

// SendText types text into a session's pane.
func (r *Registry) SendText(ctx context.Context, key, text string, enter bool) error {
	s, ok := r.Get(key)
	if !ok || !s.Controllable {
		return errors.New("session is not controllable")
	}
	r.log.Info("input", "session", key, "bytes", len(text), "enter", enter)
	return r.tm.SendText(ctx, s.PaneID, text, enter)
}

// SendKeys presses keys in a session's pane.
func (r *Registry) SendKeys(ctx context.Context, key string, keys []string) error {
	s, ok := r.Get(key)
	if !ok || !s.Controllable {
		return errors.New("session is not controllable")
	}
	r.log.Info("keys", "session", key, "keys", keys)
	return r.tm.SendKeys(ctx, s.PaneID, keys)
}

// SpawnRequest describes a new or resumed session.
type SpawnRequest struct {
	Provider string `json:"provider"` // claude|codex
	Dir      string `json:"dir"`
	Resume   string `json:"resume,omitempty"` // session id to resume
	Prompt   string `json:"prompt,omitempty"`
	// Extra CLI flags from a small allowlist (e.g. "--permission-mode plan").
	PermissionMode string `json:"permission_mode,omitempty"`
	Model          string `json:"model,omitempty"`
}

var safeArg = func(s string) bool {
	if s == "" || len(s) > 64 {
		return false
	}
	for _, c := range s {
		if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '-' || c == '_' || c == '.' || c == ':' || c == '[' || c == ']') {
			return false
		}
	}
	return true
}

// Spawn starts a CLI inside a new tmux session in a workspace directory and
// returns the placeholder session the app can subscribe to.
func (r *Registry) Spawn(ctx context.Context, req SpawnRequest) (Session, error) {
	if req.Provider != "claude" && req.Provider != "codex" {
		return Session{}, errors.New("provider must be claude or codex")
	}
	if req.Provider == "claude" && !r.cfg.Claude.On() || req.Provider == "codex" && !r.cfg.Codex.On() {
		return Session{}, errors.New("provider disabled")
	}
	dir, err := r.insideWorkspace(req.Dir)
	if err != nil {
		return Session{}, err
	}
	var argv []string
	if req.Provider == "claude" {
		argv = []string{firstNonEmpty(r.cfg.Claude.Binary, "claude")}
		if req.Resume != "" {
			if !safeArg(req.Resume) {
				return Session{}, errors.New("bad resume id")
			}
			argv = append(argv, "--resume", req.Resume)
		}
		if req.PermissionMode != "" {
			if !safeArg(req.PermissionMode) {
				return Session{}, errors.New("bad permission mode")
			}
			argv = append(argv, "--permission-mode", req.PermissionMode)
		}
		if req.Model != "" {
			if !safeArg(req.Model) {
				return Session{}, errors.New("bad model")
			}
			argv = append(argv, "--model", req.Model)
		}
		if req.Prompt != "" {
			argv = append(argv, "--", req.Prompt)
		}
	} else {
		argv = []string{firstNonEmpty(r.cfg.Codex.Binary, "codex")}
		if req.Resume != "" {
			if !safeArg(req.Resume) {
				return Session{}, errors.New("bad resume id")
			}
			argv = append(argv, "resume", req.Resume)
		} else {
			if req.Model != "" {
				if !safeArg(req.Model) {
					return Session{}, errors.New("bad model")
				}
				argv = append(argv, "--model", req.Model)
			}
			if req.Prompt != "" {
				argv = append(argv, "--", req.Prompt)
			}
		}
	}
	var rnd [4]byte
	_, _ = rand.Read(rnd[:])
	name := fmt.Sprintf("%s-%s-%s", firstNonEmpty(r.cfg.Tmux.SessionPrefix, "ph"), req.Provider, hex.EncodeToString(rnd[:]))
	pane, err := r.tm.NewSession(ctx, name, dir, argv, nil)
	if err != nil {
		return Session{}, err
	}
	r.log.Info("spawned", "provider", req.Provider, "dir", dir, "tmux", name, "pane", pane)
	ph := Session{Key: req.Provider + ":pending:" + pane, ID: "pending", Provider: req.Provider, Cwd: dir, Repo: filepath.Base(dir), Status: transcript.StatusBusy, Running: true, Controllable: true, PaneID: pane, TmuxSession: name, StartedAt: time.Now(), UpdatedAt: time.Now(), Spawned: true, Pending: true, Title: "Starting " + req.Provider + "…"}
	r.mu.Lock()
	r.spawned[pane] = spawnInfo{Provider: req.Provider, TmuxSession: name, Dir: dir, At: time.Now()}
	r.mu.Unlock()
	r.upsert(ph)
	return ph, nil
}

// insideWorkspace resolves dir and checks the app may start sessions there:
// under a configured workspace, inside an added repository, or exactly a
// directory an agent session has already run in (a "recent" repository).
func (r *Registry) insideWorkspace(dir string) (string, error) {
	real, err := filepath.EvalSymlinks(config.Expand(dir))
	if err != nil {
		return "", fmt.Errorf("directory: %w", err)
	}
	st, err := os.Stat(real)
	if err != nil || !st.IsDir() {
		return "", errors.New("not a directory")
	}
	workspaces, repos := r.Dirs()
	for _, w := range append(workspaces, repos...) {
		wr, err := filepath.EvalSymlinks(w)
		if err != nil {
			continue
		}
		if real == wr || strings.HasPrefix(real, wr+string(filepath.Separator)) {
			return real, nil
		}
	}
	for _, s := range r.Sessions() {
		if s.Cwd == "" {
			continue
		}
		if cr, err := filepath.EvalSymlinks(s.Cwd); err == nil && cr == real {
			return real, nil
		}
	}
	if len(workspaces) == 0 && len(repos) == 0 {
		return "", errors.New("no repositories configured: run `porthole add` inside the repository")
	}
	return "", errors.New("directory is outside configured repositories (run `porthole add` there)")
}

// Repo is a git repository the app can start sessions in.
type Repo struct {
	Name      string `json:"name"`
	Path      string `json:"path"`
	Workspace string `json:"workspace,omitempty"`
	// Source is "workspace" (found by scanning), "repo" (added explicitly)
	// or "recent" (an agent session has run there).
	Source   string    `json:"source"`
	Branch   string    `json:"branch,omitempty"`
	LastUsed time.Time `json:"last_used,omitempty"`
	LastProv string    `json:"last_provider,omitempty"`
}

// Repos lists explicit repositories, git repositories under each workspace
// (two levels deep), and the directories of known sessions, most recently
// used first.
func (r *Registry) Repos() []Repo {
	var out []Repo
	last := map[string]Session{}
	for _, s := range r.Sessions() {
		if s.Cwd == "" {
			continue
		}
		if p, ok := last[s.Cwd]; !ok || s.UpdatedAt.After(p.UpdatedAt) {
			last[s.Cwd] = s
		}
	}
	seen := map[string]bool{}
	add := func(dir, workspace, source string) {
		if seen[dir] {
			return
		}
		if _, err := os.Stat(filepath.Join(dir, ".git")); err != nil {
			return
		}
		seen[dir] = true
		rp := Repo{Name: filepath.Base(dir), Path: dir, Workspace: workspace, Source: source, Branch: gitBranch(dir)}
		if s, ok := last[dir]; ok {
			rp.LastUsed, rp.LastProv = s.UpdatedAt, s.Provider
		}
		out = append(out, rp)
	}
	workspaces, repos := r.Dirs()
	for _, p := range repos {
		if real, err := filepath.EvalSymlinks(p); err == nil {
			add(real, "", "repo")
		}
	}
	for _, w := range workspaces {
		root, err := filepath.EvalSymlinks(w)
		if err != nil {
			continue
		}
		add(root, w, "workspace")
		l1, _ := os.ReadDir(root)
		for _, d := range l1 {
			if !d.IsDir() || strings.HasPrefix(d.Name(), ".") {
				continue
			}
			p1 := filepath.Join(root, d.Name())
			add(p1, w, "workspace")
			if seen[p1] {
				continue
			}
			l2, _ := os.ReadDir(p1)
			for _, d2 := range l2 {
				if d2.IsDir() && !strings.HasPrefix(d2.Name(), ".") {
					add(filepath.Join(p1, d2.Name()), w, "workspace")
				}
			}
		}
	}
	for cwd := range last {
		if real, err := filepath.EvalSymlinks(cwd); err == nil {
			add(real, "", "recent")
		}
	}
	sort.Slice(out, func(i, j int) bool {
		if !out[i].LastUsed.Equal(out[j].LastUsed) {
			return out[i].LastUsed.After(out[j].LastUsed)
		}
		return out[i].Name < out[j].Name
	})
	return out
}

func gitBranch(dir string) string {
	b, err := os.ReadFile(filepath.Join(dir, ".git", "HEAD"))
	if err != nil {
		// Worktrees: .git is a file pointing at the gitdir.
		if gd, err2 := os.ReadFile(filepath.Join(dir, ".git")); err2 == nil {
			line := strings.TrimSpace(string(gd))
			if strings.HasPrefix(line, "gitdir: ") {
				b, err = os.ReadFile(filepath.Join(strings.TrimPrefix(line, "gitdir: "), "HEAD"))
			}
		}
		if err != nil {
			return ""
		}
	}
	s := strings.TrimSpace(string(b))
	if strings.HasPrefix(s, "ref: refs/heads/") {
		return strings.TrimPrefix(s, "ref: refs/heads/")
	}
	if len(s) >= 7 {
		return s[:7]
	}
	return s
}

// Skills lists slash commands for a provider, merged across profiles.
func (r *Registry) Skills(prov, repo string) []provider.Skill {
	r.mu.RLock()
	cps, xps := r.claudeProfiles, r.codexProfiles
	r.mu.RUnlock()
	if repo != "" {
		if real, err := r.insideWorkspace(repo); err == nil {
			repo = real
		} else {
			repo = ""
		}
	}
	var out []provider.Skill
	if prov == "" || prov == "claude" {
		for _, p := range cps {
			out = append(out, claude.Skills(p.Dir, repo)...)
		}
	}
	if prov == "" || prov == "codex" {
		for _, p := range xps {
			out = append(out, codex.Skills(p.Dir, repo)...)
		}
	}
	return provider.Dedupe(out)
}

// ---- accounts ----

// Accounts returns the latest account snapshot.
func (r *Registry) Accounts() AccountsSnapshot {
	r.acctMu.RLock()
	defer r.acctMu.RUnlock()
	return r.accts
}

func (r *Registry) setCodexLimits(rl *transcript.RateLimits, at time.Time) {
	r.acctMu.Lock()
	if r.accts.Codex == nil {
		r.accts.Codex = &Codex{}
	}
	if at.IsZero() {
		at = time.Now()
	}
	if r.accts.Codex.SeenAt.After(at) {
		r.acctMu.Unlock()
		return
	}
	r.accts.Codex.RateLimits, r.accts.Codex.SeenAt = rl, at
	snap := r.accts
	r.acctMu.Unlock()
	r.each(func(l Listener) { l.AccountsUpdated(snap) })
}

func (r *Registry) accountsLoop(ctx context.Context) {
	interval := time.Duration(r.cfg.Cswap.PollIntervalS) * time.Second
	if interval < 60*time.Second {
		interval = 60 * time.Second
	}
	refresh := func() {
		changed := false
		r.acctMu.Lock()
		if r.cfg.Cswap.On() && r.cs.Available() {
			if snap, err := r.cs.List(ctx); err == nil {
				r.accts.Claude = snap
				changed = true
			} else {
				r.log.Debug("cswap list", "err", err)
			}
		}
		r.mu.RLock()
		xps := r.codexProfiles
		r.mu.RUnlock()
		if len(xps) > 0 {
			if r.accts.Codex == nil {
				r.accts.Codex = &Codex{}
			}
			if e := codex.AccountEmail(xps[0].Dir); e != "" && e != r.accts.Codex.Email {
				r.accts.Codex.Email = e
				changed = true
			}
		}
		r.accts.FetchedAt = time.Now()
		snap := r.accts
		r.acctMu.Unlock()
		if changed {
			r.each(func(l Listener) { l.AccountsUpdated(snap) })
		}
	}
	refresh()
	t := time.NewTicker(interval)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			refresh()
		}
	}
}

// RefreshAccounts triggers an out-of-band account refresh (e.g. on a model
// switch hook). cswap itself rate-limits the network, so this is cheap.
func (r *Registry) RefreshAccounts(ctx context.Context) {
	if !(r.cfg.Cswap.On() && r.cs.Available()) {
		return
	}
	snap, err := r.cs.List(ctx)
	if err != nil {
		return
	}
	r.acctMu.Lock()
	r.accts.Claude = snap
	r.accts.FetchedAt = time.Now()
	cp := r.accts
	r.acctMu.Unlock()
	r.each(func(l Listener) { l.AccountsUpdated(cp) })
}

// SetStatus overrides a session's status (used by hooks). A status other
// than waiting_input means the dialog, if any, is gone.
func (r *Registry) SetStatus(key, status string) {
	s, ok := r.Get(key)
	if !ok {
		return
	}
	s.Status = status
	if status != transcript.StatusWaitingInput {
		s.Question = nil
	}
	s.UpdatedAt = time.Now()
	r.upsert(s)
}

// FindByTranscript maps a hook's transcript_path to a session key, resolving
// symlinks so profile aliases match.
func (r *Registry) FindByTranscript(path string) (Session, bool) {
	real, err := filepath.EvalSymlinks(path)
	if err != nil {
		real = path
	}
	r.mu.RLock()
	defer r.mu.RUnlock()
	for _, s := range r.sessions {
		if s.TranscriptPath == "" {
			continue
		}
		sr, err := filepath.EvalSymlinks(s.TranscriptPath)
		if err != nil {
			sr = s.TranscriptPath
		}
		if sr == real {
			return *s, true
		}
	}
	return Session{}, false
}

// RegisterFromHook creates a session entry when a hook arrives for a
// transcript the scanner has not seen yet (e.g. first seconds of a session).
func (r *Registry) RegisterFromHook(prov, sessionID, transcriptPath, cwd string) Session {
	if s, ok := r.FindByTranscript(transcriptPath); ok {
		return s
	}
	s := Session{Key: prov + ":" + sessionID, ID: sessionID, Provider: prov, Cwd: cwd, Repo: filepath.Base(cwd), TranscriptPath: transcriptPath, Running: true, Status: transcript.StatusBusy, StartedAt: time.Now(), UpdatedAt: time.Now(), Kind: "interactive"}
	if sum, ok := r.summarize(prov, transcriptPath); ok {
		s.Title, s.Branch, s.Model = sum.Title, sum.Branch, sum.Model
	}
	r.upsert(s)
	return s
}
