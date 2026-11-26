package tmux

import (
	"context"
	"os/exec"
	"reflect"
	"strings"
	"testing"
	"time"
)

func TestKeyCommands(t *testing.T) {
	got, err := keyCommands("%3", []string{"C-u", "x", "y", "Enter", "Down", "-", "Enter"})
	if err != nil {
		t.Fatal(err)
	}
	want := [][]string{
		{"send-keys", "-t", "%3", "C-u"},
		{"send-keys", "-t", "%3", "-l", "--", "x", "y"},
		{"send-keys", "-t", "%3", "Enter", "Down"},
		{"send-keys", "-t", "%3", "-l", "--", "-"},
		{"send-keys", "-t", "%3", "Enter"},
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("argv:\n got %q\nwant %q", got, want)
	}
	for _, bad := range [][]string{nil, {"rm -rf /"}, {";"}, {"\x01"}, {"Enter", "ab"}} {
		if _, err := keyCommands("%3", bad); err == nil {
			t.Fatalf("keys %q accepted", bad)
		}
	}
	if _, err := keyCommands("3", []string{"Enter"}); err == nil {
		t.Fatal("bad pane id accepted")
	}
}

// These tests drive a private tmux server (-L) so they never touch the
// user's sessions. They are skipped when tmux is not installed.
func testClient(t *testing.T) (*Client, func()) {
	t.Helper()
	if _, err := exec.LookPath("tmux"); err != nil {
		t.Skip("tmux not installed")
	}
	sock := "porthole-test-" + strings.ReplaceAll(t.Name(), "/", "-")
	c := &Client{Binary: "tmux"}
	// Route every call through the private socket by wrapping the binary.
	c.Binary = "tmux"
	c.extraArgs = []string{"-L", sock}
	cleanup := func() { _, _ = c.run(context.Background(), "kill-server") }
	return c, cleanup
}

func TestSpawnSendCapture(t *testing.T) {
	c, cleanup := testClient(t)
	defer cleanup()
	ctx := context.Background()
	pane, err := c.NewSession(ctx, "t1", t.TempDir(), []string{"sh", "-c", "while read l; do echo \"got:$l\"; done"}, nil)
	if err != nil {
		t.Fatal(err)
	}
	if !ValidPaneID(pane) {
		t.Fatalf("pane %q", pane)
	}
	panes, err := c.ListPanes(ctx)
	if err != nil || len(panes) != 1 || panes[0].PaneID != pane || panes[0].SessionName != "t1" {
		t.Fatalf("panes: %+v %v", panes, err)
	}
	// Literal text with shell metacharacters must arrive unchanged.
	in := `hello $(id) "quoted" ; echo nope`
	if err := c.SendText(ctx, pane, in, true); err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(3 * time.Second)
	var scr *Screen
	for time.Now().Before(deadline) {
		scr, err = c.Capture(ctx, pane, 50)
		if err == nil && strings.Contains(strings.Join(scr.Lines, "\n"), "got:"+in) {
			break
		}
		time.Sleep(100 * time.Millisecond)
	}
	if scr == nil || !strings.Contains(strings.Join(scr.Lines, "\n"), "got:"+in) {
		t.Fatalf("literal text not echoed; screen=%v", scr)
	}
	// Multi-line goes through paste-buffer.
	if err := c.SendText(ctx, pane, "a\nb", true); err != nil {
		t.Fatal(err)
	}
	// Keys: a literal after a named key must be typed, not "-l".
	if err := c.SendKeys(ctx, pane, []string{"C-u", "x", "Enter"}); err != nil {
		t.Fatal(err)
	}
	deadline = time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		scr, err = c.Capture(ctx, pane, 50)
		if err == nil && strings.Contains(strings.Join(scr.Lines, "\n"), "got:x") {
			break
		}
		time.Sleep(100 * time.Millisecond)
	}
	if scr == nil || !strings.Contains(strings.Join(scr.Lines, "\n"), "got:x") {
		t.Fatalf("literal key after named key not typed; screen=%v", scr)
	}
	if err := c.SendKeys(ctx, pane, []string{"rm -rf /"}); err == nil {
		t.Fatal("multi-char key accepted")
	}
	if err := c.SendKeys(ctx, pane, []string{";"}); err == nil {
		t.Fatal("semicolon accepted")
	}
	if err := c.SendText(ctx, "%999999999", "x", false); err == nil {
		t.Fatal("bad pane id accepted")
	}
	if err := c.SendText(ctx, "t1; kill-server", "x", false); err == nil {
		t.Fatal("injected target accepted")
	}
	if !c.HasSession(ctx, "t1") || c.HasSession(ctx, "t") {
		t.Fatal("HasSession exact match broken")
	}
	if err := c.KillSession(ctx, "t1"); err != nil {
		t.Fatal(err)
	}
}

func TestSpawnWrapper(t *testing.T) {
	if w := spawnWrapper(true, true, true, 1); w != nil {
		t.Fatalf("server running: want no wrapper, got %v", w)
	}
	if w := spawnWrapper(false, false, true, 1); w != nil {
		t.Fatalf("no systemd-run: want no wrapper, got %v", w)
	}
	if w := spawnWrapper(false, true, false, 1); w != nil {
		t.Fatalf("outside a service: want no wrapper, got %v", w)
	}
	w := spawnWrapper(false, true, true, 42)
	want := []string{"systemd-run", "--user", "--scope", "--quiet", "--collect", "--unit", "porthole-tmux-42", "--"}
	if strings.Join(w, " ") != strings.Join(want, " ") {
		t.Fatalf("wrapper = %v", w)
	}
}

func TestNewWindowKillWindow(t *testing.T) {
	c, cleanup := testClient(t)
	defer cleanup()
	ctx := context.Background()
	if _, err := c.NewSession(ctx, "w1", t.TempDir(), []string{"sh", "-c", "sleep 30"}, nil); err != nil {
		t.Fatal(err)
	}
	dir := t.TempDir()
	pane, err := c.NewWindow(ctx, "w1", "ph-run-abc", dir, []string{"sh", "-c", "echo \"$1\"; sleep 30", "x", "arg with $(id) ; spaces"})
	if err != nil {
		t.Fatal(err)
	}
	if !ValidPaneID(pane) {
		t.Fatalf("pane %q", pane)
	}
	panes, err := c.ListPanes(ctx)
	if err != nil || len(panes) != 2 {
		t.Fatalf("panes %+v %v", panes, err)
	}
	deadline := time.Now().Add(3 * time.Second)
	for {
		scr, err := c.Capture(ctx, pane, 10)
		if err == nil && strings.Contains(strings.Join(scr.Lines, "\n"), "arg with $(id) ; spaces") {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("argument not echoed literally: %v %v", scr, err)
		}
		time.Sleep(50 * time.Millisecond)
	}
	if err := c.KillWindow(ctx, pane); err != nil {
		t.Fatal(err)
	}
	panes, _ = c.ListPanes(ctx)
	if len(panes) != 1 || panes[0].PaneID == pane {
		t.Fatalf("window not killed: %+v", panes)
	}
	if _, err := c.NewWindow(ctx, "w1;x", "n", dir, []string{"true"}); err == nil {
		t.Fatal("bad session name accepted")
	}
	if err := c.KillWindow(ctx, "w1"); err == nil {
		t.Fatal("bad pane id accepted")
	}
}

func TestLeadingBang(t *testing.T) {
	for _, c := range []struct {
		in, lead, rest string
		ok             bool
	}{
		{"!cat x", "!", "cat x", true},
		{"! cat x", "!", "cat x", true},
		{"!", "", "!", false},
		{"cat !x", "", "cat !x", false},
		{"", "", "", false},
	} {
		lead, rest, ok := leadingBang(c.in)
		if lead != c.lead || rest != c.rest || ok != c.ok {
			t.Errorf("%q: got %q %q %v", c.in, lead, rest, ok)
		}
	}
}
