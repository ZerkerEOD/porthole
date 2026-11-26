package core

import "testing"

func TestPromptLineAndShellMode(t *testing.T) {
	draft := readLines(t, "prompt_draft.txt")
	if got := promptLine(draft); got != "ok check the results" {
		t.Fatalf("draft %q", got)
	}
	if shellModeOn(draft) {
		t.Fatal("a draft is not shell mode")
	}
	shell := readLines(t, "prompt_shell.txt")
	if !shellModeOn(shell) {
		t.Fatal("shell mode not seen")
	}
	idle := readLines(t, "mode_manual.ansi")
	if got := promptLine(idle); got != "" {
		t.Fatalf("idle prompt reads %q", got)
	}
	if shellModeOn(idle) {
		t.Fatal("idle is not shell mode")
	}
}
