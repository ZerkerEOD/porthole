// Package core is the daemon's model: the registry of sessions discovered
// through tmux, the CLIs' own session lists and their transcripts, plus the
// followers that stream normalized events to subscribers.
package core

import (
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
}

// Listener receives registry changes. Implementations must not block.
type Listener interface {
	SessionUpserted(s Session)
	SessionRemoved(key string)
	Events(key string, evs []transcript.Event)
	Pane(key string, screen *tmux.Screen)
	PermissionPending(p PermissionRequest)
	PermissionResolved(id string, behavior string)
	AccountsUpdated(a AccountsSnapshot)
}

// PermissionRequest is a Claude PermissionRequest hook waiting for an answer.
type PermissionRequest struct {
	ID         string         `json:"id"`
	SessionKey string         `json:"session_key"`
	ToolName   string         `json:"tool_name"`
	ToolInput  map[string]any `json:"tool_input,omitempty"`
	Cwd        string         `json:"cwd,omitempty"`
	CreatedAt  time.Time      `json:"created_at"`
	ExpiresAt  time.Time      `json:"expires_at"`
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
