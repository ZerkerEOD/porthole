package core

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"
)

// Retention of runs read back after a restart.
const (
	runKeepState = 24 * time.Hour
	runKeepLogs  = 7 * 24 * time.Hour
	runLogMax    = 64 * 1024
)

// runFile is the on-disk record of one run, <runsDir>/<id>.json. It is
// written when the run starts, on every change and when its output is fed,
// so a daemon restarted mid-run can pick the run up again.
type runFile struct {
	Run     Run    `json:"run"`
	Feed    bool   `json:"feed"`
	LogPath string `json:"log_path"`
	Device  string `json:"device"`
	// FeedSettled is set once feeding ended, fed or given up.
	FeedSettled bool `json:"feed_settled,omitempty"`
}

var runIDRe = regexp.MustCompile(`^[0-9a-f]{8}$`)

func (r *Registry) runFilePath(id string) string {
	return filepath.Join(r.runsDir(), id+".json")
}

// persistRun writes the run's current state to its file. A run that was
// dismissed or forgotten is not written back.
func (r *Registry) persistRun(key, id string) {
	r.persistMu.Lock()
	defer r.persistMu.Unlock()
	r.runsMu.Lock()
	st, ok := r.runs[key][id]
	if !ok {
		r.runsMu.Unlock()
		return
	}
	rf := runFile{Run: st.run, Feed: st.feed, LogPath: st.logPath, Device: st.run.Device, FeedSettled: st.feedSettled}
	r.runsMu.Unlock()
	if err := writeRunFile(r.runFilePath(id), rf); err != nil {
		r.log.Warn("run state not saved", "session", key, "id", id, "err", err)
	}
}

// writeRunFile replaces path atomically with rf (mode 0600).
func writeRunFile(path string, rf runFile) error {
	b, err := json.Marshal(rf)
	if err != nil {
		return err
	}
	tmp, err := os.CreateTemp(filepath.Dir(path), ".run-*.tmp")
	if err != nil {
		return err
	}
	name := tmp.Name()
	_, werr := tmp.Write(b)
	cerr := tmp.Close()
	if werr == nil {
		werr = cerr
	}
	if werr == nil {
		werr = os.Chmod(name, 0o600)
	}
	if werr == nil {
		werr = os.Rename(name, path)
	}
	if werr != nil {
		_ = os.Remove(name)
	}
	return werr
}

func readRunFile(path string) (runFile, error) {
	var rf runFile
	b, err := os.ReadFile(path)
	if err != nil {
		return rf, err
	}
	if err := json.Unmarshal(b, &rf); err != nil {
		return rf, err
	}
	return rf, nil
}

// LoadRuns reads back the runs a previous daemon left on disk. A run that
// finished while the daemon was down is completed from its log; one still
// running is tailed again; a finished run whose output was to be typed into
// the session and was not is fed now. Windows of finished runs close ten
// minutes after the run ended, at once when that is past. Runs that ended
// more than a day ago are dropped.
func (r *Registry) LoadRuns(ctx context.Context) {
	dir := r.runsDir()
	ents, err := os.ReadDir(dir)
	if err != nil {
		return
	}
	pruneRunLogs(dir, runKeepLogs)
	for _, e := range ents {
		n := e.Name()
		if e.IsDir() || !strings.HasSuffix(n, ".json") {
			continue
		}
		id := strings.TrimSuffix(n, ".json")
		if !runIDRe.MatchString(id) {
			continue
		}
		r.loadRun(ctx, id)
	}
}

func (r *Registry) loadRun(ctx context.Context, id string) {
	path := r.runFilePath(id)
	rf, err := readRunFile(path)
	if err != nil || rf.Run.ID != id || rf.Run.Key == "" {
		r.log.Warn("run state unreadable; dropped", "id", id, "err", err)
		_ = os.Remove(path)
		return
	}
	// The log always lives beside the state file; a path from the file
	// that points elsewhere is not trusted.
	logPath := filepath.Join(r.runsDir(), id+".log")
	key := rf.Run.Key
	run := rf.Run
	run.Recovered = true
	if run.Device == "" {
		run.Device = rf.Device
	}
	r.runsMu.Lock()
	_, dup := r.runs[key][id]
	r.runsMu.Unlock()
	if dup {
		return
	}

	feedOutput, feedCode, feedNow := "", 0, false
	if run.State == RunRunning {
		b, _ := readTail(logPath, runReadBytes)
		fi, statErr := os.Stat(logPath)
		code, exited := 0, false
		if c, ok := parseExit(b); ok {
			if rc, err := os.ReadFile(logPath + ".rc"); err == nil {
				if n, err := strconv.Atoi(strings.TrimSpace(string(rc))); err == nil {
					c = n
				}
				code, exited = c, true
			}
		}
		alive := false
		if !exited && run.PaneID != "" {
			name, err := r.tm.WindowName(ctx, run.PaneID)
			alive = err == nil && name == runWindowPrefix+id
		}
		switch {
		case exited:
			run.Exit = &code
			run.State = RunDone
			if code == 130 {
				run.State = RunStopped
			}
			run.Tail = tailLines(string(b), runTailLines, runTailBytes)
			feedOutput, feedCode = stripExit(string(b)), code
		case !alive:
			// The window is gone without an exit line (the tmux server
			// stopped, say): the run cannot be followed any more.
			run.State = RunStopped
			if len(b) > 0 {
				run.Tail = tailLines(string(b), runTailLines, runTailBytes)
			}
		}
		if run.State != RunRunning && run.EndedAt.IsZero() {
			run.EndedAt = time.Now()
			if statErr == nil {
				run.EndedAt = fi.ModTime()
			}
		}
	}
	if run.State != RunRunning && !run.EndedAt.IsZero() && time.Since(run.EndedAt) > runKeepState {
		ctx2, cancel := context.WithTimeout(ctx, 10*time.Second)
		r.killRunWindow(ctx2, run.PaneID, id)
		cancel()
		_ = os.Remove(path)
		_ = os.Remove(logPath + ".rc")
		r.log.Info("old run dropped", "session", key, "id", id)
		return
	}
	if rf.Feed && !run.Fed && !rf.FeedSettled && run.State != RunRunning && run.Exit != nil {
		if feedOutput == "" {
			b, _ := readTail(logPath, runReadBytes)
			feedOutput = stripExit(string(b))
		}
		feedCode, feedNow = *run.Exit, true
	}

	st := &runState{run: run, feed: rf.Feed, logPath: logPath, quit: make(chan struct{}), feedSettled: rf.FeedSettled, feeding: feedNow}
	r.runsMu.Lock()
	if r.runs[key] == nil {
		r.runs[key] = map[string]*runState{}
	}
	r.runs[key][id] = st
	if run.State != RunRunning {
		r.scheduleRunKillLocked(key, id, st)
	}
	r.runsMu.Unlock()
	r.persistRun(key, id)
	if run.State != RunRunning {
		_ = os.Remove(logPath + ".rc")
	}
	r.log.Info("run recovered", "session", key, "id", id, "state", run.State, "feed", feedNow)
	r.each(func(l Listener) { l.RunUpdated(run) })
	switch {
	case run.State == RunRunning:
		go r.tailRun(key, id, st)
	case feedNow:
		go r.feedRun(key, id, st, feedOutput, feedCode, true)
	}
}

// RunLog returns the start of a run's log, up to 64 KB; truncated is set
// when the log is longer.
func (r *Registry) RunLog(key, id string) (text string, truncated bool, err error) {
	r.runsMu.Lock()
	st, ok := r.runs[key][id]
	logPath := ""
	if ok {
		logPath = st.logPath
	}
	r.runsMu.Unlock()
	if !ok {
		return "", false, errors.New("unknown run")
	}
	f, err := os.Open(logPath)
	if err != nil {
		return "", false, errors.New("run log not available")
	}
	defer f.Close()
	b, err := io.ReadAll(io.LimitReader(f, runLogMax+1))
	if err != nil {
		return "", false, errors.New("run log not available")
	}
	if len(b) > runLogMax {
		b = b[:runLogMax]
		// Drop a rune cut in half at the end.
		for i := 0; i < utf8.UTFMax-1 && len(b) > 0; i++ {
			if c, size := utf8.DecodeLastRune(b); c != utf8.RuneError || size > 1 {
				break
			}
			b = b[:len(b)-1]
		}
		truncated = true
	}
	return string(b), truncated, nil
}
