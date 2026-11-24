package core

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/ZerkerEOD/porthole/daemon/internal/tmux"
	"github.com/ZerkerEOD/porthole/daemon/internal/transcript"
)

// A lost dialog (daemon restart, missed hook, a scan that dropped it) is
// read back off the pane. The CLI draws it as, once ANSI is stripped:
//
//	←  ☒ Header  ☐ Header  ✔ Submit  →   tab row; multi-question dialogs only
//	│ Question text, wrapped over        one or more lines
//	│ more lines
//	❯ 1. Label                           options; multi-select rows carry [ ] / [✔]
//	     Description                     indented lines up to the next row
//	  2. Label
//	  3. Type something.                 free-text row ("[ ] Type something" plus an
//	     Next                            unnumbered Next/Submit row in a multi select)
//	────────────────────────────────
//	  4. Chat about this
//	Enter to select · Tab/Arrow keys to navigate · Esc to cancel
//
// Only the current question is visible, so a recovered dialog is served one
// question at a time: Question.Recovered is set and Remaining counts the
// unanswered tabs that follow.

var (
	optionRowRe = regexp.MustCompile(`^\s*(?:❯\s*)?(\d+)\.\s+(?:\[([ ✔xX])\]\s+)?(.*)$`)
	typeRowRe   = regexp.MustCompile(`^\s*(?:❯\s*)?(\d+)\.\s+(?:\[[ ✔xX]\]\s+)?Type something\.?\s*$`)
	tabRe       = regexp.MustCompile(`([☐☒✔])\s*([^☐☒✔←→]*)`)
	selectAllRe = regexp.MustCompile(`\s*\(Select all that apply\)\.?`)
)

const submitTab = "Submit"

// parseDialog reads the question dialog off captured pane lines (ANSI may be
// present). It returns the visible question and how many unanswered
// questions follow it, or ok=false when no dialog is on screen.
func parseDialog(raw []string) (item QuestionItem, remaining int, ok bool) {
	lines := make([]string, len(raw))
	for i, l := range raw {
		// The CLI pads with no-break spaces, which \s does not match.
		lines[i] = strings.TrimRight(strings.ReplaceAll(stripANSI(l), "\u00a0", " "), " ")
	}
	// The free-text row ends the option list; the last one on screen is the
	// live dialog.
	typeIdx := -1
	for i := len(lines) - 1; i >= 0; i-- {
		if typeRowRe.MatchString(lines[i]) {
			typeIdx = i
			break
		}
	}
	if typeIdx < 0 {
		return item, 0, false
	}
	n, _ := strconv.Atoi(typeRowRe.FindStringSubmatch(lines[typeIdx])[1])
	if n < 2 {
		return item, 0, false
	}
	// Options are numbered n-1 down to 1 above the row; whatever else sits
	// between two rows describes the option above it.
	opts := make([]QuestionOption, n-1)
	want := n - 1
	first := -1
	var desc []string
	for i := typeIdx - 1; i >= 0 && want > 0; i-- {
		l := lines[i]
		if strings.TrimSpace(l) == "" {
			continue
		}
		m := optionRowRe.FindStringSubmatch(l)
		if m == nil {
			desc = append([]string{l}, desc...)
			continue
		}
		if k, _ := strconv.Atoi(m[1]); k != want {
			desc = append([]string{l}, desc...)
			continue
		}
		if m[2] != "" {
			item.MultiSelect = true
		}
		opts[want-1] = QuestionOption{Label: collapse(m[3]), Description: collapse(strings.Join(desc, " "))}
		desc = nil
		want--
		first = i
	}
	if want > 0 {
		return item, 0, false
	}
	// The question is the text block above the first option; blank lines
	// may separate it from the options and from the tab row.
	qEnd := first
	for qEnd > 0 && strings.TrimSpace(lines[qEnd-1]) == "" {
		qEnd--
	}
	qStart := qEnd
	for qStart > 0 && questionLine(lines[qStart-1]) {
		qStart--
	}
	if qStart == qEnd {
		return item, 0, false
	}
	var parts []string
	for _, l := range lines[qStart:qEnd] {
		parts = append(parts, strings.TrimPrefix(strings.TrimSpace(l), "│"))
	}
	question := collapse(strings.Join(parts, " "))
	if loc := selectAllRe.FindStringIndex(question); loc != nil {
		question = collapse(question[:loc[0]] + question[loc[1]:])
		item.MultiSelect = true
	}
	item.Question, item.Options = question, opts
	// Tab row, when there is one: the line above the question.
	for i := qStart - 1; i >= 0; i-- {
		if strings.TrimSpace(lines[i]) == "" {
			continue
		}
		if tabRow(lines[i]) {
			item.Header, remaining = parseTabs(raw[i], lines[i])
		}
		break
	}
	return item, remaining, true
}

// questionLine reports whether l can be part of the question text: not
// blank, not a rule, not the tab row, and not CLI chrome.
func questionLine(l string) bool {
	t := strings.TrimSpace(l)
	if t == "" || tabRow(l) || strings.Trim(t, "─") == "" {
		return false
	}
	for _, p := range []string{"●", "❯", "⎿", "✻", "⏵"} {
		if strings.HasPrefix(t, p) {
			return false
		}
	}
	return true
}

func tabRow(l string) bool {
	return strings.ContainsAny(l, "☐☒✔") && (strings.Contains(l, "←") || strings.Contains(l, "→"))
}

// parseTabs reads the tab row: the current tab's label (the highlighted
// one, else the first unanswered) and how many other tabs are unanswered.
// Answered tabs show ☒ (or ✔); the trailing Submit tab is not a question.
func parseTabs(raw, plain string) (header string, remaining int) {
	type tab struct {
		label    string
		answered bool
		pos      int
	}
	var tabs []tab
	for _, m := range tabRe.FindAllStringSubmatchIndex(plain, -1) {
		tabs = append(tabs, tab{label: strings.TrimSpace(plain[m[4]:m[5]]), answered: plain[m[2]:m[3]] != "☐", pos: m[2]})
	}
	if n := len(tabs); n > 0 && strings.EqualFold(tabs[n-1].label, submitTab) {
		tabs = tabs[:n-1]
	}
	if len(tabs) == 0 {
		return "", 0
	}
	cur := -1
	hl := highlighted(raw)
	for i, t := range tabs {
		if at := utf8Index(plain, t.pos); at < len(hl) && hl[at] {
			if cur >= 0 {
				cur = -1
				break
			}
			cur = i
		}
	}
	if cur < 0 {
		cur = 0
		for i, t := range tabs {
			if !t.answered {
				cur = i
				break
			}
		}
	}
	for i, t := range tabs {
		if i != cur && !t.answered {
			remaining++
		}
	}
	return tabs[cur].label, remaining
}

// utf8Index converts a byte offset in s to a rune index.
func utf8Index(s string, byteOff int) int {
	if byteOff > len(s) {
		byteOff = len(s)
	}
	return len([]rune(s[:byteOff]))
}

// highlighted flags, per rune of the ANSI-stripped line, whether a
// background color or inverse video was in effect.
func highlighted(raw string) []bool {
	var out []bool
	on := false
	for len(raw) > 0 {
		loc := ansiRe.FindStringIndex(raw)
		if loc == nil {
			for range raw {
				out = append(out, on)
			}
			break
		}
		for range raw[:loc[0]] {
			out = append(out, on)
		}
		seq := raw[loc[0]:loc[1]]
		if strings.HasSuffix(seq, "m") {
			on = sgrHighlight(seq[2:len(seq)-1], on)
		}
		raw = raw[loc[1]:]
	}
	return out
}

// sgrHighlight applies one SGR parameter list to the highlight state.
func sgrHighlight(params string, on bool) bool {
	if params == "" {
		return false
	}
	ps := strings.Split(params, ";")
	for i := 0; i < len(ps); i++ {
		n, err := strconv.Atoi(ps[i])
		if err != nil {
			continue
		}
		switch {
		case n == 0:
			on = false
		case n == 7:
			on = true
		case n == 27 || n == 49:
			on = false
		case n >= 40 && n <= 47, n >= 100 && n <= 107:
			on = true
		case n == 48:
			on = true
			if i+1 < len(ps) {
				switch ps[i+1] {
				case "5":
					i += 2
				case "2":
					i += 4
				}
			}
		case n == 38:
			if i+1 < len(ps) {
				switch ps[i+1] {
				case "5":
					i += 2
				case "2":
					i += 4
				}
			}
		}
	}
	return on
}

func newQuestionID() string {
	var rnd [8]byte
	_, _ = rand.Read(rnd[:])
	return hex.EncodeToString(rnd[:])
}

// recoverFromScreen publishes the dialog shown on scr as the session's
// pending question. replace is the id of a recovered question the new one
// supersedes; with replace "" a session that already holds a question is
// left alone. It returns nil when no dialog is on screen.
func (r *Registry) recoverFromScreen(key, replace string, scr *tmux.Screen) *Question {
	s, ok := r.Get(key)
	if !ok || !s.Controllable || (s.Question != nil && (replace == "" || s.Question.ID != replace)) {
		return nil
	}
	item, remaining, ok := parseDialog(scr.Lines)
	if !ok {
		return nil
	}
	q := &Question{ID: newQuestionID(), Questions: []QuestionItem{item}, SetAt: time.Now(), Recovered: true, Remaining: remaining}
	s.Question, s.Status, s.UpdatedAt = q, transcript.StatusWaitingInput, time.Now()
	r.upsert(s)
	r.log.Info("question recovered", "session", key, "id", q.ID, "remaining", remaining)
	r.gate.Question(key, questionText(q))
	return q
}

// recoverQuestion captures the session's pane and publishes the dialog on
// it, if any.
func (r *Registry) recoverQuestion(ctx context.Context, key string) *Question {
	s, ok := r.Get(key)
	if !ok || !s.Controllable || s.Question != nil {
		return nil
	}
	scr, err := r.tm.Capture(ctx, s.PaneID, 0)
	if err != nil {
		return nil
	}
	return r.recoverFromScreen(key, "", scr)
}

// recoverQuestions runs from the scan: controllable sessions that wait for
// input without a recorded question get their pane read once per tick.
func (r *Registry) recoverQuestions(ctx context.Context) {
	r.mu.RLock()
	var keys []string
	for k, s := range r.sessions {
		if s.Provider == "claude" && s.Running && s.Controllable && s.Question == nil && s.Status == transcript.StatusWaitingInput && !r.answering[k] {
			keys = append(keys, k)
		}
	}
	r.mu.RUnlock()
	for _, k := range keys {
		r.recoverQuestion(ctx, k)
	}
}
