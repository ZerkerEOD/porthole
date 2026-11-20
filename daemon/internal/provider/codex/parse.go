// Package codex understands OpenAI Codex CLI: its rollout JSONL files, running
// processes, CODEX_HOME profiles and skills. Nothing here talks to OpenAI.
package codex

import (
	"encoding/json"
	"strconv"
	"strings"
	"time"

	"github.com/ZerkerEOD/porthole/daemon/internal/transcript"
)

// Parser converts Codex rollout lines into normalized events.
type Parser struct {
	model string
	// callNames maps call_id to tool name so outputs can be labelled.
	callNames map[string]string
}

// NewParser returns a fresh parser.
func NewParser() *Parser { return &Parser{callNames: map[string]string{}} }

type line struct {
	Timestamp string          `json:"timestamp"`
	Type      string          `json:"type"`
	Payload   json.RawMessage `json:"payload"`
}

type payload struct {
	Type string `json:"type"`

	// session_meta
	ID     string `json:"id"`
	Cwd    string `json:"cwd"`
	CLIVer string `json:"cli_version"`
	Source string `json:"source"`
	Git    *struct {
		Branch string `json:"branch"`
	} `json:"git"`

	// turn_context
	TurnID         string `json:"turn_id"`
	Model          string `json:"model"`
	ApprovalPolicy string `json:"approval_policy"`

	// event_msg
	Message          string `json:"message"`
	Text             string `json:"text"`
	Phase            string `json:"phase"`
	LastAgentMessage string `json:"last_agent_message"`
	RateLimits       *struct {
		PlanType  string      `json:"plan_type"`
		Primary   *rateWindow `json:"primary"`
		Secondary *rateWindow `json:"secondary"`
	} `json:"rate_limits"`
	Info *struct {
		TotalTokenUsage *struct {
			Input  int64 `json:"input_tokens"`
			Output int64 `json:"output_tokens"`
			Cached int64 `json:"cached_input_tokens"`
		} `json:"total_token_usage"`
		ModelContextWindow int64 `json:"model_context_window"`
	} `json:"info"`

	// response_item
	Role      string          `json:"role"`
	Content   json.RawMessage `json:"content"`
	Summary   json.RawMessage `json:"summary"`
	Name      string          `json:"name"`
	Arguments string          `json:"arguments"`
	CallID    string          `json:"call_id"`
	Output    json.RawMessage `json:"output"`
	Input     string          `json:"input"`
	Action    *struct {
		Command []string `json:"command"`
	} `json:"action"`
	Status string `json:"status"`
}

type rateWindow struct {
	UsedPercent   float64 `json:"used_percent"`
	WindowMinutes int64   `json:"window_minutes"`
	ResetsAt      int64   `json:"resets_at"`
}

type contentPart struct {
	Type string `json:"type"`
	Text string `json:"text"`
}

func parseTime(s string) time.Time {
	t, err := time.Parse(time.RFC3339Nano, s)
	if err != nil {
		return time.Time{}
	}
	return t
}

func partsText(raw json.RawMessage) string {
	var parts []contentPart
	if json.Unmarshal(raw, &parts) != nil {
		var s string
		if json.Unmarshal(raw, &s) == nil {
			return s
		}
		return ""
	}
	var sb strings.Builder
	for _, p := range parts {
		if p.Text == "" {
			continue
		}
		if sb.Len() > 0 {
			sb.WriteString("\n")
		}
		sb.WriteString(p.Text)
	}
	return sb.String()
}

// ParseLine implements transcript.Parser.
func (p *Parser) ParseLine(raw []byte) ([]transcript.Event, error) {
	var l line
	if err := json.Unmarshal(raw, &l); err != nil {
		return nil, err
	}
	var pl payload
	if len(l.Payload) > 0 {
		if err := json.Unmarshal(l.Payload, &pl); err != nil {
			return nil, err
		}
	}
	base := transcript.Event{TS: parseTime(l.Timestamp), Model: p.model}
	switch l.Type {
	case "session_meta":
		m := map[string]any{"session_id": pl.ID, "cwd": pl.Cwd, "cli_version": pl.CLIVer, "source": pl.Source}
		if pl.Git != nil {
			m["git_branch"] = pl.Git.Branch
		}
		base.Type = transcript.TypeMeta
		base.Meta = m
		return []transcript.Event{base}, nil
	case "turn_context":
		var out []transcript.Event
		if pl.Model != "" && pl.Model != p.model {
			prev := p.model
			p.model = pl.Model
			ev := base
			ev.Type = transcript.TypeModelSwitch
			ev.Model = pl.Model
			ev.Meta = map[string]any{"from": prev, "to": pl.Model}
			out = append(out, ev)
		}
		ev := base
		ev.Type = transcript.TypeMeta
		ev.TurnID = pl.TurnID
		ev.Meta = map[string]any{"cwd": pl.Cwd, "approval_policy": pl.ApprovalPolicy, "model": pl.Model}
		return append(out, ev), nil
	case "event_msg":
		return p.parseEvent(pl, base)
	case "response_item":
		return p.parseItem(pl, base)
	}
	return nil, nil
}

func (p *Parser) parseEvent(pl payload, base transcript.Event) ([]transcript.Event, error) {
	base.TurnID = pl.TurnID
	switch pl.Type {
	case "user_message":
		base.Type = transcript.TypeUser
		base.Text, base.Truncated = transcript.Clip(pl.Message)
		return []transcript.Event{base}, nil
	case "task_started":
		base.Type = transcript.TypeStatus
		base.Status = transcript.StatusBusy
		return []transcript.Event{base}, nil
	case "task_complete", "turn_aborted":
		base.Type = transcript.TypeStatus
		base.Status = transcript.StatusIdle
		return []transcript.Event{base}, nil
	case "error", "stream_error":
		base.Type = transcript.TypeSystem
		base.Level = "error"
		base.Text, base.Truncated = transcript.Clip(firstNonEmpty(pl.Message, pl.Text, "error"))
		return []transcript.Event{base}, nil
	case "token_count":
		u := &transcript.Usage{}
		if pl.Info != nil {
			if t := pl.Info.TotalTokenUsage; t != nil {
				u.InputTokens, u.OutputTokens, u.CacheReadTokens = t.Input, t.Output, t.Cached
			}
			u.ContextWindow = pl.Info.ModelContextWindow
		}
		if rl := pl.RateLimits; rl != nil {
			u.RateLimits = &transcript.RateLimits{Plan: rl.PlanType, Primary: window(rl.Primary), Secondary: window(rl.Secondary)}
		}
		base.Type = transcript.TypeUsage
		base.Usage = u
		return []transcript.Event{base}, nil
	case "agent_reasoning":
		// Reasoning deltas; the response_item carries the final summary. Skip.
		return nil, nil
	case "agent_message":
		// Duplicated by response_item message/assistant; skip to avoid double text.
		return nil, nil
	}
	return nil, nil
}

func window(w *rateWindow) *transcript.RateWindow {
	if w == nil {
		return nil
	}
	out := &transcript.RateWindow{UsedPercent: w.UsedPercent, WindowMinutes: w.WindowMinutes}
	if w.ResetsAt > 0 {
		out.ResetsAt = time.Unix(w.ResetsAt, 0).UTC()
	}
	return out
}

func (p *Parser) parseItem(pl payload, base transcript.Event) ([]transcript.Event, error) {
	switch pl.Type {
	case "message":
		if pl.Role != "assistant" {
			// user/developer response_items are harness wrappers; the human
			// text arrives via event_msg user_message.
			return nil, nil
		}
		txt := partsText(pl.Content)
		if strings.TrimSpace(txt) == "" {
			return nil, nil
		}
		base.Type = transcript.TypeText
		base.Text, base.Truncated = transcript.Clip(txt)
		if pl.Phase != "" {
			base.Meta = map[string]any{"phase": pl.Phase}
		}
		return []transcript.Event{base}, nil
	case "reasoning":
		txt := partsText(pl.Summary)
		if strings.TrimSpace(txt) == "" {
			return nil, nil
		}
		base.Type = transcript.TypeThinking
		base.Text, base.Truncated = transcript.Clip(txt)
		return []transcript.Event{base}, nil
	case "function_call", "custom_tool_call":
		name := pl.Name
		in := json.RawMessage(nil)
		if pl.Arguments != "" {
			if json.Valid([]byte(pl.Arguments)) {
				in = json.RawMessage(pl.Arguments)
			} else {
				in, _ = json.Marshal(map[string]string{"arguments": pl.Arguments})
			}
		} else if pl.Input != "" {
			in, _ = json.Marshal(map[string]string{"input": pl.Input})
		}
		p.callNames[pl.CallID] = name
		return []transcript.Event{toolUse(base, pl.CallID, name, in)}, nil
	case "local_shell_call":
		cmd := []string{}
		if pl.Action != nil {
			cmd = pl.Action.Command
		}
		in, _ := json.Marshal(map[string]any{"command": cmd})
		p.callNames[pl.CallID] = "shell"
		return []transcript.Event{toolUse(base, pl.CallID, "shell", in)}, nil
	case "web_search_call":
		in, _ := json.Marshal(map[string]any{"status": pl.Status})
		return []transcript.Event{toolUse(base, pl.CallID, "web_search", in)}, nil
	case "function_call_output", "custom_tool_call_output", "local_shell_call_output":
		base.Type = transcript.TypeToolResult
		base.Result = &transcript.ToolResult{ToolUseID: pl.CallID}
		out := partsText(pl.Output)
		if out == "" {
			out = string(pl.Output)
		}
		base.Text, base.Truncated = transcript.Clip(out)
		if n, ok := p.callNames[pl.CallID]; ok {
			base.Meta = map[string]any{"tool": n}
		}
		return []transcript.Event{base}, nil
	}
	return nil, nil
}

func toolUse(base transcript.Event, id, name string, in json.RawMessage) transcript.Event {
	base.Type = transcript.TypeToolUse
	if len(in) > transcript.MaxInlineText {
		in = json.RawMessage(`{"_truncated":true}`)
		base.Truncated = true
	}
	base.Tool = &transcript.ToolUse{ID: id, Name: name, Input: in}
	return base
}

func firstNonEmpty(ss ...string) string {
	for _, s := range ss {
		if s != "" {
			return s
		}
	}
	return ""
}

// SessionIDFromFilename extracts the session UUID from a rollout file name
// like rollout-2026-05-08T11-53-56-019e0738-fdee-7f73-8499-2f32eb007778.jsonl.
func SessionIDFromFilename(name string) string {
	name = strings.TrimSuffix(name, ".jsonl")
	parts := strings.Split(name, "-")
	if len(parts) < 5 {
		return ""
	}
	return strings.Join(parts[len(parts)-5:], "-")
}

var _ = strconv.Itoa
