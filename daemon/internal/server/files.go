package server

import (
	"encoding/base64"
	"errors"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/ZerkerEOD/porthole/daemon/internal/config"
	"github.com/ZerkerEOD/porthole/daemon/internal/core"
	"github.com/ZerkerEOD/porthole/daemon/internal/transcript"
)

// Limits on image files moved between the app and a session.
const (
	maxFileBytes     = 10 * 1024 * 1024
	uploadKeep       = 7 * 24 * time.Hour
	maxUploadNameLen = 64
	// maxUploadMessageBytes is the WebSocket read limit; only file.put may
	// use more than maxMessageBytes. 10 MB in base64 plus the envelope.
	maxUploadMessageBytes = 16 * 1024 * 1024
)

// FilePutReq uploads an image into the session's upload directory.
type FilePutReq struct {
	Key       string `json:"key"`
	Name      string `json:"name"`
	MediaType string `json:"media_type"`
	Data      string `json:"data"`
}

// FilePut is the reply to file.put: the absolute path of the stored file.
type FilePut struct {
	Path string `json:"path"`
}

// FileGetReq asks for an image file a session can see.
type FileGetReq struct {
	Key  string `json:"key"`
	Path string `json:"path"`
}

// FileData is the reply to file.get.
type FileData struct {
	MediaType string `json:"media_type"`
	Data      string `json:"data"`
	Bytes     int    `json:"bytes"`
}

// imageExt maps the accepted media types to the extension a stored file gets.
var imageExt = map[string]string{
	"image/png":  ".png",
	"image/jpeg": ".jpg",
	"image/webp": ".webp",
	"image/gif":  ".gif",
}

// extMediaType maps the extensions file.get serves to their media types.
var extMediaType = map[string]string{
	".png":  "image/png",
	".jpg":  "image/jpeg",
	".jpeg": "image/jpeg",
	".webp": "image/webp",
	".gif":  "image/gif",
}

var unsafeNameRe = regexp.MustCompile(`[^A-Za-z0-9._-]`)

// safeUploadName reduces a client file name to its base name with only
// [A-Za-z0-9._-], at most 64 characters, ending in ext.
func safeUploadName(name, ext string) string {
	base := name
	if i := strings.LastIndexAny(base, `/\`); i >= 0 {
		base = base[i+1:]
	}
	base = unsafeNameRe.ReplaceAllString(base, "")
	if e := filepath.Ext(base); e != "" {
		base = strings.TrimSuffix(base, e)
	}
	base = strings.Trim(base, ".")
	if base == "" {
		base = "image"
	}
	if max := maxUploadNameLen - len(ext); len(base) > max {
		base = base[:max]
	}
	return base + ext
}

// validSessionDir reports whether a session id is safe as one path element.
func validSessionDir(id string) bool {
	return id != "" && id != "." && id != ".." && len(id) <= 128 && !unsafeNameRe.MatchString(id)
}

// putUpload stores an uploaded image under root/<session id>/ and returns
// its absolute path. Files older than seven days are pruned first.
func putUpload(root string, s core.Session, req FilePutReq, now time.Time) (string, int, error) {
	ext, ok := imageExt[req.MediaType]
	if !ok {
		return "", 0, errors.New("media type not allowed (png, jpeg, webp or gif)")
	}
	if !validSessionDir(s.ID) {
		return "", 0, errors.New("session has no usable id")
	}
	if transcript.Base64Size(req.Data) > maxFileBytes {
		return "", 0, errors.New("file larger than 10 MB")
	}
	data, err := base64.StdEncoding.DecodeString(req.Data)
	if err != nil {
		return "", 0, errors.New("data is not valid base64")
	}
	if len(data) == 0 {
		return "", 0, errors.New("empty file")
	}
	if len(data) > maxFileBytes {
		return "", 0, errors.New("file larger than 10 MB")
	}
	root, err = filepath.Abs(root)
	if err != nil {
		return "", 0, err
	}
	pruneUploads(root, now.Add(-uploadKeep))
	dir := filepath.Join(root, s.ID)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return "", 0, err
	}
	_ = os.Chmod(root, 0o700)
	_ = os.Chmod(dir, 0o700)
	name := safeUploadName(req.Name, ext)
	prefix := strconv.FormatInt(now.Unix(), 10) + "-"
	for i := 0; i < 100; i++ {
		fn := prefix + name
		if i > 0 {
			fn = prefix + strings.TrimSuffix(name, ext) + "-" + strconv.Itoa(i) + ext
		}
		path := filepath.Join(dir, fn)
		f, err := os.OpenFile(path, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o600)
		if errors.Is(err, os.ErrExist) {
			continue
		}
		if err != nil {
			return "", 0, err
		}
		_, werr := f.Write(data)
		if cerr := f.Close(); werr == nil {
			werr = cerr
		}
		if werr != nil {
			_ = os.Remove(path)
			return "", 0, werr
		}
		return path, len(data), nil
	}
	return "", 0, errors.New("could not pick a file name")
}

// pruneUploads removes uploads modified before cutoff and session
// directories left empty.
func pruneUploads(root string, cutoff time.Time) {
	dirs, err := os.ReadDir(root)
	if err != nil {
		return
	}
	for _, d := range dirs {
		if !d.IsDir() {
			continue
		}
		dir := filepath.Join(root, d.Name())
		ents, err := os.ReadDir(dir)
		if err != nil {
			continue
		}
		left := 0
		for _, e := range ents {
			fi, err := e.Info()
			if err == nil && e.Type().IsRegular() && fi.ModTime().Before(cutoff) {
				_ = os.Remove(filepath.Join(dir, e.Name()))
				continue
			}
			left++
		}
		if left == 0 {
			_ = os.Remove(dir)
		}
	}
}

// within reports whether path lies strictly below dir. Both are cleaned
// absolute paths.
func within(path, dir string) bool {
	rel, err := filepath.Rel(dir, path)
	return err == nil && rel != "." && rel != ".." && !strings.HasPrefix(rel, ".."+string(filepath.Separator)) && !filepath.IsAbs(rel)
}

// resolvedDir returns dir with symlinks resolved, or "" when it does not
// exist or is the file system root.
func resolvedDir(dir string) string {
	if dir == "" || !filepath.IsAbs(dir) {
		return ""
	}
	d, err := filepath.EvalSymlinks(dir)
	if err != nil || d == string(filepath.Separator) {
		return ""
	}
	return d
}

// scratchRoot is where the CLI keeps per-session scratch directories:
// /tmp/claude-<uid>/<project>/<session id>/.
var scratchRoot = "/tmp"

// inScratchpad reports whether real lies below a directory named after the
// session somewhere under scratchRoot/claude-*/, where that claude-*
// directory belongs to this user (the parent is shared with other users).
func inScratchpad(real, sessionID string) bool {
	if !validSessionDir(sessionID) {
		return false
	}
	base := resolvedDir(scratchRoot)
	if base == "" {
		return false
	}
	rel, err := filepath.Rel(base, real)
	if err != nil || strings.HasPrefix(rel, "..") {
		return false
	}
	parts := strings.Split(rel, string(filepath.Separator))
	if len(parts) < 3 || !strings.HasPrefix(parts[0], "claude-") {
		return false
	}
	fi, err := os.Stat(filepath.Join(base, parts[0]))
	if err != nil || !fi.IsDir() {
		return false
	}
	if st, ok := fi.Sys().(*syscall.Stat_t); !ok || int(st.Uid) != os.Getuid() {
		return false
	}
	// The session id must be a directory element, not the file itself.
	for _, p := range parts[1 : len(parts)-1] {
		if p == sessionID {
			return true
		}
	}
	return false
}

// errFileRefused is the one error file.get returns for a path it will not
// serve, so a client cannot probe which files exist.
var errFileRefused = errors.New("file not available: only png, jpeg, webp or gif files up to 10 MB in the session's directory, its uploads or its scratchpad")

// getFile reads an image the session may show: one whose real path lies in
// the session's working directory, its upload directory or its scratchpad.
func getFile(uploadsRoot string, s core.Session, path string) (FileData, error) {
	// The CLI and the model write home-relative paths as "~/…"; the app
	// passes them on unchanged.
	if strings.HasPrefix(path, "~/") {
		if home, err := os.UserHomeDir(); err == nil {
			path = filepath.Join(home, path[2:])
		}
	}
	if path == "" || !filepath.IsAbs(path) {
		return FileData{}, errors.New("path must be absolute")
	}
	real, err := filepath.EvalSymlinks(filepath.Clean(path))
	if err != nil {
		return FileData{}, errFileRefused
	}
	mt, ok := extMediaType[strings.ToLower(filepath.Ext(real))]
	if !ok {
		return FileData{}, errFileRefused
	}
	allowed := false
	if d := resolvedDir(s.Cwd); d != "" && within(real, d) {
		allowed = true
	}
	if !allowed && validSessionDir(s.ID) {
		if d := resolvedDir(filepath.Join(uploadsRoot, s.ID)); d != "" && within(real, d) {
			allowed = true
		}
	}
	if !allowed && inScratchpad(real, s.ID) {
		allowed = true
	}
	if !allowed {
		return FileData{}, errFileRefused
	}
	// O_NOFOLLOW: the resolved path must not have become a link since.
	f, err := os.OpenFile(real, os.O_RDONLY|syscall.O_NOFOLLOW|syscall.O_NONBLOCK, 0)
	if err != nil {
		return FileData{}, errFileRefused
	}
	defer f.Close()
	fi, err := f.Stat()
	if err != nil || !fi.Mode().IsRegular() || fi.Size() > maxFileBytes {
		return FileData{}, errFileRefused
	}
	b, err := io.ReadAll(io.LimitReader(f, maxFileBytes+1))
	if err != nil || len(b) > maxFileBytes {
		return FileData{}, errFileRefused
	}
	return FileData{MediaType: mt, Data: base64.StdEncoding.EncodeToString(b), Bytes: len(b)}, nil
}

// uploadsDir is where file.put stores images, by session id.
func (h *hub) uploadsDir() string {
	if h.uploads != "" {
		return h.uploads
	}
	return filepath.Join(config.StateDir(), "uploads")
}
