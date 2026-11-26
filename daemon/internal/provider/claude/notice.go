package claude

import (
	"fmt"
	"html"
	"strconv"
	"strings"

	"github.com/ZerkerEOD/porthole/daemon/internal/transcript"
)

// taskNotice turns a queued <task-notification> (a background agent or
// command finished) into a system event. The same notice is also written
// later as a user record when the model reads it; isSystemInjected hides
// that copy so the notice shows once.
func taskNotice(e entry, base transcript.Event) (transcript.Event, bool) {
	s := contentText(e.Content)
	if !strings.Contains(s, "<task-notification>") {
		return transcript.Event{}, false
	}
	taskID := tagText(s, "task-id")
	status := tagText(s, "status")
	summary := tagText(s, "summary")
	isAgent := strings.HasPrefix(summary, `Agent "`)
	// The usage block follows the agent's free-form result; read it from
	// the last <usage> so text inside the result cannot shadow it.
	usage := ""
	if i := strings.LastIndex(s, "<usage>"); i >= 0 {
		usage = s[i:]
	}

	ev := base
	ev.Type = transcript.TypeSystem
	ev.ID = "task:" + taskID + ":" + status
	ev.Level = "info"
	if status != "" && status != "completed" {
		ev.Level = "warn"
	}
	parts := []string{summary}
	if summary == "" {
		parts[0] = "Background task " + firstNonBlank(status, "finished")
	}
	if n, err := strconv.ParseInt(tagText(usage, "subagent_tokens"), 10, 64); err == nil {
		parts = append(parts, humanTokens(n)+" tokens")
	}
	if n, err := strconv.Atoi(tagText(usage, "tool_uses")); err == nil {
		unit := "tool uses"
		if n == 1 {
			unit = "tool use"
		}
		parts = append(parts, strconv.Itoa(n)+" "+unit)
	}
	if n, err := strconv.ParseInt(tagText(usage, "duration_ms"), 10, 64); err == nil {
		parts = append(parts, humanDuration(n))
	}
	ev.Text, ev.Truncated = transcript.Clip(strings.Join(parts, " · "))
	meta := map[string]any{"kind": "task_notification", "status": status}
	if taskID != "" {
		meta["task_id"] = taskID
	}
	if id := tagText(s, "tool-use-id"); id != "" {
		meta["tool_use_id"] = id
	}
	if isAgent {
		ev.AgentID = taskID
	}
	ev.Meta = meta
	return ev, true
}

// tagText returns the unescaped text of the first <tag>...</tag> in s.
func tagText(s, tag string) string {
	open, end := "<"+tag+">", "</"+tag+">"
	i := strings.Index(s, open)
	if i < 0 {
		return ""
	}
	rest := s[i+len(open):]
	j := strings.Index(rest, end)
	if j < 0 {
		return ""
	}
	return strings.TrimSpace(html.UnescapeString(rest[:j]))
}

func firstNonBlank(ss ...string) string {
	for _, s := range ss {
		if strings.TrimSpace(s) != "" {
			return s
		}
	}
	return ""
}

// humanTokens renders a token count as 850, 64k or 1.2M.
func humanTokens(n int64) string {
	switch {
	case n < 1000:
		return strconv.FormatInt(n, 10)
	case n < 999_500:
		return strconv.FormatInt((n+500)/1000, 10) + "k"
	default:
		return strings.TrimSuffix(fmt.Sprintf("%.1f", float64(n)/1e6), ".0") + "M"
	}
}

// humanDuration renders milliseconds as 45s, 1m 32s or 1h 5m.
func humanDuration(ms int64) string {
	sec := (ms + 500) / 1000
	switch {
	case sec < 60:
		return strconv.FormatInt(sec, 10) + "s"
	case sec < 3600:
		return fmt.Sprintf("%dm %ds", sec/60, sec%60)
	default:
		return fmt.Sprintf("%dh %dm", sec/3600, (sec%3600)/60)
	}
}
