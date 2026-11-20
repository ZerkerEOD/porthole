package core

import (
	"sync"
	"time"

	"github.com/ZerkerEOD/porthole/daemon/internal/provider/claude"
	"github.com/ZerkerEOD/porthole/daemon/internal/provider/codex"
	"github.com/ZerkerEOD/porthole/daemon/internal/transcript"
)

// maxCached caps the in-memory events per followed session. Older events are
// dropped from memory; history before that is re-read from disk on demand.
const maxCached = 20000

// follower tails one transcript and keeps its parsed events.
type follower struct {
	key     string
	path    string
	parser  transcript.Parser
	tailer  *transcript.Tailer
	mu      sync.Mutex
	events  []transcript.Event
	nextSeq int64
	lastUse time.Time
	// status derived from the transcript (Codex) when no better source exists.
	status string
	model  string
}

func newFollower(key, provider, path string) *follower {
	var p transcript.Parser
	if provider == "codex" {
		p = codex.NewParser()
	} else {
		p = claude.NewParser()
	}
	return &follower{key: key, path: path, parser: p, tailer: &transcript.Tailer{Path: path}, lastUse: time.Now(), status: transcript.StatusUnknown}
}

// pump reads new lines and returns the new events (already appended).
func (f *follower) pump() ([]transcript.Event, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	var fresh []transcript.Event
	_, err := f.tailer.ReadAvailable(func(line []byte) error {
		evs, perr := f.parser.ParseLine(line)
		if perr != nil {
			return nil // a bad line is skipped, never fatal
		}
		for _, ev := range evs {
			ev.Seq = f.nextSeq
			f.nextSeq++
			if ev.Type == transcript.TypeStatus && ev.Status != "" {
				f.status = ev.Status
			}
			if ev.Model != "" {
				f.model = ev.Model
			}
			fresh = append(fresh, ev)
		}
		return nil
	})
	if len(fresh) > 0 {
		f.events = append(f.events, fresh...)
		if len(f.events) > maxCached {
			f.events = append([]transcript.Event(nil), f.events[len(f.events)-maxCached:]...)
		}
	}
	return fresh, err
}

// page returns up to limit events with Seq < before (before<=0 means latest).
func (f *follower) page(before int64, limit int) (out []transcript.Event, hasMore bool) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.lastUse = time.Now()
	if limit <= 0 || limit > 500 {
		limit = 200
	}
	end := len(f.events)
	if before > 0 {
		// Binary search for first seq >= before.
		lo, hi := 0, len(f.events)
		for lo < hi {
			mid := (lo + hi) / 2
			if f.events[mid].Seq < before {
				lo = mid + 1
			} else {
				hi = mid
			}
		}
		end = lo
	}
	start := end - limit
	if start < 0 {
		start = 0
	}
	out = append([]transcript.Event(nil), f.events[start:end]...)
	hasMore = start > 0 || (len(f.events) > 0 && f.events[0].Seq > 0)
	return out, hasMore
}
