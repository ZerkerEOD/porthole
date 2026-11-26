// Package core is the daemon's model: the registry of sessions discovered
// through tmux, the CLIs' own session lists and their transcripts, plus the
// followers that stream normalized events to subscribers.
package core

import (
	"reflect"
	"time"

	"github.com/ZerkerEOD/porthole/daemon/internal/tmux"
	"github.com/ZerkerEOD/porthole/daemon/internal/transcript"
)

// Session is what the app lists. Key is "<provider>:<session id>".
type Session struct {
	Key            string    `json:"key"`
	ID             string    `json:"id"`
	Provider       string    `json:"provider"` // claude|codex
	Title          string    `json:"title,omitempty"`
	Cwd            string    `json:"cwd,omitempty"`
	Repo           string    `json:"repo,omitempty"` // basename of cwd
	Branch         string    `json:"branch,omitempty"`
	Profile        string    `json:"profile,omitempty"`
	TranscriptPath string    `json:"-"`
	Status         string    `json:"status"`
	Running        bool      `json:"running"`
	Controllable   bool      `json:"controllable"`
	PaneID         string    `json:"pane_id,omitempty"`
	TmuxSession    string    `json:"tmux_session,omitempty"`
	PID            int       `json:"pid,omitempty"`
	Kind           string    `json:"kind,omitempty"` // interactive|background
	Model          string    `json:"model,omitempty"`
	Account        string    `json:"account,omitempty"`
	LastPrompt     string    `json:"last_prompt,omitempty"`
	StartedAt      time.Time `json:"started_at,omitempty"`
	UpdatedAt      time.Time `json:"updated_at,omitempty"`
	Size           int64     `json:"size,omitempty"`
	Spawned        bool      `json:"spawned,omitempty"`
	Sidechain      bool      `json:"sidechain,omitempty"`
	// Pending is set on a placeholder created by Spawn before the CLI has
	// written its transcript; the key is then "<provider>:pending:<pane>".
	Pending bool `json:"pending,omitempty"`
	// Question is set while the CLI shows an AskUserQuestion dialog (reported
	// by the PermissionRequest hook) that has not been answered yet.
	Question *Question `json:"question,omitempty"`
	// PermissionMode is the Claude Code mode (default, acceptEdits, plan, auto,
	// dontAsk, bypassPermissions) from the last hook or the status bar.
	PermissionMode string `json:"permission_mode,omitempty"`
	// LastDenied records the most recent action auto mode refused, which the
	// CLI reports through the PermissionDenied hook without opening a dialog.
	LastDenied *DeniedTool `json:"last_denied,omitempty"`
	// Agents lists the subagent runs (Claude Code Agent tool calls) of the
	// session, oldest first.
	Agents []transcript.AgentInfo `json:"agents,omitempty"`
	// Usage is the session's own token usage (subagents excluded), summed
	// over its assistant messages.
	Usage *transcript.Usage `json:"usage,omitempty"`
}

// sameSession reports whether a and b hold the same values. Session holds
// slices, so it cannot be compared with ==.
func sameSession(a, b Session) bool { return reflect.DeepEqual(a, b) }

// Question is a pending AskUserQuestion call: the tool input as the hook
// reported it plus an opaque id, which question.answer echoes back.
type Question struct {
	ID        string         `json:"id"`
	Questions []QuestionItem `json:"questions"`
	// Recovered is set when the dialog was read off the pane rather than
	// reported by the hook: only the current question is visible, so the
	// dialog is served one question at a time and Remaining counts the
	// unanswered questions that follow.
	Recovered bool `json:"recovered,omitempty"`
	Remaining int  `json:"remaining,omitempty"`
	// SetAt is when the dialog was recorded; the transcript is silent while
	// it is open, so a later record means it closed.
	SetAt time.Time `json:"-"`
}

// QuestionItem is one question of the dialog.
type QuestionItem struct {
	Question    string           `json:"question"`
	Header      string           `json:"header"`
	MultiSelect bool             `json:"multiSelect"`
	Options     []QuestionOption `json:"options"`
}

// QuestionOption is one choice of a question. Preview carries the optional
// code or layout sample the CLI shows for the option.
type QuestionOption struct {
	Label       string `json:"label"`
	Description string `json:"description"`
	Preview     string `json:"preview,omitempty"`
}

// Listener receives registry changes. Implementations must not block.
type Listener interface {
	SessionUpserted(s Session)
	// SessionReplaced precedes SessionRemoved(oldKey) when a spawn
	// placeholder turns into a real session.
	SessionReplaced(oldKey, newKey string)
	SessionRemoved(key string)
	Events(key string, evs []transcript.Event)
	Pane(key string, screen *tmux.Screen)
	PermissionPending(p PermissionRequest)
	PermissionResolved(id string, behavior string)
	AccountsUpdated(a AccountsSnapshot)
}

// DeniedTool is one action refused by auto mode.
type DeniedTool struct {
	Tool string    `json:"tool"`
	At   time.Time `json:"at"`
}

// PermissionRequest is a permission prompt the phone can answer: either a
// Claude PermissionRequest hook held open for a decision, or (Recovered) the
// dialog the CLI drew in the terminal, read off the pane, with its Options
// as the CLI numbers them.
type PermissionRequest struct {
	ID         string         `json:"id"`
	SessionKey string         `json:"session_key"`
	ToolName   string         `json:"tool_name"`
	ToolInput  map[string]any `json:"tool_input,omitempty"`
	Cwd        string         `json:"cwd,omitempty"`
	CreatedAt  time.Time      `json:"created_at"`
	ExpiresAt  time.Time      `json:"expires_at,omitzero"`
	// Recovered requests describe the on-screen dialog instead of ToolInput.
	Recovered   bool     `json:"recovered,omitempty"`
	Prompt      string   `json:"prompt,omitempty"`
	Description string   `json:"description,omitempty"`
	Detail      string   `json:"detail,omitempty"`
	Options     []string `json:"options,omitempty"`
}

// AccountsSnapshot is the current view from the optional account providers.
type AccountsSnapshot struct {
	FetchedAt time.Time `json:"fetched_at"`
	Claude    any       `json:"claude,omitempty"` // cswap JSON as-is (schemaVersion 1)
	Codex     *Codex    `json:"codex,omitempty"`
}

// Codex is the Codex account view assembled from auth.json and rollouts.
type Codex struct {
	Email      string                 `json:"email,omitempty"`
	RateLimits *transcript.RateLimits `json:"rate_limits,omitempty"`
	SeenAt     time.Time              `json:"seen_at,omitempty"`
}
