package core

import (
	"errors"
	"time"

	"github.com/ZerkerEOD/porthole/daemon/internal/provider/claude"
	"github.com/ZerkerEOD/porthole/daemon/internal/transcript"
)

// claudeExtras refreshes a Claude session's subagent list and token usage
// from its transcript. Both reads are cached by file size and mtime, so an
// unchanged session costs a few stat calls. On a read error the values from
// prev are kept.
//
// A subagent counts as running while it has not reported completion and
// either its transcript changed in the last 20 seconds or the parent session
// is running and its meta.json is of the kind that records completion (so
// a long tool call inside the subagent does not make it look stopped). No
// subagent runs once the parent has exited.
func (r *Registry) claudeExtras(s *Session, prev *Session) {
	if s.TranscriptPath == "" {
		return
	}
	if agents, err := claude.ListAgents(s.TranscriptPath); err == nil {
		for i := range agents {
			a := &agents[i]
			if !s.Running {
				a.Running = false
			} else if !a.Finished && a.ReportsFinish {
				a.Running = true
			}
		}
		s.AgentsTotal = len(agents)
		s.Agents = trimAgents(agents, maxFinishedAgents)
	} else if prev != nil {
		s.Agents, s.AgentsTotal = prev.Agents, prev.AgentsTotal
	}
	s.PendingTasks = 0
	if s.Running {
		if tasks, err := claude.PendingTasks(s.TranscriptPath); err == nil {
			cutoff := time.Now().Add(-pendingTaskMaxAge)
			for _, t := range tasks {
				if t.LaunchedAt.IsZero() || t.LaunchedAt.After(cutoff) {
					s.PendingTasks++
				}
			}
		} else if prev != nil {
			s.PendingTasks = prev.PendingTasks
		}
	}
	if u, err := claude.TranscriptUsage(s.TranscriptPath); err == nil {
		if u != (transcript.Usage{}) {
			s.Usage = &u
		} else {
			s.Usage = nil
		}
	} else if prev != nil {
		s.Usage = prev.Usage
	}
}

// pendingTaskMaxAge bounds how long a background task without a completion
// notice keeps its session busy. A background Bash call can be a server that
// never ends; past this age it no longer holds status or notices back.
const pendingTaskMaxAge = 30 * time.Minute

// backgroundWork reports whether a session has a running subagent or a
// pending background task.
func backgroundWork(s Session) bool {
	if s.PendingTasks > 0 {
		return true
	}
	for _, a := range s.Agents {
		if a.Running {
			return true
		}
	}
	return false
}

// holdBusy reports a running session that looks idle or waiting for input
// as busy while it has background work: the model resumes when that work
// reports back. A permission prompt or an open question still wins.
func holdBusy(s *Session) {
	if !s.Running || s.Question != nil {
		return
	}
	if (s.Status == transcript.StatusIdle || s.Status == transcript.StatusWaitingInput) && backgroundWork(*s) {
		s.Status = transcript.StatusBusy
	}
}

// maxFinishedAgents bounds how many finished subagents ride along with a
// session; long sessions accumulate hundreds and every upsert carries them.
const maxFinishedAgents = 40

// trimAgents keeps every running agent and the most recent keep finished
// ones, in the original (oldest first) order. AgentsTotal still counts all.
func trimAgents(agents []transcript.AgentInfo, keep int) []transcript.AgentInfo {
	finished := 0
	for _, a := range agents {
		if !a.Running {
			finished++
		}
	}
	drop := finished - keep
	if drop <= 0 {
		return agents
	}
	out := make([]transcript.AgentInfo, 0, len(agents)-drop)
	for _, a := range agents {
		if !a.Running && drop > 0 {
			drop--
			continue
		}
		out = append(out, a)
	}
	return out
}

// stopAgents returns agents with Running cleared, for a session that exited.
func stopAgents(agents []transcript.AgentInfo) []transcript.AgentInfo {
	if len(agents) == 0 {
		return agents
	}
	out := make([]transcript.AgentInfo, len(agents))
	copy(out, agents)
	for i := range out {
		out[i].Running = false
	}
	return out
}

// AgentKey is the follower and subscription key of one subagent transcript.
func AgentKey(key, agentID string) string { return key + "#" + agentID }

func validAgentID(id string) bool {
	if id == "" || len(id) > 64 {
		return false
	}
	for _, c := range id {
		if !(c >= '0' && c <= '9' || c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c == '-' || c == '_') {
			return false
		}
	}
	return true
}

// agentPath resolves a subagent of a session to its transcript file. Only
// ids listed for the session are accepted.
func (r *Registry) agentPath(key, agentID string) (string, error) {
	s, ok := r.Get(key)
	if !ok {
		return "", errors.New("unknown session")
	}
	if s.Provider != "claude" || s.TranscriptPath == "" {
		return "", errors.New("session has no subagents")
	}
	if !validAgentID(agentID) {
		return "", errors.New("unknown agent")
	}
	for _, a := range s.Agents {
		if a.ID == agentID {
			return a.Path, nil
		}
	}
	// The list on the card may predate the agent: look again.
	agents, err := claude.ListAgents(s.TranscriptPath)
	if err != nil {
		return "", err
	}
	for _, a := range agents {
		if a.ID == agentID {
			return a.Path, nil
		}
	}
	return "", errors.New("unknown agent " + agentID + " in session " + key)
}

// agentFollower returns (creating if needed) the follower of a subagent.
func (r *Registry) agentFollower(key, agentID string, subscribe bool) (*follower, error) {
	path, err := r.agentPath(key, agentID)
	if err != nil {
		return nil, err
	}
	k := AgentKey(key, agentID)
	r.mu.Lock()
	f := r.followers[k]
	if f == nil {
		f = newFollower(k, "claude", path)
		r.followers[k] = f
	}
	if subscribe {
		r.subs[k]++
	}
	r.mu.Unlock()
	return f, nil
}

// SubscribeAgent starts streaming one subagent's transcript, read-only. It
// returns the latest page of events; new events reach listeners through
// Events with the key AgentKey(key, agentID).
func (r *Registry) SubscribeAgent(key, agentID string, before int64, limit int) ([]transcript.Event, bool, error) {
	f, err := r.agentFollower(key, agentID, true)
	if err != nil {
		return nil, false, err
	}
	if _, err := f.pump(); err != nil {
		r.Unsubscribe(AgentKey(key, agentID))
		return nil, false, err
	}
	evs, more := f.page(before, limit)
	return evs, more, nil
}

// UnsubscribeAgent drops one subscription to a subagent transcript.
func (r *Registry) UnsubscribeAgent(key, agentID string) {
	r.Unsubscribe(AgentKey(key, agentID))
}

// HistoryAgent pages older events of a subagent transcript.
func (r *Registry) HistoryAgent(key, agentID string, before int64, limit int) ([]transcript.Event, bool, error) {
	f, err := r.agentFollower(key, agentID, false)
	if err != nil {
		return nil, false, err
	}
	if _, err := f.pump(); err != nil {
		return nil, false, err
	}
	evs, more := f.page(before, limit)
	return evs, more, nil
}
