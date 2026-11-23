package core

import (
	"testing"
)

// Captured from the CLI (ANSI stripped), with the tab row highlight added
// back on the current tab.
var recoverMulti = []string{
	"",
	"←  \x1b[38;5;16m\x1b[48;5;153m ☐ Multi-select \x1b[39m\x1b[49m  ☐ Navigation  ☐ Preview  ✔ Submit  →",
	"│ Multi-question test, question 1 of 3 (single-select): how did the multi-select card ... behave in",
	"│ the Porthole chat view?",
	"❯ 1. Worked fully",
	"     Checkboxes toggled, and the typed note went through alongside the selections.",
	"  2. Worked with quirks",
	"     The answer arrived, but something about the layout or interaction was off.",
	"  3. Hard to use",
	"     Selecting several options or adding the note took real effort.",
	"  4. Type something.",
	"────────────────────────────────",
	"  5. Chat about this",
	"Enter to select · Tab/Arrow keys to navigate · Esc to cancel",
}

func TestParseDialogTabs(t *testing.T) {
	item, remaining, ok := parseDialog(recoverMulti)
	if !ok {
		t.Fatal("dialog not found")
	}
	if item.Question != "Multi-question test, question 1 of 3 (single-select): how did the multi-select card ... behave in the Porthole chat view?" {
		t.Fatalf("question %q", item.Question)
	}
	if item.Header != "Multi-select" || remaining != 2 || item.MultiSelect {
		t.Fatalf("header %q remaining %d multi %v", item.Header, remaining, item.MultiSelect)
	}
	want := []QuestionOption{
		{Label: "Worked fully", Description: "Checkboxes toggled, and the typed note went through alongside the selections."},
		{Label: "Worked with quirks", Description: "The answer arrived, but something about the layout or interaction was off."},
		{Label: "Hard to use", Description: "Selecting several options or adding the note took real effort."},
	}
	if len(item.Options) != len(want) {
		t.Fatalf("options %+v", item.Options)
	}
	for i := range want {
		if item.Options[i] != want[i] {
			t.Errorf("option %d: %+v", i, item.Options[i])
		}
	}
}

func TestParseDialogAnsweredTabs(t *testing.T) {
	lines := append([]string(nil), recoverMulti...)
	// Second question current (highlighted), first answered, third open.
	lines[1] = "←  ✔ Multi-select  \x1b[7m ☐ Navigation \x1b[27m  ☐ Preview  ✔ Submit  →"
	item, remaining, ok := parseDialog(lines)
	if !ok || item.Header != "Navigation" || remaining != 1 {
		t.Fatalf("ok %v header %q remaining %d", ok, item.Header, remaining)
	}
	// Last open question current, no highlight on the row: the first
	// unanswered tab is the current one.
	lines[1] = "←  ✔ Multi-select  ✔ Navigation  ☐ Preview  ✔ Submit  →"
	item, remaining, ok = parseDialog(lines)
	if !ok || item.Header != "Preview" || remaining != 0 {
		t.Fatalf("ok %v header %q remaining %d", ok, item.Header, remaining)
	}
}

func TestParseDialogMultiSelect(t *testing.T) {
	lines := []string{
		"● Some earlier output with │ a box",
		"",
		"│ Which of these apply? (Select all that apply)",
		"❯ 1. [ ] Alpha",
		"  2. [✔] Beta",
		"     Second one",
		"  3. [ ] Gamma",
		"  4. Type something.",
		"────────────────────────────────",
		"  5. Chat about this",
		"Enter to select · Space to toggle · Esc to cancel",
	}
	item, remaining, ok := parseDialog(lines)
	if !ok || !item.MultiSelect || remaining != 0 || item.Header != "" {
		t.Fatalf("ok %v item %+v remaining %d", ok, item, remaining)
	}
	if item.Question != "Which of these apply?" {
		t.Fatalf("question %q", item.Question)
	}
	if len(item.Options) != 3 || item.Options[0].Label != "Alpha" || item.Options[1] != (QuestionOption{Label: "Beta", Description: "Second one"}) || item.Options[2].Label != "Gamma" {
		t.Fatalf("options %+v", item.Options)
	}
}

func TestParseDialogSingle(t *testing.T) {
	lines := []string{
		"\x1b[1m│ Which fruit do you pick?\x1b[0m",
		"\x1b[38;5;153m❯\x1b[39m \x1b[38;5;246m1.\x1b[39m Apple",
		"     Apple",
		"  2. Banana",
		"     Banana",
		"  3. Type something.",
		"────────────────────────────────",
		"  4. Chat about this",
		"Enter to select · Tab/Arrow keys to navigate · Esc to cancel",
	}
	item, remaining, ok := parseDialog(lines)
	if !ok || remaining != 0 || item.Header != "" || item.MultiSelect {
		t.Fatalf("ok %v item %+v remaining %d", ok, item, remaining)
	}
	if item.Question != "Which fruit do you pick?" || len(item.Options) != 2 || item.Options[1] != (QuestionOption{Label: "Banana", Description: "Banana"}) {
		t.Fatalf("item %+v", item)
	}
}

// Captured from a scratch session: no "│" in front of the question.
func TestParseDialogPlainQuestion(t *testing.T) {
	lines := []string{
		"❯ Use your question tool to ask me three questions with short options, one of them multi-select",
		"────────────────────────────────────────────────────────────────────",
		"←\u00a0 \x1b[38;5;16m\x1b[48;5;153m ☐ Language \x1b[39m\x1b[49m ☐ Editors  ☐ Focus time  ✔ Submit  →",
		"",
		"\x1b[1m\x1b[38;5;231mWhich programming language do you reach for first?\x1b[0m",
		"",
		"\x1b[38;5;153m❯\x1b[39m\u00a0\x1b[38;5;246m1.\x1b[39m Python",
		"     Scripting, data, and general-purpose work.",
		"  2. TypeScript",
		"     Typed JavaScript for web and Node.",
		"  3. Go",
		"     Compiled, simple concurrency.",
		"  4. Rust",
		"     Memory safety and performance.",
		"  5. Type something.",
		"────────────────────────────────────────────────────────────────────",
		"  6. Chat about this",
		"Enter to select · Tab/Arrow keys to navigate · Esc to cancel",
	}
	item, remaining, ok := parseDialog(lines)
	if !ok || item.Header != "Language" || remaining != 2 || item.MultiSelect {
		t.Fatalf("ok %v header %q remaining %d item %+v", ok, item.Header, remaining, item)
	}
	if item.Question != "Which programming language do you reach for first?" || len(item.Options) != 4 || item.Options[3] != (QuestionOption{Label: "Rust", Description: "Memory safety and performance."}) {
		t.Fatalf("item %+v", item)
	}
}

// Captured from a scratch session: the second question of three, a multi
// select with the first tab answered.
func TestParseDialogMultiSelectLive(t *testing.T) {
	lines := []string{
		"←\u00a0 ☒ Language  \x1b[38;5;16m\x1b[48;5;153m ☐ Editors \x1b[39m\x1b[49m ☐ Focus time  ✔ Submit  →",
		"",
		"Which editors do you use regularly?",
		"",
		"❯ 1. [ ] Neovim",
		"         Modal editing in the terminal.",
		"  2. [ ] VS Code",
		"         Extension-rich GUI editor.",
		"  3. [ ] JetBrains",
		"         Full IDEs like GoLand or PyCharm.",
		"  4. [ ] Zed",
		"         Fast, collaborative native editor.",
		"  \x1b[38;5;246m5. \x1b[39m[ ] \x1b[38;5;246mType something\x1b[39m",
		"     \x1b[1mNext\x1b[0m",
		"────────────────────────────────────────────────────────────────────",
		"  6. Chat about this",
		"",
		"Enter to select · Tab/Arrow keys to navigate · Esc to cancel",
	}
	item, remaining, ok := parseDialog(lines)
	if !ok || item.Header != "Editors" || remaining != 1 || !item.MultiSelect {
		t.Fatalf("ok %v header %q remaining %d item %+v", ok, item.Header, remaining, item)
	}
	if item.Question != "Which editors do you use regularly?" || len(item.Options) != 4 || item.Options[2] != (QuestionOption{Label: "JetBrains", Description: "Full IDEs like GoLand or PyCharm."}) {
		t.Fatalf("item %+v", item)
	}
}

func TestParseDialogNone(t *testing.T) {
	cases := [][]string{
		{},
		{"❯ 1. Yes", "  2. Yes, and don't ask again", "  3. No", "Esc to cancel"},
		{"│ a boxed line", "some prose", "  1. Type something."},
		{"│ Question?", "  1. One", "  3. Type something."},
		{"> type here", "", "? for shortcuts"},
	}
	for i, c := range cases {
		if _, _, ok := parseDialog(c); ok {
			t.Errorf("case %d parsed as a dialog", i)
		}
	}
}

func TestQuestionTextShown(t *testing.T) {
	text := screenText(screenOf(recoverMulti))
	q := QuestionItem{Question: "Multi-question test, question 1 of 3 (single-select): how did the multi-select card ... behave in the Porthole chat view?", Header: "Multi-select", Options: []QuestionOption{{Label: "Worked fully"}}}
	if !questionTextShown(text, q) || !questionShown(text, q) {
		t.Fatal("wrapped question not matched")
	}
	q.Question = "Something else?"
	if questionTextShown(text, q) {
		t.Fatal("matched by header")
	}
	if !questionShown(text, q) {
		t.Fatal("questionShown ignores the header")
	}
}
