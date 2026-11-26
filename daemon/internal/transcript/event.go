// Package transcript defines the provider-neutral event model that both the
// Claude Code and Codex parsers produce, plus the file tailer that feeds them.
package transcript

import (
	"encoding/json"
	"time"
)

// Event types. The app renders by Type; everything else is optional detail.
const (
	TypeMeta        = "meta"               // session metadata changed (title, cwd, model, ...)
	TypeUser        = "user"               // a human turn
	TypeText        = "assistant.text"     // assistant markdown
	TypeThinking    = "assistant.thinking" // assistant reasoning (may be empty when redacted)
	TypeToolUse     = "tool.use"
	TypeToolResult  = "tool.result"
	TypeStatus      = "status"
	TypeUsage       = "usage"
	TypeModelSwitch = "model_switch"
	TypeCompact     = "compact"
	TypeSystem      = "system" // errors, notices
	// TypeCommand is a shell command the user ran with "!" (meta.source
	// "bang", with stdout and stderr) or the output of a slash command
	// (meta.source "slash").
	TypeCommand = "command"
)

// Session statuses.
const (
	StatusUnknown           = "unknown"
	StatusIdle              = "idle"
	StatusBusy              = "busy"
	StatusWaitingPermission = "waiting_permission"
	StatusWaitingInput      = "waiting_input"
	StatusExited            = "exited"
)

// MaxInlineText caps the size of a single text/result payload sent to the app.
// Larger content is truncated and flagged; the full text stays on disk.
const MaxInlineText = 16 * 1024

// Event is one normalized transcript item.
type Event struct {
	Seq       int64     `json:"seq"`
	Type      string    `json:"type"`
	TS        time.Time `json:"ts"`
	ID        string    `json:"id,omitempty"`
	ParentID  string    `json:"parent_id,omitempty"`
	MessageID string    `json:"message_id,omitempty"` // groups blocks of one assistant message
	TurnID    string    `json:"turn_id,omitempty"`
	Sidechain bool      `json:"sidechain,omitempty"` // subagent traffic
	AgentID   string    `json:"agent_id,omitempty"`

	Text      string `json:"text,omitempty"`
	Truncated bool   `json:"truncated,omitempty"`

	Tool   *ToolUse    `json:"tool,omitempty"`
	Result *ToolResult `json:"result,omitempty"`
	Status string      `json:"status,omitempty"`
	Usage  *Usage      `json:"usage,omitempty"`
	Model  string      `json:"model,omitempty"`
	Level  string      `json:"level,omitempty"` // for system: info|warn|error

	Meta map[string]any `json:"meta,omitempty"`

	// Images are pictures attached to a user turn or returned by a tool.
	Images []Image `json:"images,omitempty"`
}

// Image is one picture carried inline as base64. A picture too large to
// send has Omitted set and Data empty; Bytes is then its decoded size.
type Image struct {
	MediaType string `json:"media_type"`
	Data      string `json:"data,omitempty"`
	Omitted   bool   `json:"omitted,omitempty"`
	Bytes     int    `json:"bytes,omitempty"`
}

// Limits on images sent inline with an event.
const (
	MaxImagesPerEvent = 3
	MaxImageBytes     = 1536 * 1024
)

// Base64Size returns the decoded size of standard base64 text without
// decoding it.
func Base64Size(s string) int {
	n := len(s)
	if n == 0 {
		return 0
	}
	pad := 0
	for pad < 2 && n-pad > 0 && s[n-1-pad] == '=' {
		pad++
	}
	return n/4*3 + (n%4)*3/4 - pad
}

// ToolUse is a tool invocation by the assistant.
type ToolUse struct {
	ID    string          `json:"id"`
	Name  string          `json:"name"`
	Input json.RawMessage `json:"input,omitempty"`
}

// ToolResult is the output returned to the assistant for a ToolUse.
type ToolResult struct {
	ToolUseID string `json:"tool_use_id"`
	IsError   bool   `json:"is_error,omitempty"`
}

// Usage is token accounting for one assistant message or a session total.
type Usage struct {
	InputTokens         int64   `json:"input_tokens,omitempty"`
	OutputTokens        int64   `json:"output_tokens,omitempty"`
	CacheReadTokens     int64   `json:"cache_read_tokens,omitempty"`
	CacheCreationTokens int64   `json:"cache_creation_tokens,omitempty"`
	TotalCostUSD        float64 `json:"total_cost_usd,omitempty"`
	ContextWindow       int64   `json:"context_window,omitempty"`
	// RateLimits is provider usage-limit info when the transcript carries it
	// (Codex token_count events do).
	RateLimits *RateLimits `json:"rate_limits,omitempty"`
}

// RateLimits mirrors the shape Codex writes; Claude usage comes from cswap.
type RateLimits struct {
	Plan      string      `json:"plan,omitempty"`
	Primary   *RateWindow `json:"primary,omitempty"`
	Secondary *RateWindow `json:"secondary,omitempty"`
}

// RateWindow is one usage window.
type RateWindow struct {
	UsedPercent   float64   `json:"used_percent"`
	WindowMinutes int64     `json:"window_minutes,omitempty"`
	ResetsAt      time.Time `json:"resets_at,omitempty"`
}

// Clip truncates s to MaxInlineText and reports whether it did.
func Clip(s string) (string, bool) {
	if len(s) <= MaxInlineText {
		return s, false
	}
	// Cut on a rune boundary.
	cut := MaxInlineText
	for cut > 0 && (s[cut]&0xC0) == 0x80 {
		cut--
	}
	return s[:cut], true
}

// Parser turns one raw transcript line into zero or more events. Parsers must
// be tolerant: unknown entry types are skipped, never fatal.
type Parser interface {
	// ParseLine returns the events for one JSONL line. Seq is assigned by the caller.
	ParseLine(line []byte) ([]Event, error)
}
