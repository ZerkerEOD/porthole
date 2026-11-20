package transcript

import (
	"bufio"
	"bytes"
	"context"
	"errors"
	"io"
	"os"
	"sync"
	"time"

	"github.com/fsnotify/fsnotify"
)

// Tailer follows one JSONL file from a byte offset, delivering complete lines.
// A trailing partial line (the CLI is mid-write) is held until its newline
// arrives. Truncation (offset beyond size) restarts from zero.
type Tailer struct {
	Path   string
	Offset int64

	mu      sync.Mutex
	partial []byte
}

// ReadAvailable reads every complete line past Offset and calls fn for each.
// It returns the new offset. Safe to call repeatedly; cheap when nothing changed.
func (t *Tailer) ReadAvailable(fn func(line []byte) error) (int64, error) {
	t.mu.Lock()
	defer t.mu.Unlock()
	f, err := os.Open(t.Path)
	if err != nil {
		return t.Offset, err
	}
	defer f.Close()
	st, err := f.Stat()
	if err != nil {
		return t.Offset, err
	}
	if st.Size() < t.Offset {
		// Truncated or replaced: start over.
		t.Offset = 0
		t.partial = nil
	}
	if st.Size() == t.Offset {
		return t.Offset, nil
	}
	if _, err := f.Seek(t.Offset, io.SeekStart); err != nil {
		return t.Offset, err
	}
	r := bufio.NewReaderSize(f, 256*1024)
	for {
		chunk, err := r.ReadSlice('\n')
		if errors.Is(err, bufio.ErrBufferFull) {
			t.partial = append(t.partial, chunk...)
			t.Offset += int64(len(chunk))
			continue
		}
		if err != nil && !errors.Is(err, io.EOF) {
			return t.Offset, err
		}
		if len(chunk) > 0 && chunk[len(chunk)-1] == '\n' {
			line := chunk[:len(chunk)-1]
			if len(t.partial) > 0 {
				line = append(t.partial, line...)
				t.partial = nil
			}
			t.Offset += int64(len(chunk))
			line = bytes.TrimRight(line, "\r")
			if len(bytes.TrimSpace(line)) > 0 {
				if ferr := fn(line); ferr != nil {
					return t.Offset, ferr
				}
			}
		} else if len(chunk) > 0 {
			// Partial trailing line: keep bytes, advance offset so we do not re-read them.
			t.partial = append(t.partial, chunk...)
			t.Offset += int64(len(chunk))
		}
		if errors.Is(err, io.EOF) {
			return t.Offset, nil
		}
	}
}

// Watcher multiplexes fsnotify events for many files and directories and
// coalesces bursts. Callers register paths and receive the path that changed.
type Watcher struct {
	w   *fsnotify.Watcher
	out chan string
}

// NewWatcher creates a watcher; Close it when done.
func NewWatcher() (*Watcher, error) {
	w, err := fsnotify.NewWatcher()
	if err != nil {
		return nil, err
	}
	return &Watcher{w: w, out: make(chan string, 256)}, nil
}

// Add watches a file or directory. Adding twice is harmless.
func (wt *Watcher) Add(path string) error { return wt.w.Add(path) }

// Remove stops watching a path.
func (wt *Watcher) Remove(path string) error { return wt.w.Remove(path) }

// Events yields changed paths, debounced per path to at most one per 50 ms.
func (wt *Watcher) Events() <-chan string { return wt.out }

// Run pumps fsnotify events until ctx is done.
func (wt *Watcher) Run(ctx context.Context) {
	pending := map[string]bool{}
	tick := time.NewTicker(50 * time.Millisecond)
	defer tick.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case ev, ok := <-wt.w.Events:
			if !ok {
				return
			}
			if ev.Op&(fsnotify.Write|fsnotify.Create|fsnotify.Rename|fsnotify.Remove) != 0 {
				pending[ev.Name] = true
			}
		case <-wt.w.Errors:
			// Errors are non-fatal for a best-effort tailer; the poll fallback covers gaps.
		case <-tick.C:
			for p := range pending {
				select {
				case wt.out <- p:
				default:
				}
				delete(pending, p)
			}
		}
	}
}

// Close releases the underlying watcher.
func (wt *Watcher) Close() error { return wt.w.Close() }
