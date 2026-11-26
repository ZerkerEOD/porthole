package server

import (
	"encoding/json"

	"github.com/ZerkerEOD/porthole/daemon/internal/core"
	"github.com/ZerkerEOD/porthole/daemon/internal/tmux"
	"github.com/ZerkerEOD/porthole/daemon/internal/transcript"
)

// Message is the WebSocket envelope in both directions. The JSON Schemas in
// proto/ are generated from these types.
type Message struct {
	Type    string          `json:"type"`
	ID      string          `json:"id,omitempty"` // client request id, echoed in result
	Payload json.RawMessage `json:"payload,omitempty"`
}

// Client -> server payloads.
type (
	SubscribeReq struct {
		Key    string `json:"key"`
		Before int64  `json:"before,omitempty"`
		Limit  int    `json:"limit,omitempty"`
	}
	KeyReq struct {
		Key string `json:"key"`
	}
	InputReq struct {
		Key   string `json:"key"`
		Text  string `json:"text"`
		Enter bool   `json:"enter"`
	}
	KeysReq struct {
		Key  string   `json:"key"`
		Keys []string `json:"keys"`
	}
	ResizeReq struct {
		Key  string `json:"key"`
		Cols int    `json:"cols"`
		Rows int    `json:"rows"`
	}
	PermissionAnswerReq struct {
		ID       string `json:"id"`
		Behavior string `json:"behavior,omitempty"` // allow|deny
		// Option picks one of a recovered dialog's options by index instead.
		Option *int `json:"option,omitempty"`
	}
	ModeReq struct {
		Key  string `json:"key"`
		Mode string `json:"mode"`
	}
	ModeMsg struct {
		Key  string `json:"key"`
		Mode string `json:"mode"`
	}
	QuestionAnswerReq struct {
		Key     string        `json:"key"`
		ID      string        `json:"id"`
		Answers []core.Answer `json:"answers"`
	}
	// HistoryReq pages a session transcript, or with AgentID one of its
	// subagent transcripts.
	HistoryReq struct {
		Key     string `json:"key"`
		AgentID string `json:"agent_id,omitempty"`
		Before  int64  `json:"before,omitempty"`
		Limit   int    `json:"limit,omitempty"`
	}
	AgentSubscribeReq struct {
		Key     string `json:"key"`
		AgentID string `json:"agent_id"`
		Before  int64  `json:"before,omitempty"`
		Limit   int    `json:"limit,omitempty"`
	}
	AgentKeyReq struct {
		Key     string `json:"key"`
		AgentID string `json:"agent_id"`
	}
	// PaneReq subscribes to (or leaves) a session's pane or, with RunID or
	// PaneID, the window of one of the session's runs.
	PaneReq struct {
		Key    string `json:"key"`
		RunID  string `json:"run_id,omitempty"`
		PaneID string `json:"pane_id,omitempty"`
	}
	// RunReq starts command in a new window of the session's tmux session.
	RunReq struct {
		Key     string `json:"key"`
		Command string `json:"command"`
		Feed    bool   `json:"feed"`
	}
	RunKeyReq struct {
		Key string `json:"key"`
		ID  string `json:"id"`
	}
	RunStarted struct {
		ID string `json:"id"`
	}
	RunList struct {
		Runs []core.Run `json:"runs"`
	}
)

// Server -> client payloads.
type (
	Hello struct {
		Name        string                   `json:"name"`
		Version     string                   `json:"version"`
		Protocol    int                      `json:"protocol"`
		Device      string                   `json:"device"`
		Hosts       []string                 `json:"hosts,omitempty"`
		Sessions    []core.Session           `json:"sessions"`
		Accounts    core.AccountsSnapshot    `json:"accounts"`
		Permissions []core.PermissionRequest `json:"permissions"`
		Runs        []core.Run               `json:"runs"`
		Features    map[string]bool          `json:"features"`
	}
	EventsMsg struct {
		Key    string             `json:"key"`
		Events []transcript.Event `json:"events"`
	}
	HistoryMsg struct {
		Key     string             `json:"key"`
		AgentID string             `json:"agent_id,omitempty"`
		Events  []transcript.Event `json:"events"`
		HasMore bool               `json:"has_more"`
	}
	AgentEventsMsg struct {
		Key     string             `json:"key"`
		AgentID string             `json:"agent_id"`
		Events  []transcript.Event `json:"events"`
	}
	// PaneMsg is a screen snapshot. RunID and PaneID are set for the
	// window of a run.
	PaneMsg struct {
		Key    string       `json:"key"`
		RunID  string       `json:"run_id,omitempty"`
		PaneID string       `json:"pane_id,omitempty"`
		Screen *tmux.Screen `json:"screen"`
	}
	ResultMsg struct {
		OK    bool            `json:"ok"`
		Error string          `json:"error,omitempty"`
		Data  json.RawMessage `json:"data,omitempty"`
	}
	PermissionResolvedMsg struct {
		ID       string `json:"id"`
		Behavior string `json:"behavior"`
	}
	ReplacedMsg struct {
		Old string `json:"old"`
		New string `json:"new"`
	}
)
