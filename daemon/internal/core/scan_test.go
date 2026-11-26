package core

import (
	"testing"

	"github.com/ZerkerEOD/porthole/daemon/internal/tmux"
)

// A dead pane, a pane without a pid and a run window must never claim a
// CLI process; only the pane the CLI really runs under does.
func TestMapCLIProcsIgnoresDeadAndRunPanes(t *testing.T) {
	procs := map[int]tmux.Process{
		1:   {PID: 1, PPID: 0, Name: "systemd"},
		100: {PID: 100, PPID: 1, Name: "fish"},
		101: {PID: 101, PPID: 100, Name: "claude", Args: "claude"},
		200: {PID: 200, PPID: 1, Name: "sh"},
		201: {PID: 201, PPID: 200, Name: "claude", Args: "claude -p"},
		300: {PID: 300, PPID: 1, Name: "claude", Args: "claude"},
	}
	panes := []tmux.Pane{
		{PaneID: "%1", PID: 100, SessionName: "main", WindowName: "main"},
		{PaneID: "%17", PID: 0, SessionName: "main", WindowName: "ph-run-abcd1234", Dead: true},
		{PaneID: "%18", PID: 0, SessionName: "main", WindowName: "other"},
		{PaneID: "%19", PID: 200, SessionName: "main", WindowName: "ph-run-ffff0000"},
	}
	got := mapCLIProcs(panes, procs, true, true)
	if len(got) != 3 {
		t.Fatalf("mapped %+v", got)
	}
	if got[101].pane.PaneID != "%1" {
		t.Fatalf("claude in a pane: %+v", got[101])
	}
	if got[201].pane.PaneID != "" {
		t.Fatalf("claude in a run window got a pane: %+v", got[201])
	}
	if got[300].pane.PaneID != "" {
		t.Fatalf("claude outside tmux got a pane: %+v", got[300])
	}
}
