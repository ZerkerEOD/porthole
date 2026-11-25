package core

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/ZerkerEOD/porthole/daemon/internal/transcript"
)

// Permission modes as Claude Code names them in hook payloads and on the
// --permission-mode flag.
const (
	ModeDefault     = "default"
	ModeAcceptEdits = "acceptEdits"
	ModePlan        = "plan"
	ModeAuto        = "auto"
	ModeDontAsk     = "dontAsk"
	ModeBypass      = "bypassPermissions"
)

// modeCycle is the order Shift+Tab walks. bypassPermissions and auto are only
// in the cycle when the session has them; dontAsk never is. The CLI goes from
// the last available mode back to default.
var modeCycle = []string{ModeDefault, ModeAcceptEdits, ModePlan, ModeBypass, ModeAuto}

// modeLabels maps the status-bar text the CLI prints under the input box to
// the mode name. The bar reads e.g. "⏸ plan mode on (shift+tab to cycle)".
var modeLabels = []struct{ text, mode string }{
	{"manual mode on", ModeDefault},
	{"accept edits on", ModeAcceptEdits},
	{"plan mode on", ModePlan},
	{"auto mode on", ModeAuto},
	{"don't ask on", ModeDontAsk},
	{"bypass permissions on", ModeBypass},
}

// ValidMode reports whether m is a mode name the CLI accepts.
func ValidMode(m string) bool {
	switch m {
	case ModeDefault, ModeAcceptEdits, ModePlan, ModeAuto, ModeDontAsk, ModeBypass:
		return true
	}
	return false
}

// parseModeLine finds the permission-mode status bar in captured pane lines
// (ANSI may be present) and returns the mode it names. The bar is hidden
// while a dialog is open, so ok=false does not mean the mode changed.
func parseModeLine(raw []string) (mode string, ok bool) {
	for i := len(raw) - 1; i >= 0; i-- {
		l := strings.ToLower(strings.ReplaceAll(stripANSI(raw[i]), " ", " "))
		if !strings.Contains(l, "⏸") && !strings.Contains(l, "⏵⏵") {
			continue
		}
		for _, m := range modeLabels {
			if strings.Contains(l, m.text) {
				return m.mode, true
			}
		}
	}
	return "", false
}

// SetPermissionMode records the mode a hook or the screen reported.
func (r *Registry) SetPermissionMode(key, mode string) {
	if !ValidMode(mode) {
		return
	}
	s, ok := r.Get(key)
	if !ok || s.PermissionMode == mode {
		return
	}
	s.PermissionMode = mode
	r.upsert(s)
}

// modeStep is one Shift+Tab press followed by a read of the status bar; it
// returns the mode shown, or "" when the bar is not visible.
type modeStep func() (string, error)

// walkMode presses step until the bar shows target, giving up after limit
// presses. It returns the mode reached, so the caller can say how far the
// cycle got when the target is not in it.
func walkMode(target string, step modeStep, limit int) (string, error) {
	last := ""
	for i := 0; i < limit; i++ {
		got, err := step()
		if err != nil {
			return last, err
		}
		if got != "" {
			last = got
		}
		if got == target {
			return got, nil
		}
	}
	return last, fmt.Errorf("mode %s is not in this session's cycle (stopped at %s)", target, firstNonEmpty(last, "unknown"))
}

// SetMode switches a controllable Claude session to target by pressing
// Shift+Tab until the status bar names it. It refuses while a dialog is open,
// since Tab means something else there.
func (r *Registry) SetMode(ctx context.Context, key, target string) (string, error) {
	if !ValidMode(target) {
		return "", errors.New("unknown permission mode")
	}
	if target == ModeDontAsk {
		return "", errors.New("don't-ask mode can only be set when the session starts")
	}
	s, ok := r.Get(key)
	if !ok || !s.Controllable {
		return "", errors.New("session is not controllable")
	}
	if s.Provider != "claude" {
		return "", errors.New("only Claude sessions have permission modes")
	}
	if s.Question != nil || s.Status == transcript.StatusWaitingPermission || r.perm.HasPending(key) {
		return "", errors.New("answer the open dialog first")
	}
	r.mu.Lock()
	if r.answering[key] {
		r.mu.Unlock()
		return "", errors.New("session is busy answering a dialog")
	}
	r.answering[key] = true
	r.mu.Unlock()
	defer func() {
		r.mu.Lock()
		delete(r.answering, key)
		r.mu.Unlock()
	}()
	read := func() (string, error) {
		scr, err := r.tm.Capture(ctx, s.PaneID, 0)
		if err != nil {
			return "", err
		}
		m, _ := parseModeLine(scr.Lines)
		return m, nil
	}
	start, err := read()
	if err != nil {
		return "", err
	}
	if start == "" {
		return "", errors.New("the mode bar is not visible; is a dialog open?")
	}
	if start == target {
		r.SetPermissionMode(key, start)
		return start, nil
	}
	step := func() (string, error) {
		if err := r.tm.SendKeys(ctx, s.PaneID, []string{"BTab"}); err != nil {
			return "", err
		}
		time.Sleep(modeSettle)
		return read()
	}
	got, err := walkMode(target, step, len(modeCycle)+1)
	if err != nil && got != "" && got != start {
		// The target is not in this session's cycle: go back to where the
		// session was rather than leave it in whatever mode the walk ended on.
		if back, berr := walkMode(start, step, len(modeCycle)+1); berr == nil {
			got = back
		}
	}
	if got != "" {
		r.SetPermissionMode(key, got)
	}
	if err != nil {
		return got, err
	}
	r.log.Info("mode set", "session", key, "mode", got)
	return got, nil
}

// modeSettle is how long the CLI takes to redraw the bar after Shift+Tab.
var modeSettle = 150 * time.Millisecond
