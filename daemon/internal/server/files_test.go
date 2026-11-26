package server

import (
	"encoding/base64"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/ZerkerEOD/porthole/daemon/internal/core"
)

var pngBytes, _ = base64.StdEncoding.DecodeString("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==")

func TestSafeUploadName(t *testing.T) {
	cases := map[string]string{
		"../../etc/passwd":      "passwd.png",
		"My Photo (1).JPG":      "MyPhoto1.png",
		"..":                    "image.png",
		"":                      "image.png",
		`C:\x\shot.webp`:        "shot.png",
		strings.Repeat("a", 90): strings.Repeat("a", 60) + ".png",
	}
	for in, want := range cases {
		if got := safeUploadName(in, ".png"); got != want {
			t.Errorf("safeUploadName(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestPutUpload(t *testing.T) {
	root := filepath.Join(t.TempDir(), "uploads")
	s := core.Session{Key: "claude:s1", ID: "s1"}
	now := time.Now()
	data := base64.StdEncoding.EncodeToString(pngBytes)

	if _, _, err := putUpload(root, s, FilePutReq{Name: "a.png", MediaType: "image/svg+xml", Data: data}, now); err == nil {
		t.Fatal("svg accepted")
	}
	if _, _, err := putUpload(root, s, FilePutReq{Name: "a.png", MediaType: "image/png", Data: "!!not base64!!"}, now); err == nil {
		t.Fatal("bad base64 accepted")
	}
	big := base64.StdEncoding.EncodeToString(make([]byte, maxFileBytes+1))
	if _, _, err := putUpload(root, s, FilePutReq{Name: "a.png", MediaType: "image/png", Data: big}, now); err == nil || !strings.Contains(err.Error(), "10 MB") {
		t.Fatalf("oversize: %v", err)
	}
	if _, _, err := putUpload(root, core.Session{ID: ".."}, FilePutReq{Name: "a.png", MediaType: "image/png", Data: data}, now); err == nil {
		t.Fatal("bad session id accepted")
	}

	// An old upload is pruned by the next put.
	old := filepath.Join(root, "s0", "old.png")
	_ = os.MkdirAll(filepath.Dir(old), 0o700)
	_ = os.WriteFile(old, pngBytes, 0o600)
	_ = os.Chtimes(old, now.Add(-8*24*time.Hour), now.Add(-8*24*time.Hour))

	path, n, err := putUpload(root, s, FilePutReq{Name: "../shot.jpeg", MediaType: "image/png", Data: data}, now)
	if err != nil || n != len(pngBytes) {
		t.Fatalf("put %v %d", err, n)
	}
	if want := filepath.Join(root, "s1", strconv.FormatInt(now.Unix(), 10)+"-shot.png"); path != want {
		t.Fatalf("path %q want %q", path, want)
	}
	if fi, err := os.Stat(path); err != nil || fi.Mode().Perm() != 0o600 {
		t.Fatalf("file %v %v", fi, err)
	}
	if fi, err := os.Stat(filepath.Dir(path)); err != nil || fi.Mode().Perm() != 0o700 {
		t.Fatalf("dir %v %v", fi, err)
	}
	if _, err := os.Stat(filepath.Dir(old)); !os.IsNotExist(err) {
		t.Fatalf("old upload not pruned: %v", err)
	}
	// The same name in the same second gets a new file.
	path2, _, err := putUpload(root, s, FilePutReq{Name: "shot", MediaType: "image/png", Data: data}, now)
	if err != nil || path2 == path {
		t.Fatalf("second put %q %v", path2, err)
	}
	// The stored file can be read back.
	fd, err := getFile(root, s, path)
	if err != nil || fd.Bytes != len(pngBytes) || fd.MediaType != "image/png" {
		t.Fatalf("get upload %+v %v", fd, err)
	}
}

func TestGetFile(t *testing.T) {
	cwd := t.TempDir()
	outside := t.TempDir()
	uploads := t.TempDir()
	s := core.Session{Key: "claude:s1", ID: "s1", Cwd: cwd}
	in := filepath.Join(cwd, "sub", "pic.PNG")
	_ = os.MkdirAll(filepath.Dir(in), 0o755)
	if err := os.WriteFile(in, pngBytes, 0o644); err != nil {
		t.Fatal(err)
	}
	fd, err := getFile(uploads, s, in)
	if err != nil || fd.MediaType != "image/png" || fd.Bytes != len(pngBytes) || fd.Data != base64.StdEncoding.EncodeToString(pngBytes) {
		t.Fatalf("file in cwd: %+v %v", fd, err)
	}

	secret := filepath.Join(outside, "secret.png")
	_ = os.WriteFile(secret, pngBytes, 0o600)
	if _, err := getFile(uploads, s, secret); err == nil {
		t.Fatal("file outside the roots served")
	}
	// A link inside the cwd pointing outside is refused.
	link := filepath.Join(cwd, "link.png")
	if err := os.Symlink(secret, link); err != nil {
		t.Fatal(err)
	}
	if fd, err := getFile(uploads, s, link); err == nil || fd.Data != "" {
		t.Fatal("symlink to outside served")
	}
	// A dot-dot path that escapes the cwd is refused.
	if _, err := getFile(uploads, s, filepath.Join(cwd, "..", filepath.Base(outside), "secret.png")); err == nil {
		t.Fatal("dot-dot escape served")
	}
	// Wrong extension, relative path, directory, oversize.
	txt := filepath.Join(cwd, "notes.txt")
	_ = os.WriteFile(txt, []byte("x"), 0o600)
	if _, err := getFile(uploads, s, txt); err == nil {
		t.Fatal("text file served")
	}
	if _, err := getFile(uploads, s, "sub/pic.PNG"); err == nil {
		t.Fatal("relative path served")
	}
	dir := filepath.Join(cwd, "d.png")
	_ = os.Mkdir(dir, 0o700)
	if _, err := getFile(uploads, s, dir); err == nil {
		t.Fatal("directory served")
	}
	huge := filepath.Join(cwd, "huge.png")
	f, _ := os.Create(huge)
	_ = f.Truncate(maxFileBytes + 1)
	f.Close()
	if _, err := getFile(uploads, s, huge); err == nil {
		t.Fatal("oversize file served")
	}
	// A session in / gets no cwd access.
	if _, err := getFile(uploads, core.Session{ID: "s1", Cwd: "/"}, in); err == nil {
		t.Fatal("cwd / allowed a file")
	}
}

func TestGetFileScratchpad(t *testing.T) {
	base := t.TempDir()
	old := scratchRoot
	scratchRoot = base
	t.Cleanup(func() { scratchRoot = old })
	s := core.Session{ID: "0b1c2d3e-aaaa", Cwd: t.TempDir()}
	pad := filepath.Join(base, "claude-1000", "-home-u-proj", s.ID, "scratchpad")
	_ = os.MkdirAll(pad, 0o700)
	img := filepath.Join(pad, "shot.png")
	_ = os.WriteFile(img, pngBytes, 0o600)
	if _, err := getFile(t.TempDir(), s, img); err != nil {
		t.Fatalf("scratchpad file refused: %v", err)
	}
	other := filepath.Join(base, "claude-1000", "-home-u-proj", "another-session", "x.png")
	_ = os.MkdirAll(filepath.Dir(other), 0o700)
	_ = os.WriteFile(other, pngBytes, 0o600)
	if _, err := getFile(t.TempDir(), s, other); err == nil {
		t.Fatal("another session's scratchpad served")
	}
	notClaude := filepath.Join(base, "other", s.ID, "x.png")
	_ = os.MkdirAll(filepath.Dir(notClaude), 0o700)
	_ = os.WriteFile(notClaude, pngBytes, 0o600)
	if _, err := getFile(t.TempDir(), s, notClaude); err == nil {
		t.Fatal("non-claude temp dir served")
	}
}
