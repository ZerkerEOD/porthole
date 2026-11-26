package core

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/ZerkerEOD/porthole/daemon/internal/config"
	"github.com/ZerkerEOD/porthole/daemon/internal/transcript"
)

// Run states.
const (
	RunRunning = "running"
	RunDone    = "done"
	RunStopped = "stopped"
)

// Limits and timings of commands run in a window.
const (
	maxRunCommand   = 4 * 1024
	maxRunsPerSess  = 4
	runTailLines    = 40
	runTailBytes    = 8 * 1024
	runFeedLines    = 120
	runReadBytes    = 256 * 1024
	runStopGrace    = 5 * time.Second
	runKillAfterEnd = 10 * time.Minute
)

// Run is a shell command started from the app in its own tmux window next
// to a session's pane. Its output goes to a log file the daemon tails.
type Run struct {
	Key       string    `json:"key"`
	ID        string    `json:"id"`
	Command   string    `json:"command"`
	State     string    `json:"state"` // running|done|stopped
	Exit      *int      `json:"exit,omitempty"`
	Tail      string    `json:"tail"`
	StartedAt time.Time `json:"started_at"`
	EndedAt   time.Time `json:"ended_at,omitzero"`
	// Fed is set once the output was typed into the session; Queued when
	// that happened while the session was busy, so the CLI takes it as the
	// next turn.
	Fed    bool   `json:"fed"`
	Queued bool   `json:"queued"`
	PaneID string `json:"pane_id"`
	Device string `json:"device"`
	// Recovered marks a run the daemon read back from disk after a restart.
	Recovered bool `json:"recovered,omitempty"`
}

// runState is the registry's bookkeeping for one run.
type runState struct {
	run      Run
	feed     bool
	logPath  string
	stopAt   time.Time // when Stop was asked; zero if never
	size     int64
	mtime    time.Time
	quit     chan struct{}
	quitOnce sync.Once
	kill     *time.Timer // closes the window of a finished run
	// feedSettled is set once feeding the output ended, fed or given up,
	// so a restart does not try again; feeding guards against two feeds
	// of one run in this process.
	feedSettled bool
	feeding     bool
}

func (st *runState) close() {
	st.quitOnce.Do(func() { close(st.quit) })
	if st.kill != nil {
		st.kill.Stop()
	}
}

// runScript is the sh program each run window executes. The command and
// the log path arrive as positional parameters ($1, $2), never spliced into
// the script, so the command text is interpreted once, by the inner sh.
//
// POSIX sh has no PIPESTATUS, so the command's own status is written to
// "$2.rc" from inside the pipeline and read back for the final "[exit N]"
// line. Both shells trap SIGINT (a trapped signal is reset to the default
// in children, unlike an ignored one), so Ctrl-C stops the command but not
// the bookkeeping; tee -i keeps the log open through it.
const runScript = `trap : INT; { trap : INT; sh -c "$1"; echo "$?" > "$2.rc"; } 2>&1 | tee -i "$2"; rc=$(cat "$2.rc" 2>/dev/null); printf '\n[exit %s]\n' "${rc:-255}" | tee -i -a "$2"`

// runArgv is the window's argv for command, logging to logPath.
func runArgv(command, logPath string) []string {
	return []string{"sh", "-c", runScript, "porthole-run", command, logPath}
}

var exitLineRe = regexp.MustCompile(`^\[exit (-?[0-9]{1,5})\]$`)

// parseExit reads the exit status from the final non-empty line of a log.
func parseExit(log []byte) (int, bool) {
	t := bytes.TrimRight(log, "\r\n\t ")
	if i := bytes.LastIndexByte(t, '\n'); i >= 0 {
		t = t[i+1:]
	}
	m := exitLineRe.FindSubmatch(bytes.TrimSpace(t))
	if m == nil {
		return 0, false
	}
	n, err := strconv.Atoi(string(m[1]))
	return n, err == nil
}

// stripExit drops the final "[exit N]" line and the blank line before it.
func stripExit(log string) string {
	t := strings.TrimRight(log, "\r\n\t ")
	i := strings.LastIndexByte(t, '\n')
	if i >= 0 && exitLineRe.MatchString(strings.TrimSpace(t[i+1:])) {
		return strings.TrimRight(t[:i], "\r\n")
	}
	if i < 0 && exitLineRe.MatchString(strings.TrimSpace(t)) {
		return ""
	}
	return strings.TrimRight(log, "\r\n")
}

// tailLines returns the last n lines of s, then keeps at most max bytes
// from the end (cut on a rune boundary).
func tailLines(s string, n, max int) string {
	s = strings.TrimRight(s, "\r\n")
	idx := len(s)
	for i := 0; i < n; i++ {
		j := strings.LastIndexByte(s[:idx], '\n')
		if j < 0 {
			idx = -1
			break
		}
		idx = j
	}
	out := s[idx+1:]
	if len(out) > max {
		cut := len(out) - max
		for cut < len(out) && (out[cut]&0xC0) == 0x80 {
			cut++
		}
		out = out[cut:]
	}
	return out
}

// feedText is the message typed into the session when a fed run exits.
func feedText(command, output string, exit int) string {
	body := "$ " + command
	if output != "" {
		body += "\n" + output
	}
	body += "\n[exit " + strconv.Itoa(exit) + "]"
	fence := "```"
	for strings.Contains(body, fence) {
		fence += "`"
	}
	return "I ran this in a separate window:\n" + fence + "\n" + body + "\n" + fence
}

// readTail returns up to max bytes from the end of the file.
func readTail(path string, max int64) ([]byte, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	fi, err := f.Stat()
	if err != nil {
		return nil, err
	}
	off := fi.Size() - max
	if off < 0 {
		off = 0
	}
	if _, err := f.Seek(off, io.SeekStart); err != nil {
		return nil, err
	}
	b, err := io.ReadAll(f)
	if err != nil {
		return nil, err
	}
	if off > 0 {
		// Drop the partial first line.
		if i := bytes.IndexByte(b, '\n'); i >= 0 {
			b = b[i+1:]
		}
	}
	return b, nil
}

// pruneRunLogs deletes run logs (and leftover status files) older than age,
// which a restarted daemon no longer tracks.
func pruneRunLogs(dir string, age time.Duration) {
	ents, err := os.ReadDir(dir)
	if err != nil {
		return
	}
	cutoff := time.Now().Add(-age)
	for _, e := range ents {
		n := e.Name()
		if e.IsDir() || !(strings.HasSuffix(n, ".log") || strings.HasSuffix(n, ".log.rc")) {
			continue
		}
		if fi, err := e.Info(); err == nil && fi.ModTime().Before(cutoff) {
			_ = os.Remove(filepath.Join(dir, n))
		}
	}
}

func newRunID() string {
	var b [4]byte
	_, _ = rand.Read(b[:])
	return hex.EncodeToString(b[:])
}

func (r *Registry) runsDir() string {
	if r.runDir != "" {
		return r.runDir
	}
	return filepath.Join(config.StateDir(), "runs")
}

// RunCommand starts command in a new window of the session's tmux session,
// in the session's working directory. With feed set, the output is typed
// into the session as a message when the command exits.
func (r *Registry) RunCommand(ctx context.Context, key, command string, feed bool, device string) (Run, error) {
	s, ok := r.Get(key)
	if !ok {
		return Run{}, errors.New("unknown session")
	}
	if !s.Controllable || s.TmuxSession == "" {
		return Run{}, errors.New("session is not controllable")
	}
	if strings.TrimSpace(command) == "" {
		return Run{}, errors.New("empty command")
	}
	if len(command) > maxRunCommand {
		return Run{}, errors.New("command too long")
	}
	// Starts are serialised so two arriving together cannot both pass the
	// per-session limit.
	r.runStartMu.Lock()
	defer r.runStartMu.Unlock()
	r.runsMu.Lock()
	running := 0
	for _, st := range r.runs[key] {
		if st.run.State == RunRunning {
			running++
		}
	}
	r.runsMu.Unlock()
	if running >= maxRunsPerSess {
		return Run{}, fmt.Errorf("at most %d commands may run at once in a session", maxRunsPerSess)
	}
	dir := r.runsDir()
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return Run{}, err
	}
	pruneRunLogs(dir, 7*24*time.Hour)
	id := newRunID()
	logPath := filepath.Join(dir, id+".log")
	f, err := os.OpenFile(logPath, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o600)
	if err != nil {
		return Run{}, err
	}
	f.Close()
	cwd := s.Cwd
	if st, err := os.Stat(cwd); cwd == "" || err != nil || !st.IsDir() {
		cwd = dir
	}
	pane, err := r.tm.NewWindow(ctx, s.TmuxSession, runWindowPrefix+id, cwd, runArgv(command, logPath))
	if err != nil {
		_ = os.Remove(logPath)
		return Run{}, err
	}
	st := &runState{
		run:     Run{Key: key, ID: id, Command: command, State: RunRunning, StartedAt: time.Now(), PaneID: pane, Device: device},
		feed:    feed,
		logPath: logPath,
		quit:    make(chan struct{}),
	}
	r.runsMu.Lock()
	if r.runs[key] == nil {
		r.runs[key] = map[string]*runState{}
	}
	r.runs[key][id] = st
	run := st.run
	r.runsMu.Unlock()
	r.persistRun(key, id)
	r.log.Info("run started", "session", key, "id", id, "device", device, "bytes", len(command), "command", firstLine(command, 80), "pane", pane)
	r.each(func(l Listener) { l.RunUpdated(run) })
	go r.tailRun(key, id, st)
	return run, nil
}

// tailRun polls the run's log until the run ends or is forgotten.
func (r *Registry) tailRun(key, id string, st *runState) {
	poll := r.runPoll
	if poll <= 0 {
		poll = time.Second
	}
	t := time.NewTicker(poll)
	defer t.Stop()
	for {
		select {
		case <-st.quit:
			return
		case <-t.C:
		}
		if r.pollRun(key, id, st) {
			return
		}
	}
}

// pollRun reads the log once, publishes a change, and reports whether the
// run has ended.
func (r *Registry) pollRun(key, id string, st *runState) bool {
	fi, err := os.Stat(st.logPath)
	if err != nil {
		return false
	}
	r.runsMu.Lock()
	changed := fi.Size() != st.size || !fi.ModTime().Equal(st.mtime)
	st.size, st.mtime = fi.Size(), fi.ModTime()
	stopAt := st.stopAt
	r.runsMu.Unlock()

	var b []byte
	if changed {
		b, _ = readTail(st.logPath, runReadBytes)
	}
	code, exited := 0, false
	if changed {
		if c, ok := parseExit(b); ok {
			// The status file proves the line came from the wrapper, not
			// from the command's own output.
			if rc, err := os.ReadFile(st.logPath + ".rc"); err == nil {
				if n, err := strconv.Atoi(strings.TrimSpace(string(rc))); err == nil {
					c = n
				}
				code, exited = c, true
			}
		}
	}
	graceOver := !stopAt.IsZero() && time.Since(stopAt) > runStopGrace
	if !changed && !graceOver {
		return false
	}

	r.runsMu.Lock()
	if _, ok := r.runs[key][id]; !ok {
		r.runsMu.Unlock()
		return true
	}
	if changed {
		st.run.Tail = tailLines(string(b), runTailLines, runTailBytes)
	}
	ended := false
	switch {
	case exited:
		st.run.Exit = &code
		st.run.State = RunDone
		if !stopAt.IsZero() {
			st.run.State = RunStopped
		}
		ended = true
	case graceOver:
		st.run.State = RunStopped
		ended = true
	}
	if ended {
		st.run.EndedAt = time.Now()
		r.scheduleRunKillLocked(key, id, st)
	}
	run := st.run
	feed := ended && exited && st.feed && !st.feeding && !st.feedSettled
	if feed {
		st.feeding = true
	}
	r.runsMu.Unlock()
	// The state is on disk before the status file goes, so a restart in
	// between still knows how the run ended.
	r.persistRun(key, id)

	if ended {
		_ = os.Remove(st.logPath + ".rc")
		exit := "none"
		if run.Exit != nil {
			exit = strconv.Itoa(*run.Exit)
		}
		r.log.Info("run ended", "session", key, "id", id, "state", run.State, "exit", exit)
	}
	if feed {
		r.feedRun(key, id, st, stripExit(string(b)), code, run.Recovered)
		return true
	}
	r.each(func(l Listener) { l.RunUpdated(run) })
	return ended
}

// feedRun types the run's output into the session. A session showing a
// permission prompt or a question is waited on (retrying each second for up
// to ten minutes) so the text does not land in the dialog; a busy session
// gets it anyway and the CLI queues it as the next turn. With waitSession
// (a run recovered after a restart) a session that is missing or not yet
// controllable is waited on the same way. The caller sets st.feeding.
func (r *Registry) feedRun(key, id string, st *runState, output string, code int, waitSession bool) {
	r.runsMu.Lock()
	command := st.run.Command
	r.runsMu.Unlock()
	text := feedText(command, tailLines(output, runFeedLines, runReadBytes), code)
	wait := r.runFeedWait
	if wait <= 0 {
		wait = 10 * time.Minute
	}
	deadline := time.Now().Add(wait)
	for {
		s, ok := r.Get(key)
		ready := ok && s.Controllable && s.PaneID != ""
		if !ready && !waitSession {
			r.log.Warn("run output not fed: session not controllable", "session", key, "id", id)
			break
		}
		if ready && s.Question == nil && s.Status != transcript.StatusWaitingPermission {
			queued := s.Status == transcript.StatusBusy
			ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
			err := r.SendText(ctx, key, text, true)
			cancel()
			if err != nil {
				r.log.Warn("run output not fed", "session", key, "id", id, "err", err)
				break
			}
			r.runsMu.Lock()
			st.run.Fed, st.run.Queued = true, queued
			r.runsMu.Unlock()
			r.log.Info("run output fed", "session", key, "id", id, "queued", queued)
			break
		}
		if time.Now().After(deadline) {
			if ready {
				r.log.Warn("run output not fed: a dialog stayed open", "session", key, "id", id)
			} else {
				r.log.Warn("run output not fed: session not controllable", "session", key, "id", id)
			}
			break
		}
		select {
		case <-st.quit:
			r.runsMu.Lock()
			st.feeding = false
			r.runsMu.Unlock()
			return
		case <-time.After(time.Second):
		}
	}
	r.runsMu.Lock()
	st.feeding, st.feedSettled = false, true
	run := st.run
	r.runsMu.Unlock()
	r.persistRun(key, id)
	r.each(func(l Listener) { l.RunUpdated(run) })
}

// closeRunWindow kills the window of a finished run and clears its pane id.
func (r *Registry) closeRunWindow(key, id string) {
	r.runsMu.Lock()
	st, ok := r.runs[key][id]
	if !ok || st.run.PaneID == "" {
		r.runsMu.Unlock()
		return
	}
	pane := st.run.PaneID
	st.run.PaneID = ""
	run := st.run
	r.runsMu.Unlock()
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	r.killRunWindow(ctx, pane, id)
	cancel()
	r.persistRun(key, id)
	r.each(func(l Listener) { l.RunUpdated(run) })
}

// killRunWindow kills the window holding pane only while that window is
// still the run's own: pane ids are reused once a tmux server restarts, so
// a stale id could otherwise close an unrelated window.
func (r *Registry) killRunWindow(ctx context.Context, pane, id string) {
	if pane == "" {
		return
	}
	name, err := r.tm.WindowName(ctx, pane)
	if err != nil || name != runWindowPrefix+id {
		r.log.Debug("run window not killed: not the run's window", "id", id, "pane", pane)
		return
	}
	_ = r.tm.KillWindow(ctx, pane)
}

// scheduleRunKillLocked arms the timer that closes a finished run's window
// runKillAfterEnd after it ended (at once when that time has passed).
// runsMu must be held.
func (r *Registry) scheduleRunKillLocked(key, id string, st *runState) {
	after := r.runKillAfter
	if after <= 0 {
		after = runKillAfterEnd
	}
	d := time.Until(st.run.EndedAt.Add(after))
	if d < 0 {
		d = 0
	}
	if st.kill != nil {
		st.kill.Stop()
	}
	st.kill = time.AfterFunc(d, func() { r.closeRunWindow(key, id) })
}

// StopRun presses Ctrl-C in the run's window. The run is marked stopped
// when its exit line appears or, failing that, after five seconds.
func (r *Registry) StopRun(ctx context.Context, key, id string) error {
	r.runsMu.Lock()
	st, ok := r.runs[key][id]
	if !ok {
		r.runsMu.Unlock()
		return errors.New("unknown run")
	}
	if st.run.State != RunRunning {
		r.runsMu.Unlock()
		return nil
	}
	if st.stopAt.IsZero() {
		st.stopAt = time.Now()
	}
	pane := st.run.PaneID
	r.runsMu.Unlock()
	r.log.Info("run stop", "session", key, "id", id)
	return r.tm.SendKeys(ctx, pane, []string{"C-c"})
}

// DismissRun kills the run's window and forgets the run.
func (r *Registry) DismissRun(ctx context.Context, key, id string) error {
	r.persistMu.Lock()
	defer r.persistMu.Unlock()
	r.runsMu.Lock()
	st, ok := r.runs[key][id]
	pane := ""
	if ok {
		delete(r.runs[key], id)
		if len(r.runs[key]) == 0 {
			delete(r.runs, key)
		}
		pane = st.run.PaneID
	}
	r.runsMu.Unlock()
	if !ok {
		return errors.New("unknown run")
	}
	st.close()
	r.killRunWindow(ctx, pane, id)
	_ = os.Remove(st.logPath)
	_ = os.Remove(st.logPath + ".rc")
	_ = os.Remove(r.runFilePath(id))
	r.log.Info("run dismissed", "session", key, "id", id)
	return nil
}

// Runs lists a session's runs, oldest first.
func (r *Registry) Runs(key string) []Run {
	r.runsMu.Lock()
	defer r.runsMu.Unlock()
	out := make([]Run, 0, len(r.runs[key]))
	for _, st := range r.runs[key] {
		out = append(out, st.run)
	}
	sortRuns(out)
	return out
}

// AllRuns lists every run, oldest first.
func (r *Registry) AllRuns() []Run {
	r.runsMu.Lock()
	defer r.runsMu.Unlock()
	var out []Run
	for _, m := range r.runs {
		for _, st := range m {
			out = append(out, st.run)
		}
	}
	sortRuns(out)
	return out
}

func sortRuns(rs []Run) {
	sort.Slice(rs, func(i, j int) bool {
		if !rs[i].StartedAt.Equal(rs[j].StartedAt) {
			return rs[i].StartedAt.Before(rs[j].StartedAt)
		}
		return rs[i].ID < rs[j].ID
	})
}

// RunPaneID returns the pane of one of the session's runs while its
// window is open.
func (r *Registry) RunPaneID(key, id string) (string, bool) { return r.runPane(key, id) }

// runPane returns the pane of one of the session's runs.
func (r *Registry) runPane(key, id string) (string, bool) {
	r.runsMu.Lock()
	defer r.runsMu.Unlock()
	st, ok := r.runs[key][id]
	if !ok || st.run.PaneID == "" {
		return "", false
	}
	return st.run.PaneID, true
}

// RunByPane finds the run of a session whose window holds paneID.
func (r *Registry) RunByPane(key, paneID string) (string, bool) {
	r.runsMu.Lock()
	defer r.runsMu.Unlock()
	for id, st := range r.runs[key] {
		if st.run.PaneID != "" && st.run.PaneID == paneID {
			return id, true
		}
	}
	return "", false
}

// forgetRuns drops a removed session's runs. Windows and logs of finished
// runs are removed; a command still running keeps its window and log.
func (r *Registry) forgetRuns(key string) {
	type gone struct {
		st      *runState
		id      string
		running bool
		pane    string
	}
	r.persistMu.Lock()
	defer r.persistMu.Unlock()
	r.runsMu.Lock()
	var gs []gone
	for id, st := range r.runs[key] {
		gs = append(gs, gone{st, id, st.run.State == RunRunning, st.run.PaneID})
	}
	delete(r.runs, key)
	r.runsMu.Unlock()
	for _, g := range gs {
		g.st.close()
		if g.running {
			continue
		}
		_ = os.Remove(g.st.logPath)
		_ = os.Remove(r.runFilePath(g.id))
		if g.pane != "" {
			ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
			r.killRunWindow(ctx, g.pane, g.id)
			cancel()
		}
	}
}

// RunPaneKey is the pane subscription key of a run window.
func RunPaneKey(key, id string) string { return key + "@run:" + id }

// SplitRunPaneKey undoes RunPaneKey.
func SplitRunPaneKey(k string) (key, id string, ok bool) {
	return strings.Cut(k, "@run:")
}
