package claude

import "testing"

func TestUnwrapPasted(t *testing.T) {
	in := "\n\n<pasted_content id=\"a7ac\">\nI ran this in a separate window:\n```\n$ echo hi\nhi\n[exit 0]\n```\n</pasted_content id=\"a7ac\">\n"
	want := "I ran this in a separate window:\n```\n$ echo hi\nhi\n[exit 0]\n```"
	if got := unwrapPasted(in); got != want {
		t.Fatalf("got %q", got)
	}
	if got := unwrapPasted("plain text"); got != "plain text" {
		t.Fatalf("plain text changed: %q", got)
	}
}
