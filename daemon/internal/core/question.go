package core

import (
	"context"
	"errors"
	"fmt"
	"regexp"
	"sort"
	"strings"
	"time"

	"github.com/ZerkerEOD/porthole/daemon/internal/tmux"
)

// Answer is one entry of question.answer, in question order: index for a
// single select, indices for a multi select, text for the free-text row.
type Answer struct {
	Index   *int   `json:"index,omitempty"`
	Indices []int  `json:"indices,omitempty"`
	Text    string `json:"text,omitempty"`
}

// AnswerResult is what question.answer returns.
type AnswerResult struct {
	OK     bool   `json:"ok"`
	Reason string `json:"reason,omitempty"`
}

const (
	keyGap       = 60 * time.Millisecond
	stepWait     = 1500 * time.Millisecond
	finalWait    = 3 * time.Second
	reviewTitle  = "Review your answers"
	reviewSubmit = "Submit answers"
	answeredLine = "User answered Claude's questions"
	dialogFooter = "Esc to cancel"
)

var ansiRe = regexp.MustCompile("\x1b\\[[0-9;?]*[ -/]*[@-~]")

// stripANSI removes CSI sequences from captured text.
func stripANSI(s string) string { return ansiRe.ReplaceAllString(s, "") }

// screenText flattens a capture to one whitespace-collapsed line so wrapped
// questions and labels match regardless of pane width.
func screenText(scr *tmux.Screen) string {
	var sb strings.Builder
	for _, l := range scr.Lines {
		sb.WriteString(stripANSI(l))
		sb.WriteByte(' ')
	}
	return collapse(sb.String())
}

func collapse(s string) string { return strings.Join(strings.Fields(s), " ") }

// lastLines returns the last n non-empty visible lines without ANSI.
func lastLines(scr *tmux.Screen, n int) string {
	var out []string
	for i := len(scr.Lines) - 1; i >= 0 && len(out) < n; i-- {
		if l := strings.TrimRight(stripANSI(scr.Lines[i]), " "); strings.TrimSpace(l) != "" {
			out = append([]string{l}, out...)
		}
	}
	return strings.Join(out, "\n")
}

// optionShown reports whether an option row of q is on screen.
func optionShown(text string, q QuestionItem) bool {
	for i, o := range q.Options {
		label := collapse(o.Label)
		n := fmt.Sprintf("%d. ", i+1)
		for _, row := range []string{n + label, n + "[ ] " + label, n + "[✔] " + label, n + "[x] " + label, n + "[X] " + label} {
			if strings.Contains(text, row) {
				return true
			}
		}
	}
	return false
}

// questionShown reports whether q's dialog is on screen.
func questionShown(text string, q QuestionItem) bool {
	return (questionTextShown(text, q) || collapse(q.Header) != "" && strings.Contains(text, collapse(q.Header))) && optionShown(text, q)
}

// questionTextShown reports whether q's question text is on screen; the
// header does not count, since the tab row lists every header.
func questionTextShown(text string, q QuestionItem) bool {
	return collapse(q.Question) != "" && strings.Contains(unboxed(text), collapse(q.Question))
}

// unboxed drops the "│" the CLI puts in front of each question line, so a
// wrapped question matches as one string.
func unboxed(text string) string { return collapse(strings.ReplaceAll(text, "│", " ")) }

func checkedCount(text string) int {
	return strings.Count(text, "[✔]") + strings.Count(text, "[x]") + strings.Count(text, "[X]")
}

// validateAnswers checks shape and ranges before any key is pressed.
func validateAnswers(q *Question, answers []Answer) error {
	if len(answers) != len(q.Questions) {
		return fmt.Errorf("expected %d answers, got %d", len(q.Questions), len(answers))
	}
	for i, a := range answers {
		item := q.Questions[i]
		n := len(item.Options)
		if item.MultiSelect {
			if a.Index != nil {
				return fmt.Errorf("question %d is multi-select: use indices", i+1)
			}
			if len(a.Indices) == 0 && a.Text == "" {
				return fmt.Errorf("question %d has no selection", i+1)
			}
			seen := map[int]bool{}
			for _, ix := range a.Indices {
				if ix < 0 || ix >= n || seen[ix] {
					return fmt.Errorf("question %d: index %d out of range", i+1, ix)
				}
				seen[ix] = true
			}
		} else {
			if len(a.Indices) > 0 {
				return fmt.Errorf("question %d is single-select: use index", i+1)
			}
			if (a.Index == nil) == (a.Text == "") {
				return fmt.Errorf("question %d needs exactly one of index or text", i+1)
			}
			if a.Index != nil && (*a.Index < 0 || *a.Index >= n) {
				return fmt.Errorf("question %d: index %d out of range", i+1, *a.Index)
			}
		}
	}
	return nil
}

// questionDriver presses keys in one pane and watches the screen.
type questionDriver struct {
	r    *Registry
	key  string
	pane string
	ctx  context.Context
	last *tmux.Screen
}

func (d *questionDriver) press(k string) error {
	if err := d.r.tm.SendKeys(d.ctx, d.pane, []string{k}); err != nil {
		return err
	}
	time.Sleep(keyGap)
	return nil
}

func (d *questionDriver) pressN(k string, n int) error {
	for i := 0; i < n; i++ {
		if err := d.press(k); err != nil {
			return err
		}
	}
	return nil
}

func (d *questionDriver) typeText(text string) error {
	text = strings.Join(strings.Fields(strings.ReplaceAll(text, "\n", " ")), " ")
	if text == "" {
		return errors.New("empty text")
	}
	if err := d.r.tm.SendText(d.ctx, d.pane, text, false); err != nil {
		return err
	}
	time.Sleep(keyGap)
	return nil
}

// capture returns the visible screen as collapsed text.
func (d *questionDriver) capture() (string, error) {
	scr, err := d.r.tm.Capture(d.ctx, d.pane, 0)
	if err != nil {
		return "", err
	}
	d.last = scr
	return screenText(scr), nil
}

// waitFor polls the screen until pred returns a non-empty state or the
// budget is spent; it returns the state.
func (d *questionDriver) waitFor(budget time.Duration, pred func(text string) string) (string, error) {
	deadline := time.Now().Add(budget)
	for {
		text, err := d.capture()
		if err != nil {
			return "", err
		}
		if st := pred(text); st != "" {
			return st, nil
		}
		if time.Now().After(deadline) {
			return "", nil
		}
		time.Sleep(100 * time.Millisecond)
	}
}

// cleared reports whether the registry no longer holds question id for the
// session: its tool result reached the transcript.
func (d *questionDriver) cleared(id string) bool {
	s, ok := d.r.Get(d.key)
	return !ok || s.Question == nil || s.Question.ID != id
}

func (d *questionDriver) unexpected() AnswerResult {
	tail := ""
	if d.last != nil {
		tail = lastLines(d.last, 5)
	}
	return AnswerResult{Reason: "unexpected screen:\n" + tail}
}

// AnswerQuestion drives the AskUserQuestion dialog in the session's pane.
// It never returns an error for a dialog that is not where it expects it;
// the result's reason says what the screen showed instead.
func (r *Registry) AnswerQuestion(ctx context.Context, key, id string, answers []Answer) (AnswerResult, error) {
	s, ok := r.Get(key)
	if !ok || !s.Controllable {
		return AnswerResult{}, errors.New("session is not controllable")
	}
	if s.Question == nil || s.Question.ID != id {
		return AnswerResult{Reason: "no pending question with that id"}, nil
	}
	q := s.Question
	if err := validateAnswers(q, answers); err != nil {
		return AnswerResult{Reason: err.Error()}, nil
	}
	r.mu.Lock()
	r.answering[key] = true
	r.mu.Unlock()
	defer func() {
		r.mu.Lock()
		delete(r.answering, key)
		r.mu.Unlock()
	}()
	d := &questionDriver{r: r, key: key, pane: s.PaneID, ctx: ctx}
	text, err := d.capture()
	if err != nil {
		return AnswerResult{}, err
	}
	if !questionShown(text, q.Questions[0]) {
		return AnswerResult{Reason: "question is not on screen"}, nil
	}
	answered := strings.Count(text, answeredLine)
	r.log.Info("question answer", "session", key, "id", id, "questions", len(q.Questions), "recovered", q.Recovered)
	done := func(text string) string {
		if strings.Count(text, answeredLine) > answered || (d.cleared(id) && !strings.Contains(text, dialogFooter)) {
			return "done"
		}
		return ""
	}
	if q.Recovered {
		return r.answerRecovered(d, q, answers[0], done)
	}
	for i, item := range q.Questions {
		res, err := d.answerOne(item, answers[i])
		if err != nil {
			return AnswerResult{}, err
		}
		if !res.OK {
			return res, nil
		}
		next := func(text string) string {
			if st := done(text); st != "" {
				return st
			}
			if strings.Contains(text, reviewTitle) || strings.Contains(text, reviewSubmit) {
				return "review"
			}
			if i+1 < len(q.Questions) && questionShown(text, q.Questions[i+1]) {
				return "next"
			}
			return ""
		}
		st, err := d.waitFor(stepWait, next)
		if err != nil {
			return AnswerResult{}, err
		}
		switch st {
		case "next":
			continue
		case "done":
			return AnswerResult{OK: true}, nil
		case "review":
			if err := d.press("Enter"); err != nil {
				return AnswerResult{}, err
			}
			st, err = d.waitFor(finalWait, done)
			if err != nil {
				return AnswerResult{}, err
			}
			if st == "done" {
				return AnswerResult{OK: true}, nil
			}
			return d.unexpected(), nil
		default:
			if i+1 == len(q.Questions) {
				// A single question submits straight away; give it a moment.
				if st, _ := d.waitFor(finalWait, done); st == "done" {
					return AnswerResult{OK: true}, nil
				}
			}
			return d.unexpected(), nil
		}
	}
	return d.unexpected(), nil
}

// answerRecovered answers the one question a recovered dialog shows. The
// dialog then either submits, moves to the review screen (submitted here),
// or draws the next question, which is published as a new pending question.
func (r *Registry) answerRecovered(d *questionDriver, q *Question, a Answer, done func(string) string) (AnswerResult, error) {
	item := q.Questions[0]
	res, err := d.answerOne(item, a)
	if err != nil || !res.OK {
		return res, err
	}
	st, err := d.waitFor(stepWait, func(text string) string {
		if st := done(text); st != "" {
			return st
		}
		if strings.Contains(text, reviewTitle) || strings.Contains(text, reviewSubmit) {
			return "review"
		}
		if !questionTextShown(text, item) {
			return "next"
		}
		return ""
	})
	if err != nil {
		return AnswerResult{}, err
	}
	switch st {
	case "done":
		r.ClearQuestion(d.key, q.ID)
		return AnswerResult{OK: true}, nil
	case "review":
		if err := d.press("Enter"); err != nil {
			return AnswerResult{}, err
		}
	case "":
		if q.Remaining > 0 {
			return d.unexpected(), nil
		}
		// A lone question submits straight away; give it a moment.
		if st, err = d.waitFor(finalWait, done); err != nil {
			return AnswerResult{}, err
		}
		if st == "done" {
			r.ClearQuestion(d.key, q.ID)
			return AnswerResult{OK: true}, nil
		}
		return d.unexpected(), nil
	}
	// The dialog moved on: wait for the submission or for the next question.
	st, err = d.waitFor(finalWait, func(text string) string {
		if st := done(text); st != "" {
			return st
		}
		if _, _, ok := parseDialog(d.last.Lines); ok {
			return "dialog"
		}
		return ""
	})
	if err != nil {
		return AnswerResult{}, err
	}
	switch st {
	case "done":
		r.ClearQuestion(d.key, q.ID)
		return AnswerResult{OK: true}, nil
	case "dialog":
		if r.recoverFromScreen(d.key, q.ID, d.last) != nil {
			return AnswerResult{OK: true}, nil
		}
	}
	r.ClearQuestion(d.key, q.ID)
	return d.unexpected(), nil
}

// answerOne presses the keys for one question. The cursor starts on the
// first option; rows are the options, then the free-text row, then (for a
// multi select) Submit.
func (d *questionDriver) answerOne(item QuestionItem, a Answer) (AnswerResult, error) {
	n := len(item.Options)
	cur := 0
	moveTo := func(row int) error {
		var err error
		if row > cur {
			err = d.pressN("Down", row-cur)
		} else if row < cur {
			err = d.pressN("Up", cur-row)
		}
		cur = row
		return err
	}
	if !item.MultiSelect {
		if a.Text != "" {
			if err := moveTo(n); err != nil {
				return AnswerResult{}, err
			}
			if err := d.typeText(a.Text); err != nil {
				return AnswerResult{}, err
			}
		} else if err := moveTo(*a.Index); err != nil {
			return AnswerResult{}, err
		}
		return AnswerResult{OK: true}, d.press("Enter")
	}
	ix := append([]int(nil), a.Indices...)
	sort.Ints(ix)
	want := checkedCount(screenTextOrEmpty(d))
	for _, row := range ix {
		if err := moveTo(row); err != nil {
			return AnswerResult{}, err
		}
		if err := d.press("Space"); err != nil {
			return AnswerResult{}, err
		}
		want++
		st, err := d.waitFor(stepWait, func(text string) string {
			if checkedCount(text) >= want {
				return "ok"
			}
			return ""
		})
		if err != nil {
			return AnswerResult{}, err
		}
		if st == "" {
			return AnswerResult{Reason: "multi-select could not be confirmed"}, nil
		}
	}
	if a.Text != "" {
		if err := moveTo(n); err != nil {
			return AnswerResult{}, err
		}
		if err := d.typeText(a.Text); err != nil {
			return AnswerResult{}, err
		}
	}
	if err := moveTo(n + 1); err != nil {
		return AnswerResult{}, err
	}
	return AnswerResult{OK: true}, d.press("Enter")
}

func screenTextOrEmpty(d *questionDriver) string {
	if d.last == nil {
		return ""
	}
	return screenText(d.last)
}
