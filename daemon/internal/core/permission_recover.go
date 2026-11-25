package core

import (
	"context"
	"crypto/sha1"
	"encoding/hex"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/ZerkerEOD/porthole/daemon/internal/tmux"
	"github.com/ZerkerEOD/porthole/daemon/internal/transcript"
)

// A permission prompt the CLI draws in the terminal, once the PermissionRequest
// hook returned without a decision (nobody was watching, or the hook timed
// out). Stripped of ANSI it looks like:
//
//	────────────────────────────────
//	 Bash command                        header: the kind of action
//	 Tip: auto mode handles these …      skipped
//	 Create empty probe1.txt …           description
//	╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌
//	 │ touch …/probe1.txt                detail: the command, file content or plan
//	╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌
//	 Do you want to proceed?             prompt
//	 ❯ 1. Yes
//	   2. Yes, and always allow access to …
//	      from this project               wrapped option text
//	   3. Yes, and switch to auto mode · auto mode handles …
//	   4. No
//	 Esc to cancel · Tab to amend         footer
//
// File edits say "Create file" / "Do you want to create x?" with the content
// as detail. The plan approval dialog ("Ready to code?") keeps the plan in a
// scrolling box and ends with "ctrl+g to edit in Vim · <plan file>".
type permDialog struct {
	Tool        string   // header text: "Bash command", "Create file", "Plan approval"
	Description string   // lines between header and detail
	Detail      string   // command, content or plan text
	Prompt      string   // the question line above the options
	Options     []string // as numbered on screen
}

var (
	permOptionRe = regexp.MustCompile(`^\s*(?:❯\s*)?(\d+)\.\s+(.*\S)\s*$`)
	fullRuleRe   = regexp.MustCompile(`^\s*─{8,}\s*$`)
	detailRuleRe = regexp.MustCompile(`^\s*╌{8,}\s*$`)
	// Hints the CLI appends to an option, not part of its meaning.
	optionHintRe = regexp.MustCompile(`\s*·\s*auto mode handles these prompts for you$|\s*shift\+tab to approve with this feedback$`)
)

func permFooter(l string) bool {
	t := strings.TrimSpace(l)
	return strings.HasPrefix(t, "Esc to cancel") || strings.Contains(t, "ctrl+g to edit in Vim")
}

// parsePermissionDialog reads a permission prompt off captured pane lines
// (ANSI may be present). ok is false when none is on screen.
func parsePermissionDialog(raw []string) (d permDialog, ok bool) {
	lines := make([]string, len(raw))
	for i, l := range raw {
		lines[i] = strings.TrimRight(strings.ReplaceAll(stripANSI(l), " ", " "), " ")
	}
	footer := -1
	for i := len(lines) - 1; i >= 0; i-- {
		if permFooter(lines[i]) {
			footer = i
			break
		}
	}
	if footer < 0 {
		return d, false
	}
	// Options run upward from the footer to "1."; unnumbered lines between
	// two options continue the one above them.
	var opts []string
	var cont []string
	first := -1
	want := -1
	for i := footer - 1; i >= 0; i-- {
		l := lines[i]
		if strings.TrimSpace(l) == "" {
			if len(opts) > 0 || len(cont) > 0 {
				break
			}
			continue
		}
		m := permOptionRe.FindStringSubmatch(l)
		if m == nil {
			cont = append([]string{strings.TrimSpace(l)}, cont...)
			continue
		}
		n, _ := strconv.Atoi(m[1])
		if want < 0 {
			want = n
		}
		if n != want {
			return d, false
		}
		text := collapse(strings.Join(append([]string{m[2]}, cont...), " "))
		opts = append([]string{optionHintRe.ReplaceAllString(text, "")}, opts...)
		cont = nil
		first = i
		want--
		if n == 1 {
			break
		}
	}
	if first < 0 || want != 0 || len(opts) < 2 || !strings.HasPrefix(opts[0], "Yes") {
		return d, false
	}
	d.Options = opts
	if planOptions(opts) {
		d.Tool = "Plan approval"
	}
	// The prompt is the text just above the options.
	p := first - 1
	for p >= 0 && strings.TrimSpace(lines[p]) == "" {
		p--
	}
	if p >= 0 && strings.HasSuffix(strings.TrimSpace(lines[p]), "?") {
		d.Prompt = collapse(lines[p])
	}
	// Detail sits between the two ╌ rules nearest above the prompt; header
	// and description between the ─ rule above that and the first ╌ rule.
	close, open := -1, -1
	for i := p; i >= 0 && i > p-60; i-- {
		if detailRuleRe.MatchString(lines[i]) {
			if close < 0 {
				close = i
			} else {
				open = i
				break
			}
		}
	}
	if open < 0 {
		// No detail block: the header is whatever follows the rule above.
		for i := p; i >= 0 && i > p-10; i-- {
			if fullRuleRe.MatchString(lines[i]) {
				open = i
				break
			}
		}
		if open < 0 {
			return d, true
		}
		var head []string
		for _, l := range lines[open+1 : p] {
			if t := strings.TrimSpace(l); t != "" && !strings.HasPrefix(t, "Tip:") {
				head = append(head, collapse(l))
			}
		}
		if t, desc := splitHead(head); t != "" {
			d.Tool, d.Description = t, desc
		}
		return d, true
	}
	var detail []string
	for _, l := range lines[open+1 : close] {
		t := strings.TrimSpace(l)
		if t == "" {
			continue
		}
		detail = append(detail, strings.TrimSpace(strings.TrimPrefix(t, "│")))
	}
	d.Detail = strings.Join(detail, "\n")
	top := open
	for i := open - 1; i >= 0 && i > open-8; i-- {
		if fullRuleRe.MatchString(lines[i]) {
			break
		}
		top = i
	}
	var head []string
	for _, l := range lines[top:open] {
		if t := strings.TrimSpace(l); t != "" && !strings.HasPrefix(t, "Tip:") {
			head = append(head, collapse(l))
		}
	}
	if t, desc := splitHead(head); t != "" {
		d.Tool, d.Description = t, desc
	}
	return d, true
}

// splitHead names the dialog from its header lines.
func splitHead(head []string) (tool, desc string) {
	if len(head) == 0 {
		return "", ""
	}
	tool = head[0]
	if strings.HasPrefix(tool, "Ready to code") {
		tool = "Plan approval"
	}
	return tool, strings.Join(head[1:], " ")
}

// planOptions reports whether the options are the plan approval dialog's,
// for when its header has scrolled out of view.
func planOptions(opts []string) bool {
	for _, o := range opts {
		if strings.Contains(o, "manually approve edits") || strings.HasPrefix(o, "Tell Claude what to change") {
			return true
		}
	}
	return false
}

// hash identifies one drawing of the dialog, so a new prompt with the same
// options still reads as new.
func (d permDialog) hash() string {
	h := sha1.New()
	for _, s := range []string{d.Tool, d.Description, d.Detail, d.Prompt} {
		h.Write([]byte(s))
		h.Write([]byte{0})
	}
	for _, o := range d.Options {
		h.Write([]byte(o))
		h.Write([]byte{0})
	}
	return hex.EncodeToString(h.Sum(nil))[:12]
}

// recoverPermission publishes the dialog drawn on scr as a recovered
// permission request for the session, replacing an earlier recovered one
// whose screen changed, and clears a recovered request whose dialog is gone.
func (r *Registry) recoverPermission(key string, scr *tmux.Screen) {
	s, ok := r.Get(key)
	if !ok || !s.Controllable {
		return
	}
	d, shown := parsePermissionDialog(scr.Lines)
	cur := r.perm.recoveredFor(key)
	if !shown {
		if cur != nil {
			r.perm.dropRecovered(cur.ID, "gone")
		}
		return
	}
	id := "screen:" + key + ":" + d.hash()
	if cur != nil {
		if cur.ID == id {
			return
		}
		r.perm.dropRecovered(cur.ID, "replaced")
	}
	req := PermissionRequest{ID: id, SessionKey: key, ToolName: d.Tool, Cwd: s.Cwd, CreatedAt: time.Now(), Recovered: true, Prompt: d.Prompt, Description: d.Description, Detail: d.Detail, Options: d.Options}
	r.perm.addRecovered(req)
	if s.Status != transcript.StatusWaitingPermission {
		r.SetStatus(key, transcript.StatusWaitingPermission)
	}
	r.log.Info("permission dialog recovered", "session", key, "id", id, "tool", d.Tool, "options", len(d.Options))
}

// scanScreens runs from the scan tick for running controllable Claude
// sessions: one capture each feeds the mode bar, question recovery and
// permission dialog recovery.
func (r *Registry) scanScreens(ctx context.Context) {
	r.mu.RLock()
	type target struct {
		key, pane string
		question  bool
	}
	var ts []target
	for k, s := range r.sessions {
		if s.Provider != "claude" || !s.Running || !s.Controllable || s.PaneID == "" || r.answering[k] {
			continue
		}
		ts = append(ts, target{k, s.PaneID, s.Question == nil && s.Status == transcript.StatusWaitingInput})
	}
	r.mu.RUnlock()
	for _, t := range ts {
		scr, err := r.tm.Capture(ctx, t.pane, 0)
		if err != nil {
			continue
		}
		r.readScreen(t.key, scr, t.question)
	}
}

// readScreen applies what one capture of a session's pane shows.
func (r *Registry) readScreen(key string, scr *tmux.Screen, question bool) {
	if m, ok := parseModeLine(scr.Lines); ok {
		r.SetPermissionMode(key, m)
	}
	if r.perm.hasHookPending(key) {
		return // the terminal draws nothing while the hook is held
	}
	r.recoverPermission(key, scr)
	if question {
		r.recoverFromScreen(key, "", scr)
	}
}
