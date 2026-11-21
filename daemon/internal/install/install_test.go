package install

import (
	"os"
	"testing"
)

// The unit shipped in the release archive and the one `porthole install`
// writes must be the same file.
func TestUnitMatchesPackaging(t *testing.T) {
	b, err := os.ReadFile("../../packaging/porthole.service")
	if err != nil {
		t.Skip("packaging dir not present")
	}
	if string(b) != Unit {
		t.Fatal("internal/install.Unit differs from packaging/porthole.service")
	}
}

func TestBinaryCopiesAndIsIdempotent(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	src := home + "/src-porthole"
	if err := os.WriteFile(src, []byte("#!/bin/sh\necho hi\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	dst, err := Binary(src)
	if err != nil {
		t.Fatal(err)
	}
	if dst != home+"/.local/bin/porthole" {
		t.Fatal("unexpected dst", dst)
	}
	st, err := os.Stat(dst)
	if err != nil || st.Mode()&0o111 == 0 {
		t.Fatal("binary not executable")
	}
	if _, err := Binary(dst); err != nil {
		t.Fatal("re-install of the installed binary should be a no-op:", err)
	}
}
