// Package claude understands Claude Code: its transcript JSONL, its running
// sessions (`claude agents --json`), its profiles (CLAUDE_CONFIG_DIR) and its
// skills/commands. Nothing here talks to Anthropic.
package claude

import (
	"encoding/json"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/ZerkerEOD/porthole/daemon/internal/transcript"
)

// Parser converts Claude Code transcript lines into normalized events. It is
// stateful only to dedupe per-message usage; create one per file.
type Parser struct {
	seenUsage map[string]bool
	// bang holds a "!" command whose output record has not been read yet.
	// Claude Code writes the command and its output as two consecutive
	// user records; they become one command event.
	bang *transcript.Event
}

// NewParser returns a fresh parser.
func NewParser() *Parser { return &Parser{seenUsage: map[string]bool{}} }

// entry is the superset of fields we read from any transcript line.
type entry struct {
	Type       string          `json:"type"`
	UUID       string          `json:"uuid"`
	ParentUUID string          `json:"parentUuid"`
	Timestamp  string          `json:"timestamp"`
	Sidechain  bool            `json:"isSidechain"`
	AgentID    string          `json:"agentId"`
	SessionID  string          `json:"sessionId"`
	Cwd        string          `json:"cwd"`
	GitBranch  string          `json:"gitBranch"`
	Version    string          `json:"version"`
	Slug       string          `json:"slug"`
	IsMeta     bool            `json:"isMeta"`
	IsCompact  bool            `json:"isCompactSummary"`
	Message    json.RawMessage `json:"message"`
	Subtype    string          `json:"subtype"`
	Content    json.RawMessage `json:"content"`
	Level      string          `json:"level"`
	IsAPIError bool            `json:"isApiErrorMessage"`
	Error      json.RawMessage `json:"error"`
	Operation  string          `json:"operation"` // queue-operation records

	// ToolUseResult is the structured result Claude Code stores beside a
	// tool_result block; for the Agent tool it names the subagent.
	ToolUseResult json.RawMessage `json:"toolUseResult"`

	// Metadata entries.
	AITitle        string          `json:"aiTitle"`
	Summary        string          `json:"summary"`
	LastPrompt     string          `json:"lastPrompt"`
	PermissionMode string          `json:"permissionMode"`
	Mode           string          `json:"mode"`
	AgentName      string          `json:"agentName"`
	TotalCostUSD   float64         `json:"totalCostUSD"`
	CompactMeta    json.RawMessage `json:"compactMetadata"`
}

type message struct {
	ID         string          `json:"id"`
	Role       string          `json:"role"`
	Model      string          `json:"model"`
	Content    json.RawMessage `json:"content"`
	StopReason string          `json:"stop_reason"`
	Usage      *struct {
		Input         int64 `json:"input_tokens"`
		Output        int64 `json:"output_tokens"`
		CacheRead     int64 `json:"cache_read_input_tokens"`
		CacheCreation int64 `json:"cache_creation_input_tokens"`
	} `json:"usage"`
}

type block struct {
	Type      string          `json:"type"`
	Text      string          `json:"text"`
	Thinking  string          `json:"thinking"`
	ID        string          `json:"id"`
	Name      string          `json:"name"`
	Input     json.RawMessage `json:"input"`
	ToolUseID string          `json:"tool_use_id"`
	Content   json.RawMessage `json:"content"`
	IsError   bool            `json:"is_error"`
	Source    *imageSource    `json:"source"`
}

// imageSource is the source of an image block.
type imageSource struct {
	Type      string `json:"type"`
	MediaType string `json:"media_type"`
	Data      string `json:"data"`
}

// appendImage adds an image block to imgs, up to the per-event limit. An
// image larger than the inline limit keeps only its type and size.
func appendImage(imgs []transcript.Image, b block) []transcript.Image {
	if len(imgs) >= transcript.MaxImagesPerEvent || b.Source == nil || b.Source.Type != "base64" || b.Source.Data == "" {
		return imgs
	}
	size := transcript.Base64Size(b.Source.Data)
	img := transcript.Image{MediaType: b.Source.MediaType, Bytes: size}
	if size > transcript.MaxImageBytes {
		img.Omitted = true
	} else {
		img.Data = b.Source.Data
	}
	return append(imgs, img)
}

// contentImages returns the images in a content field that is a block list.
func contentImages(raw json.RawMessage) []transcript.Image {
	if len(raw) == 0 || raw[0] != '[' {
		return nil
	}
	var blocks []block
	if json.Unmarshal(raw, &blocks) != nil {
		return nil
	}
	var imgs []transcript.Image
	for _, b := range blocks {
		if b.Type == "image" {
			imgs = appendImage(imgs, b)
		}
	}
	return imgs
}

func parseTime(s string) time.Time {
	if s == "" {
		return time.Time{}
	}
	t, err := time.Parse(time.RFC3339Nano, s)
	if err != nil {
		return time.Time{}
	}
	return t
}

// ParseLine implements transcript.Parser.
func (p *Parser) ParseLine(line []byte) ([]transcript.Event, error) {
	held := p.bang
	evs, err := p.parseLine(line)
	if held != nil && p.bang == held {
		// The record after a "!" command was not its output (the command
		// was interrupted, or the CLI wrote something in between): show the
		// command without output rather than hold it back.
		p.bang = nil
		evs = append([]transcript.Event{*held}, evs...)
	}
	return evs, err
}

func (p *Parser) parseLine(line []byte) ([]transcript.Event, error) {
	var e entry
	if err := json.Unmarshal(line, &e); err != nil {
		return nil, err
	}
	base := transcript.Event{
		TS:        parseTime(e.Timestamp),
		ID:        e.UUID,
		ParentID:  e.ParentUUID,
		Sidechain: e.Sidechain,
		AgentID:   e.AgentID,
	}
	switch e.Type {
	case "user":
		return p.parseUser(e, base)
	case "assistant":
		return p.parseAssistant(e, base)
	case "system":
		return p.parseSystem(e, base)
	case "ai-title":
		return []transcript.Event{meta(base, map[string]any{"title": e.AITitle})}, nil
	case "summary":
		if e.Summary != "" {
			return []transcript.Event{meta(base, map[string]any{"title": e.Summary})}, nil
		}
	case "last-prompt":
		return []transcript.Event{meta(base, map[string]any{"last_prompt": e.LastPrompt})}, nil
	case "permission-mode":
		return []transcript.Event{meta(base, map[string]any{"permission_mode": e.PermissionMode})}, nil
	case "agent-name":
		return []transcript.Event{meta(base, map[string]any{"name": e.AgentName})}, nil
	case "cost-state":
		ev := base
		ev.Type = transcript.TypeUsage
		ev.Usage = &transcript.Usage{TotalCostUSD: e.TotalCostUSD}
		ev.Meta = map[string]any{"total": true}
		return []transcript.Event{ev}, nil
	case "queue-operation":
		if e.Operation == "enqueue" {
			if ev, ok := taskNotice(e, base); ok {
				return []transcript.Event{ev}, nil
			}
		}
	}
	// mode, atis-latch, attachment, other queue operations, file-history-*: not shown.
	return nil, nil
}

func meta(base transcript.Event, m map[string]any) transcript.Event {
	base.Type = transcript.TypeMeta
	base.Meta = m
	return base
}

func (p *Parser) parseUser(e entry, base transcript.Event) ([]transcript.Event, error) {
	var m message
	if err := json.Unmarshal(e.Message, &m); err != nil {
		return nil, err
	}
	if e.IsCompact {
		ev := base
		ev.Type = transcript.TypeCompact
		ev.Text, ev.Truncated = transcript.Clip(contentText(m.Content))
		return []transcript.Event{ev}, nil
	}
	if e.IsMeta {
		return nil, nil
	}
	var out []transcript.Event
	// Content is either a plain string (typed prompt) or a block list.
	var s string
	if err := json.Unmarshal(m.Content, &s); err == nil {
		if evs, ok := p.commandRecord(e, base, s); ok {
			return evs, nil
		}
		ev := base
		ev.Type = transcript.TypeUser
		ev.Text, ev.Truncated = transcript.Clip(s)
		if isSystemInjected(s) {
			return nil, nil
		}
		return []transcript.Event{ev}, nil
	}
	var blocks []block
	if err := json.Unmarshal(m.Content, &blocks); err != nil {
		return nil, nil
	}
	agentID := resultAgentID(e.ToolUseResult)
	var text strings.Builder
	var imgs []transcript.Image
	for _, b := range blocks {
		switch b.Type {
		case "text":
			if text.Len() > 0 {
				text.WriteString("\n\n")
			}
			text.WriteString(b.Text)
		case "image":
			if text.Len() > 0 {
				text.WriteString("\n\n")
			}
			// The marker stays for apps that do not show images.
			text.WriteString("_[image attached]_")
			imgs = appendImage(imgs, b)
		case "tool_result":
			ev := base
			ev.Type = transcript.TypeToolResult
			ev.Result = &transcript.ToolResult{ToolUseID: b.ToolUseID, IsError: b.IsError}
			ev.Text, ev.Truncated = transcript.Clip(contentText(b.Content))
			ev.Images = contentImages(b.Content)
			if agentID != "" {
				ev.Meta = map[string]any{"agent_id": agentID}
			}
			out = append(out, ev)
		}
	}
	if evs, ok := p.commandRecord(e, base, text.String()); ok {
		return append(evs, out...), nil
	}
	if t := unwrapPasted(text.String()); strings.TrimSpace(t) != "" && !isSystemInjected(t) {
		ev := base
		ev.Type = transcript.TypeUser
		ev.Text, ev.Truncated = transcript.Clip(t)
		ev.Images = imgs
		out = append([]transcript.Event{ev}, out...)
	}
	return out, nil
}

// resultAgentID returns the subagent id an Agent tool result names, if any.
func resultAgentID(raw json.RawMessage) string {
	if len(raw) == 0 || raw[0] != '{' {
		return ""
	}
	var r struct {
		AgentID string `json:"agentId"`
	}
	if json.Unmarshal(raw, &r) != nil {
		return ""
	}
	return r.AgentID
}

// isSystemInjected recognizes harness-generated "user" lines that are not the
// human's words (reminders, interruption notices, command echoes).
// pastedRe matches the envelope the CLI wraps around text that arrived as a
// terminal paste (bracketed paste), including the message the daemon types
// back after a run. The model sees the envelope; the person need not.
var pastedRe = regexp.MustCompile(`(?s)<pasted_content id="[^"]*">\n?(.*?)\n?</pasted_content[^>]*>`)

// unwrapPasted removes pasted_content envelopes, keeping their text.
func unwrapPasted(s string) string {
	if !strings.Contains(s, "<pasted_content") {
		return s
	}
	return strings.TrimSpace(pastedRe.ReplaceAllString(s, "$1"))
}

func isSystemInjected(s string) bool {
	t := strings.TrimSpace(s)
	return strings.HasPrefix(t, "<system-reminder>") ||
		strings.HasPrefix(t, "<local-command-stdout>") ||
		strings.HasPrefix(t, "<local-command-stderr>") ||
		strings.HasPrefix(t, "<bash-input>") ||
		strings.HasPrefix(t, "<bash-stdout>") ||
		strings.HasPrefix(t, "<bash-stderr>") ||
		strings.HasPrefix(t, "<command-name>") ||
		strings.HasPrefix(t, "<task-notification>") ||
		strings.HasPrefix(t, "[Request interrupted by user")
}

func (p *Parser) parseAssistant(e entry, base transcript.Event) ([]transcript.Event, error) {
	var m message
	if err := json.Unmarshal(e.Message, &m); err != nil {
		return nil, err
	}
	base.MessageID = m.ID
	base.Model = m.Model
	var out []transcript.Event
	if e.IsAPIError {
		ev := base
		ev.Type = transcript.TypeSystem
		ev.Level = "error"
		ev.Text, ev.Truncated = transcript.Clip(contentText(m.Content))
		if ev.Text == "" {
			ev.Text = "API error"
		}
		return []transcript.Event{ev}, nil
	}
	var blocks []block
	if err := json.Unmarshal(m.Content, &blocks); err != nil {
		// Some older lines carry a string.
		var s string
		if json.Unmarshal(m.Content, &s) == nil && s != "" {
			ev := base
			ev.Type = transcript.TypeText
			ev.Text, ev.Truncated = transcript.Clip(s)
			out = append(out, ev)
		}
		return out, nil
	}
	for i, b := range blocks {
		ev := base
		if len(blocks) > 1 {
			ev.ID = base.ID + ":" + strconv.Itoa(i)
		}
		switch b.Type {
		case "text":
			if strings.TrimSpace(b.Text) == "" {
				continue
			}
			ev.Type = transcript.TypeText
			ev.Text, ev.Truncated = transcript.Clip(b.Text)
		case "thinking", "redacted_thinking":
			ev.Type = transcript.TypeThinking
			ev.Text, ev.Truncated = transcript.Clip(b.Thinking)
		case "tool_use":
			ev.Type = transcript.TypeToolUse
			in := b.Input
			if len(in) > transcript.MaxInlineText {
				in = json.RawMessage(`{"_truncated":true}`)
				ev.Truncated = true
			}
			ev.Tool = &transcript.ToolUse{ID: b.ID, Name: b.Name, Input: in}
		default:
			continue
		}
		out = append(out, ev)
	}
	if m.Usage != nil && m.ID != "" && !p.seenUsage[m.ID] {
		p.seenUsage[m.ID] = true
		ev := base
		ev.Type = transcript.TypeUsage
		ev.ID = base.ID + ":usage"
		ev.Usage = &transcript.Usage{
			InputTokens:         m.Usage.Input,
			OutputTokens:        m.Usage.Output,
			CacheReadTokens:     m.Usage.CacheRead,
			CacheCreationTokens: m.Usage.CacheCreation,
		}
		out = append(out, ev)
	}
	return out, nil
}

func (p *Parser) parseSystem(e entry, base transcript.Event) ([]transcript.Event, error) {
	ev := base
	switch e.Subtype {
	case "compact_boundary":
		ev.Type = transcript.TypeCompact
		ev.Meta = map[string]any{"boundary": true}
		return []transcript.Event{ev}, nil
	}
	txt := contentText(e.Content)
	if strings.TrimSpace(txt) == "" || e.IsMeta {
		return nil, nil
	}
	ev.Type = transcript.TypeSystem
	ev.Level = e.Level
	if ev.Level == "" {
		ev.Level = "info"
	}
	ev.Text, ev.Truncated = transcript.Clip(txt)
	return []transcript.Event{ev}, nil
}

// contentText flattens a content field that is a string, a block list, or absent.
func contentText(raw json.RawMessage) string {
	if len(raw) == 0 {
		return ""
	}
	var s string
	if json.Unmarshal(raw, &s) == nil {
		return s
	}
	var blocks []block
	if json.Unmarshal(raw, &blocks) != nil {
		return ""
	}
	var sb strings.Builder
	for _, b := range blocks {
		switch b.Type {
		case "text":
			if sb.Len() > 0 {
				sb.WriteString("\n")
			}
			sb.WriteString(b.Text)
		case "image":
			if sb.Len() > 0 {
				sb.WriteString("\n")
			}
			sb.WriteString("_[image]_")
		}
	}
	return sb.String()
}
