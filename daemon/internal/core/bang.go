package core

import (
	"context"
	"errors"
	"strings"
	"time"
)

// Claude Code runs a line as a shell command when "!" is typed into an empty
// input box: the box switches to shell mode ("! " prompt, "! for shell mode"
// under it) and Enter runs what follows. Typed in one burst with the command
// the "!" is taken for pasted text, and with unsent text already in the box
// it is just another character. So the daemon types it alone, reads the
// screen until shell mode shows, then types the command.

// bangWait is how long shell mode may take to show after "!" is typed, and
// bangSettle how long the typed command settles before Enter.
var bangWait, bangSettle = 1500 * time.Millisecond, 150 * time.Millisecond

// promptLine returns the text in the input box, or "" when it is empty or no
// prompt is visible: the last line starting with the prompt marker above the
// bottom rule.
func promptLine(raw []string) string {
	for i := len(raw) - 1; i >= 0; i-- {
		l := strings.TrimRight(strings.ReplaceAll(stripANSI(raw[i]), "\u00a0", " "), " ")
		t := strings.TrimLeft(l, " ")
		if strings.HasPrefix(t, "❯ ") || t == "❯" {
			return strings.TrimSpace(strings.TrimPrefix(t, "❯"))
		}
		if strings.HasPrefix(t, "! ") || t == "!" {
			return "!" + strings.TrimSpace(strings.TrimPrefix(t, "!"))
		}
	}
	return ""
}

// shellModeOn reports whether the input box is in shell mode.
func shellModeOn(raw []string) bool {
	for i := len(raw) - 1; i >= 0 && i >= len(raw)-6; i-- {
		l := strings.TrimSpace(stripANSI(raw[i]))
		if strings.HasPrefix(l, "! for shell mode") {
			return true
		}
	}
	return strings.HasPrefix(promptLine(raw), "!")
}

// sendBang runs command in the session's shell through the CLI's "!" prefix.
func (r *Registry) sendBang(ctx context.Context, key, pane, command string) error {
	command = strings.TrimSpace(command)
	if command == "" {
		return errors.New("empty command")
	}
	if strings.ContainsAny(command, "\n\r") {
		return errors.New("a ! command is a single line")
	}
	// Whether the box is empty cannot be told from the screen alone (the
	// CLI shows dim hints there), so type the "!" and let the screen say
	// whether shell mode came on. If it did not, the "!" landed as text and
	// is taken back out.
	if err := r.tm.SendText(ctx, pane, "!", false); err != nil {
		return err
	}
	deadline := time.Now().Add(bangWait)
	for {
		time.Sleep(100 * time.Millisecond)
		scr, err := r.tm.Capture(ctx, pane, 0)
		if err != nil {
			return err
		}
		if shellModeOn(scr.Lines) {
			break
		}
		if time.Now().After(deadline) {
			_ = r.tm.SendKeys(ctx, pane, []string{"BSpace"})
			return errors.New("the session did not switch to shell mode: it is busy, or the input box holds unsent text")
		}
	}
	if err := r.tm.SendText(ctx, pane, command, false); err != nil {
		return err
	}
	time.Sleep(bangSettle)
	r.log.Info("bang command", "session", key, "bytes", len(command))
	return r.tm.SendKeys(ctx, pane, []string{"Enter"})
}
