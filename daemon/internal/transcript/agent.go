package transcript

import "time"

// AgentInfo summarizes one subagent run (a Claude Code Agent tool call) that
// writes its own transcript next to the parent session's file.
type AgentInfo struct {
	// ID is the hex part of the transcript filename (agent-<id>.jsonl). It
	// matches the parent's toolUseResult.agentId and the task id of the
	// completion notice.
	ID          string `json:"id"`
	Type        string `json:"type"` // agentType from meta.json, "agent" when unknown
	Description string `json:"description"`
	ToolUseID   string `json:"tool_use_id,omitempty"`
	Background  bool   `json:"background"`
	Finished    bool   `json:"finished"`
	// Running is true while the run has not reported completion and its
	// transcript changed within the last 20 seconds. The registry also keeps
	// it true while the parent session runs, for runs whose meta.json
	// reports completion (ReportsFinish).
	Running   bool      `json:"running"`
	StartedAt time.Time `json:"started_at,omitzero"`
	UpdatedAt time.Time `json:"updated_at,omitzero"`
	Turns     int       `json:"turns"`     // distinct assistant messages
	ToolUses  int       `json:"tool_uses"` // tool_use blocks
	Usage     Usage     `json:"usage"`     // summed per distinct message id
	Model     string    `json:"model,omitempty"`
	LastText  string    `json:"last_text,omitempty"` // last assistant text, collapsed, at most 200 characters

	Path string `json:"-"`
	// ReportsFinish is set when meta.json carries a "finished" key, so an
	// unfinished run is known to still be in progress rather than written
	// by a build that never records completion.
	ReportsFinish bool `json:"-"`
}
