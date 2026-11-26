package claude

import (
	"bufio"
	"bytes"
	"encoding/json"
	"io"
	"os"
	"sort"
	"strings"
	"sync"
	"time"
)

// PendingTask is a background task the session launched that has not
// reported completion: an Agent call run in the background or a Bash call
// with run_in_background.
type PendingTask struct {
	ID         string
	LaunchedAt time.Time
}

// taskScan is the incremental pending-task view of one parent transcript.
type taskScan struct {
	mu       sync.Mutex
	size     int64
	mtime    time.Time
	offset   int64
	lastUsed time.Time
	pending  map[string]time.Time
}

var taskScans = struct {
	sync.Mutex
	m map[string]*taskScan
}{m: map[string]*taskScan{}}

var (
	asyncMarker  = []byte(`"isAsync"`)
	bgTaskMarker = []byte(`"backgroundTaskId"`)
	noticeMarker = []byte(`task-notification`)
)

// PendingTasks lists the background tasks of the session whose transcript is
// at path that were launched and have not reported completion, oldest first.
//
// A launch is a user record whose toolUseResult has isAsync true (a
// background Agent call; the id is agentId) or a backgroundTaskId (a
// background Bash call). Completion is a <task-notification> naming the same
// <task-id>, written as a queued record and, once the model reads it, as a
// user record. The file is read incrementally like ListAgents does.
func PendingTasks(path string) ([]PendingTask, error) {
	taskScans.Lock()
	now := time.Now()
	if len(taskScans.m) > 1024 {
		for p, s := range taskScans.m {
			if s.mu.TryLock() {
				stale := now.Sub(s.lastUsed) > 30*time.Minute
				s.mu.Unlock()
				if stale {
					delete(taskScans.m, p)
				}
			}
		}
	}
	st := taskScans.m[path]
	if st == nil {
		st = &taskScan{pending: map[string]time.Time{}}
		taskScans.m[path] = st
	}
	taskScans.Unlock()

	st.mu.Lock()
	defer st.mu.Unlock()
	if err := st.advance(path); err != nil {
		return nil, err
	}
	out := make([]PendingTask, 0, len(st.pending))
	for id, at := range st.pending {
		out = append(out, PendingTask{ID: id, LaunchedAt: at})
	}
	sort.Slice(out, func(i, j int) bool {
		if !out[i].LaunchedAt.Equal(out[j].LaunchedAt) {
			return out[i].LaunchedAt.Before(out[j].LaunchedAt)
		}
		return out[i].ID < out[j].ID
	})
	return out, nil
}

func (s *taskScan) advance(path string) error {
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
		s.offset, s.pending = 0, map[string]time.Time{}
	}
	if _, err := f.Seek(s.offset, io.SeekStart); err != nil {
		return err
	}
	r := bufio.NewReaderSize(f, 64*1024)
	for {
		line, err := r.ReadBytes('\n')
		if err != nil {
			break
		}
		s.offset += int64(len(line))
		s.line(line)
	}
	s.size, s.mtime = fi.Size(), fi.ModTime()
	return nil
}

func (s *taskScan) line(line []byte) {
	launch := bytes.Contains(line, asyncMarker) || bytes.Contains(line, bgTaskMarker)
	notice := bytes.Contains(line, noticeMarker)
	if !launch && !notice {
		return
	}
	var e entry
	if json.Unmarshal(line, &e) != nil {
		return
	}
	if launch && e.Type == "user" && len(e.ToolUseResult) > 0 && e.ToolUseResult[0] == '{' {
		var r struct {
			IsAsync          bool   `json:"isAsync"`
			Status           string `json:"status"`
			AgentID          string `json:"agentId"`
			BackgroundTaskID string `json:"backgroundTaskId"`
		}
		if json.Unmarshal(e.ToolUseResult, &r) == nil {
			at := parseTime(e.Timestamp)
			if (r.IsAsync || r.Status == "async_launched") && r.AgentID != "" {
				s.pending[r.AgentID] = at
			}
			if r.BackgroundTaskID != "" {
				s.pending[r.BackgroundTaskID] = at
			}
		}
	}
	if !notice {
		return
	}
	var text string
	switch e.Type {
	case "queue-operation":
		text = contentText(e.Content)
	case "user":
		var m message
		if json.Unmarshal(e.Message, &m) == nil {
			if json.Unmarshal(m.Content, &text) != nil {
				text = contentText(m.Content)
			}
		}
	}
	for _, id := range allTagTexts(text, "task-id") {
		delete(s.pending, id)
	}
}

// allTagTexts returns the trimmed text of every <tag>...</tag> in s.
func allTagTexts(s, tag string) []string {
	open, end := "<"+tag+">", "</"+tag+">"
	var out []string
	for {
		i := strings.Index(s, open)
		if i < 0 {
			return out
		}
		s = s[i+len(open):]
		j := strings.Index(s, end)
		if j < 0 {
			return out
		}
		out = append(out, strings.TrimSpace(s[:j]))
		s = s[j+len(end):]
	}
}
