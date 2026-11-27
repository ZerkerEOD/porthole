package server

import (
	"fmt"
	"strings"
	"testing"
	"time"
	"unicode/utf8"
)

func TestConnLogRing(t *testing.T) {
	c := newConnLog(3)
	if got := c.recent(); len(got) != 0 {
		t.Fatalf("empty log returned %d entries", len(got))
	}
	c.add(ConnAttempt{From: "a", Path: PathPair, Result: ResultUnauthorized})
	c.add(ConnAttempt{From: "b", Path: PathWebSocket, Result: ResultAccepted})
	got := c.recent()
	if len(got) != 2 || got[0].From != "b" || got[1].From != "a" {
		t.Fatalf("newest first expected, got %+v", got)
	}
	if got[0].At.IsZero() {
		t.Fatal("timestamp not set")
	}
	for i := 0; i < 5; i++ {
		c.add(ConnAttempt{From: fmt.Sprint(i), Path: PathHTTP, Result: ResultRejectedPublic, At: time.Unix(int64(i), 0)})
	}
	got = c.recent()
	if len(got) != 3 {
		t.Fatalf("ring should hold 3, got %d", len(got))
	}
	for i, want := range []string{"4", "3", "2"} {
		if got[i].From != want {
			t.Errorf("entry %d = %s, want %s", i, got[i].From, want)
		}
	}
}

func TestConnLogSize(t *testing.T) {
	c := newConnLog(connLogSize)
	for i := 0; i < connLogSize*2; i++ {
		c.add(ConnAttempt{From: fmt.Sprint(i)})
	}
	got := c.recent()
	if len(got) != connLogSize || got[0].From != fmt.Sprint(connLogSize*2-1) {
		t.Fatalf("got %d entries, first %q", len(got), got[0].From)
	}
}

func TestPathKind(t *testing.T) {
	for p, want := range map[string]string{"/v1/pair": PathPair, "/v1/ws": PathWebSocket, "/v1/health": PathHTTP, "/": PathHTTP} {
		if got := pathKind(p); got != want {
			t.Errorf("pathKind(%s) = %s, want %s", p, got, want)
		}
	}
	if remoteHost("[::1]:5000") != "::1" || remoteHost("1.2.3.4:5") != "1.2.3.4" || remoteHost("1.2.3.4") != "1.2.3.4" {
		t.Error("remoteHost")
	}
}

func TestConnLogCleansNames(t *testing.T) {
	c := newConnLog(4)
	c.add(ConnAttempt{From: "10.0.0.9", Path: PathPair, Result: ResultUnauthorized, Name: "\x1b]0;evil\x07ph\tone\x1b[2J"})
	got := c.recent()[0].Name
	if got != "]0;evilphone[2J" { // ESC, BEL and TAB gone, so no sequence survives
		t.Fatalf("name not cleaned: %q", got)
	}
	long := strings.Repeat("é", 100)
	if n := cleanName(long, maxDeviceName); len([]rune(n)) != maxDeviceName || !utf8.ValidString(n) {
		t.Fatalf("clip: %d runes valid=%v", len([]rune(n)), utf8.ValidString(n))
	}
}
