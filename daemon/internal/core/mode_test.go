package core

import (
	"errors"
	"os"
	"strings"
	"testing"
)

func TestParseModeLine(t *testing.T) {
	cases := []struct{ line, want string }{
		{"  ⏸ manual mode on · ? for shortcuts", ModeDefault},
		{"  ⏵⏵ accept edits on (shift+tab to cycle)", ModeAcceptEdits},
		{"  ⏸ plan mode on (shift+tab to cycle)", ModePlan},
		{"  ⏵⏵ auto mode on (shift+tab to cycle)", ModeAuto},
		{"  ⏵⏵ don't ask on (shift+tab to cycle)", ModeDontAsk},
		{"  ⏵⏵ bypass permissions on (shift+tab to cycle)", ModeBypass},
	}
	for _, c := range cases {
		got, ok := parseModeLine([]string{"❯ ", "────", c.line, ""})
		if !ok || got != c.want {
			t.Errorf("%q: got %q ok=%v, want %q", c.line, got, ok, c.want)
		}
	}
	if _, ok := parseModeLine([]string{"  1. Yes", "  2. No", "Esc to cancel"}); ok {
		t.Error("a dialog screen must not report a mode")
	}
	for _, f := range []struct{ file, want string }{{"mode_manual.ansi", ModeDefault}, {"mode_plan.ansi", ModePlan}} {
		b, err := os.ReadFile("testdata/" + f.file)
		if err != nil {
			t.Fatal(err)
		}
		got, ok := parseModeLine(strings.Split(string(b), "\n"))
		if !ok || got != f.want {
			t.Errorf("%s: got %q ok=%v", f.file, got, ok)
		}
	}
}

func TestWalkMode(t *testing.T) {
	// default → acceptEdits → plan → auto → default, as on an account without bypass.
	cycle := []string{ModeAcceptEdits, ModePlan, ModeAuto, ModeDefault}
	mk := func() modeStep {
		i := 0
		return func() (string, error) {
			m := cycle[i%len(cycle)]
			i++
			return m, nil
		}
	}
	got, err := walkMode(ModeAuto, mk(), 6)
	if err != nil || got != ModeAuto {
		t.Fatalf("got %q err=%v", got, err)
	}
	got, err = walkMode(ModeBypass, mk(), 6)
	if err == nil || !strings.Contains(err.Error(), "not in this session's cycle") {
		t.Fatalf("bypass must fail on this cycle: %q %v", got, err)
	}
	boom := errors.New("tmux gone")
	if _, err := walkMode(ModePlan, func() (string, error) { return "", boom }, 3); !errors.Is(err, boom) {
		t.Fatalf("want the tmux error, got %v", err)
	}
}
