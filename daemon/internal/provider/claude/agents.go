package claude

import (
	"bufio"
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/ZerkerEOD/porthole/daemon/internal/transcript"
)

// agentActiveWindow is how recently an unfinished subagent transcript must
// have changed for the run to count as running.
const agentActiveWindow = 20 * time.Second

// lastTextMax caps AgentInfo.LastText, in characters.
const lastTextMax = 200

// AgentsDir is where Claude Code writes the subagent transcripts of the
// session whose transcript is at transcriptPath.
func AgentsDir(transcriptPath string) string {
	return filepath.Join(strings.TrimSuffix(transcriptPath, ".jsonl"), "subagents")
}

// agentMeta is the part of agent-<id>.meta.json we read.
type agentMeta struct {
	AgentType    string `json:"agentType"`
	Description  string `json:"description"`
	ToolUseID    string `json:"toolUseId"`
	RequestShape string `json:"requestShape"`
	Model        string `json:"model"`
	Finished     *bool  `json:"finished"`
}

// ListAgents summarizes the subagent runs of the session whose transcript is
// at transcriptPath, oldest first. A session without subagents returns nil.
// Summaries are cached by file size and mtime, and a grown file is read only
// from where the previous read stopped.
func ListAgents(transcriptPath string) ([]transcript.AgentInfo, error) {
	dir := AgentsDir(transcriptPath)
	ents, err := os.ReadDir(dir)
	if err != nil {
		if errors.Is(err, fs.ErrNotExist) {
			return nil, nil
		}
		return nil, err
	}
	now := time.Now()
	var out []transcript.AgentInfo
	for _, de := range ents {
		name := de.Name()
		if de.IsDir() || !strings.HasPrefix(name, "agent-") || !strings.HasSuffix(name, ".jsonl") {
			continue
		}
		id := strings.TrimSuffix(strings.TrimPrefix(name, "agent-"), ".jsonl")
		if id == "" {
			continue
		}
		path := filepath.Join(dir, name)
		st := stateFor(path, false)
		st.mu.Lock()
		if err := st.advance(path); err != nil {
			st.mu.Unlock()
			continue
		}
		a := transcript.AgentInfo{
			ID:        id,
			Type:      "agent",
			StartedAt: st.started,
			UpdatedAt: st.mtime,
			Turns:     len(st.perMsg),
			ToolUses:  len(st.tools),
			Usage:     st.total,
			Model:     st.model,
			LastText:  st.lastText,
			Path:      path,
		}
		firstPrompt := st.firstPrompt
		st.mu.Unlock()

		if m, ok := readAgentMeta(filepath.Join(dir, "agent-"+id+".meta.json")); ok {
			if m.AgentType != "" {
				a.Type = m.AgentType
			}
			a.Description = m.Description
			a.ToolUseID = m.ToolUseID
			a.Background = m.RequestShape == "background"
			if m.Finished != nil {
				a.Finished, a.ReportsFinish = *m.Finished, true
			}
			if a.Model == "" {
				a.Model = m.Model
			}
		}
		if a.Description == "" {
			a.Description = firstLine(firstPrompt, 120)
		}
		a.Running = !a.Finished && now.Sub(a.UpdatedAt) < agentActiveWindow
		out = append(out, a)
	}
	sort.SliceStable(out, func(i, j int) bool {
		ti, tj := out[i].StartedAt, out[j].StartedAt
		if ti.IsZero() {
			ti = out[i].UpdatedAt
		}
		if tj.IsZero() {
			tj = out[j].UpdatedAt
		}
		if !ti.Equal(tj) {
			return ti.Before(tj)
		}
		return out[i].ID < out[j].ID
	})
	return out, nil
}

// TranscriptUsage sums the token usage of a session's own assistant messages
// (subagent records excluded), counting each message id once. Like
// ListAgents it reads only what was appended since the previous call.
func TranscriptUsage(path string) (transcript.Usage, error) {
	st := stateFor(path, true)
	st.mu.Lock()
	defer st.mu.Unlock()
	if err := st.advance(path); err != nil {
		return transcript.Usage{}, err
	}
	return st.total, nil
}

// ---- incremental transcript scan ----

// scanState is the running summary of one transcript file.
type scanState struct {
	mu            sync.Mutex
	assistantOnly bool // parent transcripts: only assistant records matter

	size     int64
	mtime    time.Time
	offset   int64 // end of the last complete line read
	lastUsed time.Time

	perMsg      map[string]transcript.Usage
	total       transcript.Usage
	tools       map[string]bool
	started     time.Time
	model       string
	lastText    string
	firstPrompt string
}

var scans = struct {
	sync.Mutex
	m map[string]*scanState
}{m: map[string]*scanState{}}

// stateFor returns the cached scan state for path, creating it if needed.
func stateFor(path string, assistantOnly bool) *scanState {
	scans.Lock()
	defer scans.Unlock()
	now := time.Now()
	if len(scans.m) > 1024 {
		for p, s := range scans.m {
			if s.mu.TryLock() {
				stale := now.Sub(s.lastUsed) > 30*time.Minute
				s.mu.Unlock()
				if stale {
					delete(scans.m, p)
				}
			}
		}
	}
	s := scans.m[path]
	if s == nil || s.assistantOnly != assistantOnly {
		s = &scanState{assistantOnly: assistantOnly}
		s.reset()
		scans.m[path] = s
	}
	return s
}

func (s *scanState) reset() {
	s.size, s.mtime, s.offset = 0, time.Time{}, 0
	s.perMsg = map[string]transcript.Usage{}
	s.total = transcript.Usage{}
	s.tools = map[string]bool{}
	s.started, s.model, s.lastText, s.firstPrompt = time.Time{}, "", "", ""
}

// advance reads the complete lines appended since the last call. A partial
// last line is left for the next call. The caller holds s.mu.
func (s *scanState) advance(path string) error {
	s.lastUsed = time.Now()
	f, err := os.Open(path)
	if err != nil {
		return err
	}
	defer f.Close()
	fi, err := f.Stat()
	if err != nil {
		return err
	}
	if fi.Size() == s.size && fi.ModTime().Equal(s.mtime) {
		return nil
	}
	if fi.Size() < s.offset {
		s.reset() // truncated or replaced: start over
	}
	if _, err := f.Seek(s.offset, io.SeekStart); err != nil {
		return err
	}
	r := bufio.NewReaderSize(f, 64*1024)
	for {
		line, err := r.ReadBytes('\n')
		if err != nil {
			break // EOF: an incomplete line waits for the next call
		}
		s.offset += int64(len(line))
		s.line(line)
	}
	s.size, s.mtime = fi.Size(), fi.ModTime()
	return nil
}

var assistantMarker = []byte(`"assistant"`)

// line folds one transcript record into the summary.
func (s *scanState) line(line []byte) {
	if s.assistantOnly && !bytes.Contains(line, assistantMarker) {
		return
	}
	var e entry
	if json.Unmarshal(line, &e) != nil {
		return
	}
	if !s.assistantOnly && s.started.IsZero() {
		s.started = parseTime(e.Timestamp)
	}
	switch e.Type {
	case "user":
		if s.firstPrompt != "" || e.IsMeta {
			return
		}
		var m message
		if json.Unmarshal(e.Message, &m) != nil {
			return
		}
		var txt string
		if json.Unmarshal(m.Content, &txt) != nil {
			txt = contentText(m.Content)
		}
		if strings.TrimSpace(txt) != "" && !isSystemInjected(txt) {
			s.firstPrompt = txt
		}
	case "assistant":
		if e.IsAPIError || (s.assistantOnly && e.Sidechain) {
			return
		}
		var m message
		if json.Unmarshal(e.Message, &m) != nil {
			return
		}
		if m.Model != "" && m.Model != "<synthetic>" {
			s.model = m.Model
		}
		if m.ID != "" {
			var u transcript.Usage
			if m.Usage != nil {
				u = transcript.Usage{InputTokens: m.Usage.Input, OutputTokens: m.Usage.Output, CacheReadTokens: m.Usage.CacheRead, CacheCreationTokens: m.Usage.CacheCreation}
			}
			s.addUsage(m.ID, u)
		}
		if s.assistantOnly {
			return
		}
		var blocks []block
		if json.Unmarshal(m.Content, &blocks) != nil {
			return
		}
		for _, b := range blocks {
			switch b.Type {
			case "tool_use":
				id := b.ID
				if id == "" {
					id = e.UUID + ":" + b.Name
				}
				s.tools[id] = true
			case "text":
				if t := collapse(b.Text, lastTextMax); t != "" {
					s.lastText = t
				}
			}
		}
	}
}

// addUsage records the usage of one assistant message. Claude Code writes a
// record per content block, each repeating the message's usage as it stood
// then, so the largest value of each counter is the message's total.
func (s *scanState) addUsage(id string, u transcript.Usage) {
	old, seen := s.perMsg[id]
	if seen {
		u.InputTokens = max(u.InputTokens, old.InputTokens)
		u.OutputTokens = max(u.OutputTokens, old.OutputTokens)
		u.CacheReadTokens = max(u.CacheReadTokens, old.CacheReadTokens)
		u.CacheCreationTokens = max(u.CacheCreationTokens, old.CacheCreationTokens)
	}
	s.perMsg[id] = u
	s.total.InputTokens += u.InputTokens - old.InputTokens
	s.total.OutputTokens += u.OutputTokens - old.OutputTokens
	s.total.CacheReadTokens += u.CacheReadTokens - old.CacheReadTokens
	s.total.CacheCreationTokens += u.CacheCreationTokens - old.CacheCreationTokens
}

// collapse joins the words of s with single spaces and caps it at n characters.
func collapse(s string, n int) string {
	s = strings.Join(strings.Fields(s), " ")
	r := []rune(s)
	if len(r) > n {
		return string(r[:n-1]) + "…"
	}
	return s
}

// ---- meta.json ----

type metaEntry struct {
	size  int64
	mtime time.Time
	meta  agentMeta
}

var metas = struct {
	sync.Mutex
	m map[string]metaEntry
}{m: map[string]metaEntry{}}

// readAgentMeta reads a meta.json file, cached by size and mtime.
func readAgentMeta(path string) (agentMeta, bool) {
	fi, err := os.Stat(path)
	if err != nil {
		metas.Lock()
		delete(metas.m, path)
		metas.Unlock()
		return agentMeta{}, false
	}
	metas.Lock()
	e, ok := metas.m[path]
	metas.Unlock()
	if ok && e.size == fi.Size() && e.mtime.Equal(fi.ModTime()) {
		return e.meta, true
	}
	b, err := os.ReadFile(path)
	if err != nil {
		return agentMeta{}, false
	}
	var m agentMeta
	if json.Unmarshal(b, &m) != nil {
		return agentMeta{}, false
	}
	metas.Lock()
	metas.m[path] = metaEntry{size: fi.Size(), mtime: fi.ModTime(), meta: m}
	metas.Unlock()
	return m, true
}
