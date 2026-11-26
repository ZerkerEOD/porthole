package core

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func readLines(t *testing.T, name string) []string {
	t.Helper()
	b, err := os.ReadFile("testdata/" + name)
	if err != nil {
		t.Fatal(err)
	}
	return strings.Split(string(b), "\n")
}

func TestParsePermissionDialogBash(t *testing.T) {
	d, ok := parsePermissionDialog(readLines(t, "perm_bash.txt"))
	if !ok {
		t.Fatal("dialog not found")
	}
	if d.Tool != "Bash command" || d.Description != "Create empty probe1.txt file in the repo" || d.Prompt != "Do you want to proceed?" {
		t.Errorf("head: %+v", d)
	}
	if !strings.HasPrefix(d.Detail, "touch /tmp/") || strings.Contains(d.Detail, "│") {
		t.Errorf("detail: %q", d.Detail)
	}
	want := []string{"Yes", "Yes, and always allow access to /tmp/claude-1000/-home-zerkereod-Programming-remote-teminal/eb738e68-21b8-4a51-9f86-7a16856106cf/scratchpad/qtest2/repo from this project", "Yes, and switch to auto mode", "No"}
	if strings.Join(d.Options, "|") != strings.Join(want, "|") {
		t.Errorf("options: %q", d.Options)
	}
}

func TestParsePermissionDialogWrite(t *testing.T) {
	d, ok := parsePermissionDialog(readLines(t, "perm_write.txt"))
	if !ok {
		t.Fatal("dialog not found")
	}
	if d.Tool != "Create file" || d.Description != "probe2.txt" || d.Prompt != "Do you want to create probe2.txt?" || d.Detail != "1 hi" {
		t.Errorf("%+v", d)
	}
	if len(d.Options) != 3 || d.Options[2] != "No" || !strings.HasPrefix(d.Options[1], "Yes, and switch to accept edits") {
		t.Errorf("options: %q", d.Options)
	}
}

func TestParsePermissionDialogPlan(t *testing.T) {
	d, ok := parsePermissionDialog(readLines(t, "perm_plan.txt"))
	if !ok {
		t.Fatal("dialog not found")
	}
	if d.Tool != "Plan approval" || d.Description != "Here is Claude's plan:" || !strings.HasSuffix(d.Prompt, "Would you like to proceed?") {
		t.Errorf("head: %+v", d)
	}
	if !strings.HasPrefix(d.Detail, "1. Create LICENSE") || !strings.Contains(d.Detail, "\n2. Verify") {
		t.Errorf("detail: %q", d.Detail)
	}
	want := []string{"Yes, and use auto mode", "Yes, manually approve edits", "Tell Claude what to change"}
	if strings.Join(d.Options, "|") != strings.Join(want, "|") {
		t.Errorf("options: %q", d.Options)
	}
}

func TestParsePermissionDialogIgnoresOtherScreens(t *testing.T) {
	// A question dialog and an idle prompt are not permission dialogs.
	for _, name := range []string{"mode_manual.ansi", "mode_plan.ansi"} {
		if _, ok := parsePermissionDialog(readLines(t, name)); ok {
			t.Errorf("%s parsed as a permission dialog", name)
		}
	}
	q := []string{"│ Which one?", "❯ 1. Red", "  2. Blue", "  3. Type something.", "Enter to select · Tab/Arrow keys to navigate · Esc to cancel"}
	if _, ok := parsePermissionDialog(q); ok {
		t.Error("question dialog parsed as a permission dialog")
	}
	if a, b := (permDialog{Prompt: "a", Options: []string{"Yes"}}).hash(), (permDialog{Prompt: "b", Options: []string{"Yes"}}).hash(); a == b {
		t.Error("hash must change with the prompt")
	}
}

func TestParsePermissionDialogScrolledPlan(t *testing.T) {
	lines := []string{
		"   - Not determined: whether this is that user's browser",
		"  ──────────────────────────────────────────────",
		"   Claude has written up a plan and is ready to execute. Would you like to proceed?",
		"   ❯ 1. Yes, and use auto mode",
		"     2. Yes, manually approve edits",
		"     3. Tell Claude what to change",
		"        shift+tab to approve with this feedback",
		"   ctrl+g to edit in Vim · ~/.claude/plans/x.md",
	}
	d, ok := parsePermissionDialog(lines)
	if !ok || d.Tool != "Plan approval" || len(d.Options) != 3 {
		t.Fatalf("%+v ok=%v", d, ok)
	}
}

func TestPlanFileFromFooterAndReadPlan(t *testing.T) {
	lines := readLines(t, "perm_plan.txt")
	if got := planFile(lines); got != "~/.claude/plans/logical-launching-origami.md" {
		t.Fatalf("plan file %q", got)
	}
	if planFile(readLines(t, "perm_bash.txt")) != "" {
		t.Fatal("a Bash dialog names no plan file")
	}
	home := t.TempDir()
	t.Setenv("HOME", home)
	plans := filepath.Join(home, ".claude", "plans")
	if err := os.MkdirAll(plans, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(plans, "x.md"), []byte("# Plan\n\n1. Do the thing\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(home, "secret.md"), []byte("nope"), 0o600); err != nil {
		t.Fatal(err)
	}
	if got, err := readPlan("~/.claude/plans/x.md", []string{plans}); err != nil || got != "# Plan\n\n1. Do the thing" {
		t.Fatalf("plan %q %v", got, err)
	}
	if got, err := readPlan("~/secret.md", []string{plans}); err == nil || got != "" {
		t.Fatalf("a file outside the plans directory must not be read: %q", got)
	}
	if got, err := readPlan("~/.claude/plans/../secret.md", []string{plans}); err == nil || got != "" {
		t.Fatalf("traversal must not be read: %q", got)
	}
}
