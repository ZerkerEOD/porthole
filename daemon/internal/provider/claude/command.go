package claude

import (
	"strings"

	"github.com/ZerkerEOD/porthole/daemon/internal/transcript"
)

// maxCommandOutput caps the stdout and stderr carried by one command event.
const maxCommandOutput = 20 * 1024

// commandRecord recognizes the user records Claude Code writes for a "!"
// shell command and for slash-command output, and turns them into command
// events. ok is false for any other text.
//
// A "!" command is written as a <bash-input> record followed by a record
// holding <bash-stdout> and <bash-stderr> whose parentUuid is the input's
// uuid. The input is held until that output arrives so the pair becomes one
// event carrying the input record's id and time.
func (p *Parser) commandRecord(e entry, base transcript.Event, text string) ([]transcript.Event, bool) {
	t := strings.TrimSpace(text)
	switch {
	case strings.HasPrefix(t, "<bash-input>"):
		ev := base
		ev.Type = transcript.TypeCommand
		ev.Text, ev.Truncated = transcript.Clip(strings.TrimSpace(rawTag(t, "bash-input")))
		ev.Meta = map[string]any{"source": "bang", "stdout": "", "stderr": ""}
		if strings.Contains(t, "<bash-stdout>") || strings.Contains(t, "<bash-stderr>") {
			fillOutput(&ev, t)
			return []transcript.Event{ev}, true
		}
		var out []transcript.Event
		if p.bang != nil {
			out = append(out, *p.bang)
		}
		p.bang = &ev
		return out, true
	case strings.HasPrefix(t, "<bash-stdout>"), strings.HasPrefix(t, "<bash-stderr>"):
		if p.bang != nil && p.bang.ID != "" && p.bang.ID == e.ParentUUID {
			ev := *p.bang
			p.bang = nil
			fillOutput(&ev, t)
			return []transcript.Event{ev}, true
		}
		// Output without its command (the input record was before the
		// window read): show the output alone.
		ev := base
		ev.Type = transcript.TypeCommand
		ev.Meta = map[string]any{"source": "bang"}
		fillOutput(&ev, t)
		return []transcript.Event{ev}, true
	case strings.HasPrefix(t, "<local-command-stdout>"), strings.HasPrefix(t, "<local-command-stderr>"):
		ev := base
		ev.Type = transcript.TypeCommand
		meta := map[string]any{"source": "slash", "stdout": capOutput(strings.TrimSpace(rawTag(t, "local-command-stdout")))}
		if se := strings.TrimSpace(rawTag(t, "local-command-stderr")); se != "" {
			meta["stderr"] = capOutput(se)
		}
		ev.Meta = meta
		return []transcript.Event{ev}, true
	}
	return nil, false
}

// fillOutput copies the <bash-stdout> and <bash-stderr> sections of t into
// ev's meta, trimmed and capped.
func fillOutput(ev *transcript.Event, t string) {
	ev.Meta["stdout"] = capOutput(strings.TrimSpace(rawTag(t, "bash-stdout")))
	ev.Meta["stderr"] = capOutput(strings.TrimSpace(rawTag(t, "bash-stderr")))
}

// rawTag returns the text between the first <tag> and the last </tag> of s,
// as written (command text and output are not entity-escaped in the
// transcript).
func rawTag(s, tag string) string {
	open, end := "<"+tag+">", "</"+tag+">"
	i := strings.Index(s, open)
	if i < 0 {
		return ""
	}
	rest := s[i+len(open):]
	j := strings.LastIndex(rest, end)
	if j < 0 {
		return rest
	}
	return rest[:j]
}

// capOutput keeps the first maxCommandOutput bytes of s, cut on a rune
// boundary, and marks the cut.
func capOutput(s string) string {
	if len(s) <= maxCommandOutput {
		return s
	}
	cut := maxCommandOutput
	for cut > 0 && (s[cut]&0xC0) == 0x80 {
		cut--
	}
	return s[:cut] + "\n[…]"
}
