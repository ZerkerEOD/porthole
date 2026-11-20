package server

import (
	"net/netip"
	"testing"
)

func TestPairingFlow(t *testing.T) {
	s, err := OpenStore(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	code, _, err := s.NewPairingCode("test")
	if err != nil || len(code) != pairingCodeLength {
		t.Fatalf("code %q %v", code, err)
	}
	if _, _, err := s.Pair("1.2.3.4", "WRONGCOD", "p", ""); err != ErrBadCode {
		t.Fatalf("expected bad code, got %v", err)
	}
	d, tok, err := s.Pair("1.2.3.4", code, "my phone", "")
	if err != nil || tok == "" || d.ID == "" {
		t.Fatalf("pair: %v", err)
	}
	if _, _, err := s.Pair("1.2.3.4", code, "again", ""); err != ErrBadCode {
		t.Fatalf("code reuse should fail, got %v", err)
	}
	if got, ok := s.Authenticate(tok); !ok || got.ID != d.ID {
		t.Fatal("auth failed")
	}
	if _, ok := s.Authenticate(tok + "x"); ok {
		t.Fatal("bad token accepted")
	}
	// Reload from disk.
	s2, err := OpenStore(s.path[:len(s.path)-len("/devices.json")])
	if err != nil {
		t.Fatal(err)
	}
	if _, ok := s2.Authenticate(tok); !ok {
		t.Fatal("token lost on reload")
	}
	if err := s2.Revoke(d.ID); err != nil {
		t.Fatal(err)
	}
	if _, ok := s2.Authenticate(tok); ok {
		t.Fatal("revoked token accepted")
	}
	if len(s2.DrainRevoked()) != 1 {
		t.Fatal("revoked id not drained")
	}
}

func TestPairingBruteForceLimit(t *testing.T) {
	s, _ := OpenStore(t.TempDir())
	code, _, _ := s.NewPairingCode("")
	for i := 0; i < pairingMaxPerMin; i++ {
		if _, _, err := s.Pair("src", "AAAAAAAA", "", ""); err != ErrBadCode {
			t.Fatalf("attempt %d: %v", i, err)
		}
	}
	if _, _, err := s.Pair("src", code, "", ""); err != ErrRateLimited {
		t.Fatalf("expected rate limit, got %v", err)
	}
	// Another source is unaffected.
	if _, _, err := s.Pair("other", code, "", ""); err != nil {
		t.Fatalf("other source: %v", err)
	}
}

func TestBindPolicy(t *testing.T) {
	for _, a := range []string{"127.0.0.1", "10.1.2.3", "192.168.1.9", "172.16.0.1", "100.100.1.1", "fd00::1", "::1"} {
		if !IsPrivateAddr(netip.MustParseAddr(a)) {
			t.Errorf("%s should be private", a)
		}
	}
	for _, a := range []string{"8.8.8.8", "1.1.1.1", "2001:db8::1", "100.128.0.1"} {
		if IsPrivateAddr(netip.MustParseAddr(a)) {
			t.Errorf("%s should be public", a)
		}
	}
	if _, err := ListenAddrs([]string{"8.8.8.8"}, false); err == nil {
		t.Fatal("public bind must be refused")
	}
	if _, err := ListenAddrs([]string{"8.8.8.8"}, true); err != nil {
		t.Fatal("public bind with flag should pass policy")
	}
	if !RemoteAllowed("100.64.5.5:1234", false) || RemoteAllowed("8.8.8.8:1", false) {
		t.Fatal("remote policy wrong")
	}
}
