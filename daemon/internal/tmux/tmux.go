// Package tmux is the control plane: pane discovery, literal input, key
// presses, screen capture and session spawning. Every call shells out to the
// tmux binary with a fixed argv; user text is never interpreted by a shell.
package tmux

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"os/exec"
	"regexp"
	"strconv"
	"strings"
	"time"
)

// Client wraps the tmux binary.
type Client struct {
	Binary string
	// extraArgs are inserted before every command (tests use -L <socket>).
	extraArgs []string
}

// Pane is one tmux pane and the process it hosts.
type Pane struct {
	SessionName string `json:"session_name"`
	WindowIndex int    `json:"window_index"`
	PaneIndex   int    `json:"pane_index"`
	PaneID      string `json:"pane_id"` // "%12"
	PID         int    `json:"pid"`     // the pane's shell/command pid
	Path        string `json:"path"`
	Command     string `json:"command"`
	TTY         string `json:"tty"`
	Width       int    `json:"width"`
	Height      int    `json:"height"`
}

var paneIDRe = regexp.MustCompile(`^%[0-9]{1,8}$`)
var sessionNameRe = regexp.MustCompile(`^[A-Za-z0-9_.-]{1,64}$`)

// ValidPaneID reports whether s looks like a tmux pane id.
func ValidPaneID(s string) bool { return paneIDRe.MatchString(s) }

func (c *Client) bin() string {
	if c.Binary == "" {
		return "tmux"
	}
	return c.Binary
}

func (c *Client) run(ctx context.Context, args ...string) (string, error) {
	ctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	full := append(append([]string{}, c.extraArgs...), args...)
	cmd := exec.CommandContext(ctx, c.bin(), full...)
	var out, errb bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &errb
	if err := cmd.Run(); err != nil {
		msg := strings.TrimSpace(errb.String())
		if msg == "" {
			msg = err.Error()
		}
		return out.String(), fmt.Errorf("tmux %s: %s", args[0], msg)
	}
	return out.String(), nil
}

// Available reports whether tmux is runnable.
func (c *Client) Available(ctx context.Context) bool {
	_, err := c.run(ctx, "-V")
	return err == nil
}

// Version returns the tmux version string.
func (c *Client) Version(ctx context.Context) (string, error) {
	out, err := c.run(ctx, "-V")
	return strings.TrimSpace(out), err
}

// ErrNoServer is returned when tmux has no running server (no sessions).
var ErrNoServer = errors.New("tmux: no server running")

const paneFormat = "#{session_name}\t#{window_index}\t#{pane_index}\t#{pane_id}\t#{pane_pid}\t#{pane_current_path}\t#{pane_current_command}\t#{pane_tty}\t#{pane_width}\t#{pane_height}"

// ListPanes lists every pane on the default server.
func (c *Client) ListPanes(ctx context.Context) ([]Pane, error) {
	out, err := c.run(ctx, "list-panes", "-a", "-F", paneFormat)
	if err != nil {
		if strings.Contains(err.Error(), "no server running") || strings.Contains(err.Error(), "error connecting") {
			return nil, ErrNoServer
		}
		return nil, err
	}
	var panes []Pane
	for _, l := range strings.Split(strings.TrimRight(out, "\n"), "\n") {
		if l == "" {
			continue
		}
		f := strings.Split(l, "\t")
		if len(f) < 10 {
			continue
		}
		p := Pane{SessionName: f[0], PaneID: f[3], Path: f[5], Command: f[6], TTY: f[7]}
		p.WindowIndex, _ = strconv.Atoi(f[1])
		p.PaneIndex, _ = strconv.Atoi(f[2])
		p.PID, _ = strconv.Atoi(f[4])
		p.Width, _ = strconv.Atoi(f[8])
		p.Height, _ = strconv.Atoi(f[9])
		panes = append(panes, p)
	}
	return panes, nil
}

// SendText types text into the pane as literal characters. Multi-line text
// goes through a tmux buffer with bracketed paste so the TUI treats it as one
// paste. When enter is true a final Enter key is sent.
func (c *Client) SendText(ctx context.Context, paneID, text string, enter bool) error {
	if !ValidPaneID(paneID) {
		return errors.New("tmux: invalid pane id")
	}
	if len(text) > 256*1024 {
		return errors.New("tmux: input too large")
	}
	if strings.ContainsAny(text, "\n\r") {
		buf := "porthole-" + strings.TrimPrefix(paneID, "%")
		if _, err := c.run(ctx, "set-buffer", "-b", buf, "--", text); err != nil {
			return err
		}
		if _, err := c.run(ctx, "paste-buffer", "-d", "-p", "-b", buf, "-t", paneID); err != nil {
			return err
		}
	} else if text != "" {
		if _, err := c.run(ctx, "send-keys", "-t", paneID, "-l", "--", text); err != nil {
			return err
		}
	}
	if enter {
		// Give the TUI a moment to ingest the paste before Enter.
		if strings.ContainsAny(text, "\n\r") {
			time.Sleep(80 * time.Millisecond)
		}
		_, err := c.run(ctx, "send-keys", "-t", paneID, "Enter")
		return err
	}
	return nil
}

// allowedKeys are the only key names a client may send by name.
var allowedKeys = map[string]bool{
	"Enter": true, "Escape": true, "Tab": true, "BTab": true, "Space": true, "BSpace": true,
	"Up": true, "Down": true, "Left": true, "Right": true, "Home": true, "End": true,
	"PageUp": true, "PageDown": true, "DC": true, "IC": true,
	"C-c": true, "C-d": true, "C-u": true, "C-l": true, "C-r": true, "C-a": true, "C-e": true,
	"C-k": true, "C-w": true, "C-z": true, "C-o": true, "C-t": true, "C-b": true, "C-g": true,
	"M-Enter": true, "S-Enter": true, "C-Enter": true,
	"F1": true, "F2": true, "F3": true, "F4": true, "F5": true, "F6": true, "F7": true, "F8": true,
}

// SendKeys presses named keys (Enter, Escape, Up, C-c, ...) or single
// printable characters in order.
func (c *Client) SendKeys(ctx context.Context, paneID string, keys []string) error {
	if !ValidPaneID(paneID) {
		return errors.New("tmux: invalid pane id")
	}
	if len(keys) == 0 || len(keys) > 32 {
		return errors.New("tmux: 1..32 keys")
	}
	args := []string{"send-keys", "-t", paneID}
	for _, k := range keys {
		switch {
		case allowedKeys[k]:
			args = append(args, k)
		case len([]rune(k)) == 1 && k[0] >= 0x20 && k != ";":
			args = append(args, "-l", k)
			// -l applies to the rest of the args in tmux; re-add target to reset.
			args = append(args, ";", "send-keys", "-t", paneID)
		default:
			return fmt.Errorf("tmux: key %q not allowed", k)
		}
	}
	// Trim a trailing empty send-keys command if the last key was literal.
	if len(args) >= 4 && args[len(args)-4] == ";" {
		args = args[:len(args)-4]
	}
	_, err := c.run(ctx, args...)
	return err
}

// Screen is a captured pane with cursor position.
type Screen struct {
	Lines   []string `json:"lines"` // with ANSI SGR sequences
	CursorX int      `json:"cursor_x"`
	CursorY int      `json:"cursor_y"`
	Width   int      `json:"width"`
	Height  int      `json:"height"`
	// InMode is true when the pane is in copy mode (scrolled back).
	InMode bool `json:"in_mode"`
}

// Capture returns the visible screen plus up to scrollback lines of history.
func (c *Client) Capture(ctx context.Context, paneID string, scrollback int) (*Screen, error) {
	if !ValidPaneID(paneID) {
		return nil, errors.New("tmux: invalid pane id")
	}
	if scrollback < 0 || scrollback > 5000 {
		scrollback = 200
	}
	out, err := c.run(ctx, "capture-pane", "-p", "-e", "-t", paneID, "-S", "-"+strconv.Itoa(scrollback))
	if err != nil {
		return nil, err
	}
	meta, err := c.run(ctx, "display-message", "-p", "-t", paneID, "#{cursor_x}\t#{cursor_y}\t#{pane_width}\t#{pane_height}\t#{pane_in_mode}")
	if err != nil {
		return nil, err
	}
	s := &Screen{Lines: strings.Split(strings.TrimRight(out, "\n"), "\n")}
	f := strings.Split(strings.TrimSpace(meta), "\t")
	if len(f) >= 5 {
		s.CursorX, _ = strconv.Atoi(f[0])
		s.CursorY, _ = strconv.Atoi(f[1])
		s.Width, _ = strconv.Atoi(f[2])
		s.Height, _ = strconv.Atoi(f[3])
		s.InMode = f[4] == "1"
	}
	return s, nil
}

// NewSession starts a detached tmux session running argv in dir and returns
// the pane id. argv[0] is resolved via PATH by tmux's default shell-less exec.
func (c *Client) NewSession(ctx context.Context, name, dir string, argv []string, env map[string]string) (string, error) {
	if !sessionNameRe.MatchString(name) {
		return "", errors.New("tmux: invalid session name")
	}
	if len(argv) == 0 {
		return "", errors.New("tmux: empty command")
	}
	args := []string{"new-session", "-d", "-P", "-F", "#{pane_id}", "-s", name, "-c", dir, "-x", "220", "-y", "60"}
	for k, v := range env {
		args = append(args, "-e", k+"="+v)
	}
	args = append(args, "--")
	args = append(args, argv...)
	out, err := c.run(ctx, args...)
	if err != nil {
		return "", err
	}
	id := strings.TrimSpace(out)
	if !ValidPaneID(id) {
		return "", fmt.Errorf("tmux: unexpected pane id %q", id)
	}
	// Keep the window open after the program exits so the user can read the end.
	_, _ = c.run(ctx, "set-option", "-t", name, "remain-on-exit", "on")
	return id, nil
}

// KillSession kills a session the daemon created.
func (c *Client) KillSession(ctx context.Context, name string) error {
	if !sessionNameRe.MatchString(name) {
		return errors.New("tmux: invalid session name")
	}
	_, err := c.run(ctx, "kill-session", "-t", "="+name)
	return err
}

// HasSession reports whether a session with this exact name exists.
func (c *Client) HasSession(ctx context.Context, name string) bool {
	if !sessionNameRe.MatchString(name) {
		return false
	}
	_, err := c.run(ctx, "has-session", "-t", "="+name)
	return err == nil
}

// Resize sets the pane's window size so the TUI matches the phone layout.
func (c *Client) Resize(ctx context.Context, paneID string, cols, rows int) error {
	if !ValidPaneID(paneID) {
		return errors.New("tmux: invalid pane id")
	}
	if cols < 20 || cols > 400 || rows < 5 || rows > 200 {
		return errors.New("tmux: size out of range")
	}
	_, err := c.run(ctx, "resize-window", "-t", paneID, "-x", strconv.Itoa(cols), "-y", strconv.Itoa(rows))
	return err
}
