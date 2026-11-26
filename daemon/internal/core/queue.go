package core

import (
	"strings"
	"unicode/utf8"
)

// Claude Code keeps messages typed while a turn runs in a queue and draws
// them above the input box until the turn ends; they reach the transcript
// only when submitted. On screen (ANSI stripped), bottom up from the hint:
//
//	❯ Write a story about a lighthouse keeper.     <- the submitted prompt
//
//	❯ first queued message
//
//	❯ second queued message, a long one that
//	  wraps onto an indented line
//	  ctrl+x ctrl+s to send now                     <- the anchor
//
// The submitted prompt looks the same once the colours are stripped. What
// tells them apart is the colour: a queued line is dim throughout, the
// marker and the text in one style, while the submitted prompt switches to
// a brighter colour right after the marker. So a "❯" line whose text starts
// with an escape sequence ends the block.

const (
	queueHint     = "to send now" // "ctrl+x ctrl+s to send now"
	queueMax      = 20
	queueMaxBytes = 2000
)

// parseQueued returns the queued messages shown on the screen, in send
// order, or nil when none are shown.
func parseQueued(raw []string) []string {
	hint := -1
	for i := len(raw) - 1; i >= 0; i-- {
		t := strings.TrimSpace(strings.ReplaceAll(stripANSI(raw[i]), " ", " "))
		if strings.HasPrefix(t, "ctrl+") && strings.HasSuffix(t, queueHint) {
			hint = i
			break
		}
	}
	if hint < 0 {
		return nil
	}
	// Walk up over the block: queued "❯" lines, their indented
	// continuations and single blank lines between messages.
	top, blanks := hint, 0
walk:
	for i := hint - 1; i >= 0; i-- {
		l := strings.TrimRight(strings.ReplaceAll(stripANSI(raw[i]), "\u00a0", " "), " ")
		t := strings.TrimLeft(l, " ")
		switch {
		case t == "":
			if blanks++; blanks > 1 {
				break walk // a gap: the block ended
			}
			continue
		case strings.HasPrefix(t, "❯"):
			if !queuedStyle(raw[i]) {
				break walk // the submitted prompt
			}
		case len(l) == len(t):
			break walk // not indented: not part of the block
		}
		blanks, top = 0, i
	}
	var out []string
	for i := top; i < hint; i++ {
		l := strings.TrimRight(strings.ReplaceAll(stripANSI(raw[i]), " ", " "), " ")
		t := strings.TrimSpace(l)
		switch {
		case t == "":
		case strings.HasPrefix(t, "❯"):
			if len(out) == queueMax {
				return out
			}
			out = append(out, strings.TrimSpace(strings.TrimPrefix(t, "❯")))
		case len(out) > 0:
			// Continuation of the message above; one that precedes every
			// queued line belongs to the submitted prompt.
			out[len(out)-1] += " " + t
		}
	}
	for i, m := range out {
		out[i] = capQueued(m)
	}
	return out
}

// queuedStyle reports whether the text of a raw "❯" line continues in the
// marker's own style, as queued messages are drawn.
func queuedStyle(raw string) bool {
	i := strings.Index(raw, "❯")
	if i < 0 {
		return false
	}
	rest := strings.TrimLeft(raw[i+len("❯"):], "  ")
	return rest != "" && rest[0] != 0x1b
}

// capQueued truncates m to queueMaxBytes on a rune boundary.
func capQueued(m string) string {
	if len(m) <= queueMaxBytes {
		return m
	}
	cut := queueMaxBytes - len("…")
	for cut > 0 && !utf8.RuneStart(m[cut]) {
		cut--
	}
	return m[:cut] + "…"
}

// SetQueued records the queued messages read off a session's screen and
// publishes the session when they changed. Only running, controllable
// Claude sessions hold a queue.
func (r *Registry) SetQueued(key string, q []string) {
	s, ok := r.Get(key)
	if !ok {
		return
	}
	if s.Provider != "claude" || !s.Running || !s.Controllable {
		q = nil
	}
	// The submitted prompt is drawn directly above the queue until Claude
	// prints anything. The colour rule in parseQueued tells it apart; the
	// transcript gives a second, theme-independent check.
	if len(q) > 0 && s.LastPrompt != "" && firstLine(q[0], 120) == s.LastPrompt {
		q = q[1:]
	}
	if len(q) == 0 {
		q = nil
	}
	if sameStrings(s.Queued, q) {
		return
	}
	s.Queued = q
	r.upsert(s)
}

func sameStrings(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}
