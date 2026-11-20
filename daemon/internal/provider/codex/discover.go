package codex

import (
	"bufio"
	"encoding/json"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/ZerkerEOD/porthole/daemon/internal/provider"
	"github.com/ZerkerEOD/porthole/daemon/internal/tmux"
)

// Profile is one CODEX_HOME.
type Profile struct {
	Dir      string
	Sessions string // real path of <dir>/sessions
}

// DefaultProfileDir is ~/.codex unless CODEX_HOME is set for the daemon.
func DefaultProfileDir() string {
	if v := os.Getenv("CODEX_HOME"); v != "" {
		return v
	}
	h, _ := os.UserHomeDir()
	return filepath.Join(h, ".codex")
}

// Profiles unions default, process-env and extra CODEX_HOME dirs.
func Profiles(extra []string, procs map[int]tmux.Process) []Profile {
	cands := []string{DefaultProfileDir()}
	cands = append(cands, extra...)
	for pid, p := range procs {
		if p.Name != "codex" {
			continue
		}
		if v := tmux.Environ(pid)["CODEX_HOME"]; v != "" {
			cands = append(cands, v)
		}
	}
	seen := map[string]bool{}
	var out []Profile
	for _, d := range cands {
		real, err := filepath.EvalSymlinks(filepath.Join(d, "sessions"))
		if err != nil {
			continue
		}
		if seen[real] {
			continue
		}
		seen[real] = true
		out = append(out, Profile{Dir: d, Sessions: real})
	}
	return out
}

// Info summarizes a rollout file.
type Info struct {
	SessionID   string    `json:"session_id"`
	Path        string    `json:"path"`
	Cwd         string    `json:"cwd"`
	GitBranch   string    `json:"git_branch,omitempty"`
	Version     string    `json:"version,omitempty"`
	Source      string    `json:"source,omitempty"` // cli|exec|vscode
	Title       string    `json:"title,omitempty"`
	FirstPrompt string    `json:"first_prompt,omitempty"`
	LastPrompt  string    `json:"last_prompt,omitempty"`
	Model       string    `json:"model,omitempty"`
	StartedAt   time.Time `json:"started_at"`
	UpdatedAt   time.Time `json:"updated_at"`
	Size        int64     `json:"size"`
}

// Summarize reads the head (and tail for the last prompt) of a rollout.
func Summarize(path string) (*Info, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	st, err := f.Stat()
	if err != nil {
		return nil, err
	}
	info := &Info{Path: path, Size: st.Size(), UpdatedAt: st.ModTime(), SessionID: SessionIDFromFilename(filepath.Base(path))}
	apply := func(l line) {
		var pl payload
		if json.Unmarshal(l.Payload, &pl) != nil {
			return
		}
		switch l.Type {
		case "session_meta":
			info.Cwd, info.Version, info.Source = pl.Cwd, pl.CLIVer, pl.Source
			if pl.ID != "" {
				info.SessionID = pl.ID
			}
			if pl.Git != nil {
				info.GitBranch = pl.Git.Branch
			}
			info.StartedAt = parseTime(l.Timestamp)
		case "turn_context":
			if pl.Model != "" {
				info.Model = pl.Model
			}
		case "event_msg":
			if pl.Type == "user_message" && pl.Message != "" {
				if info.FirstPrompt == "" {
					info.FirstPrompt = firstLine(pl.Message, 120)
				}
				info.LastPrompt = firstLine(pl.Message, 120)
			}
			if t := parseTime(l.Timestamp); !t.IsZero() {
				info.UpdatedAt = t
			}
		}
	}
	scan := func(r io.Reader) {
		sc := bufio.NewScanner(r)
		sc.Buffer(make([]byte, 1<<20), 1<<20)
		for sc.Scan() {
			var l line
			if json.Unmarshal(sc.Bytes(), &l) == nil {
				apply(l)
			}
		}
	}
	const head, tail = 128 * 1024, 128 * 1024
	scan(io.LimitReader(f, head))
	if st.Size() > head {
		start := st.Size() - tail
		if start < head {
			start = head
		}
		if _, err := f.Seek(start, io.SeekStart); err == nil {
			r := bufio.NewReader(f)
			_, _ = r.ReadBytes('\n')
			scan(r)
		}
	}
	info.Title = info.FirstPrompt
	return info, nil
}

func firstLine(s string, max int) string {
	s = strings.TrimSpace(s)
	if i := strings.IndexByte(s, '\n'); i >= 0 {
		s = s[:i]
	}
	r := []rune(s)
	if len(r) > max {
		return string(r[:max]) + "…"
	}
	return s
}

// ListRollouts returns rollout files under a profile, newest first.
func ListRollouts(profile Profile, minSize int64) ([]Info, error) {
	var out []Info
	err := filepath.WalkDir(profile.Sessions, func(p string, d os.DirEntry, err error) error {
		if err != nil {
			return nil
		}
		if d.IsDir() || !strings.HasPrefix(d.Name(), "rollout-") || !strings.HasSuffix(d.Name(), ".jsonl") {
			return nil
		}
		st, err := d.Info()
		if err != nil || st.Size() < minSize {
			return nil
		}
		out = append(out, Info{Path: p, SessionID: SessionIDFromFilename(d.Name()), Size: st.Size(), UpdatedAt: st.ModTime()})
		return nil
	})
	if err != nil {
		return nil, err
	}
	sort.Slice(out, func(i, j int) bool { return out[i].UpdatedAt.After(out[j].UpdatedAt) })
	return out, nil
}

// RolloutForPID finds the rollout a running codex process writes to: first by
// its open file descriptors, then by cwd plus start time.
func RolloutForPID(profile Profile, pid int, cwd string, started time.Time) string {
	for _, f := range tmux.OpenFiles(pid) {
		if strings.Contains(f, string(filepath.Separator)+"sessions"+string(filepath.Separator)) && strings.HasSuffix(f, ".jsonl") && strings.Contains(filepath.Base(f), "rollout-") {
			return f
		}
	}
	infos, err := ListRollouts(profile, 1)
	if err != nil {
		return ""
	}
	for _, in := range infos {
		if started.IsZero() || in.UpdatedAt.Before(started.Add(-5*time.Second)) {
			continue
		}
		s, err := Summarize(in.Path)
		if err != nil {
			continue
		}
		if cwd == "" || s.Cwd == cwd {
			if !started.IsZero() && s.StartedAt.Before(started.Add(-10*time.Second)) {
				continue
			}
			return in.Path
		}
	}
	return ""
}

// Builtin slash commands in the Codex TUI.
var Builtin = []string{"new", "resume", "fork", "model", "approvals", "permissions", "review", "compact", "diff", "mention", "status", "mcp", "init", "quit", "logout", "clear", "personality", "experimental"}

// Skills lists Codex skills for a profile and repo.
func Skills(profileDir, repo string) []provider.Skill {
	var out []provider.Skill
	out = append(out, provider.SkillDirs(filepath.Join(profileDir, "skills"), "user", "codex")...)
	h, _ := os.UserHomeDir()
	out = append(out, provider.SkillDirs(filepath.Join(h, ".agents", "skills"), "user", "codex")...)
	if repo != "" {
		out = append(out, provider.SkillDirs(filepath.Join(repo, ".agents", "skills"), "project", "codex")...)
		out = append(out, provider.SkillDirs(filepath.Join(repo, ".codex", "skills"), "project", "codex")...)
	}
	for _, p := range provider.CommandFiles(filepath.Join(profileDir, "prompts"), "user", "codex") {
		p.Name = "prompts:" + p.Name
		out = append(out, p)
	}
	for _, b := range Builtin {
		out = append(out, provider.Skill{Name: b, Source: "builtin", Provider: "codex"})
	}
	return provider.Dedupe(out)
}

// AccountEmail reads the login identity from auth.json without touching tokens.
func AccountEmail(profileDir string) string {
	b, err := os.ReadFile(filepath.Join(profileDir, "auth.json"))
	if err != nil {
		return ""
	}
	var a struct {
		Tokens *struct {
			IDToken string `json:"id_token"`
		} `json:"tokens"`
	}
	if json.Unmarshal(b, &a) != nil || a.Tokens == nil || a.Tokens.IDToken == "" {
		return ""
	}
	// id_token is a JWT; the email claim is in the payload. We never keep the token.
	parts := strings.Split(a.Tokens.IDToken, ".")
	if len(parts) < 2 {
		return ""
	}
	payload, err := decodeB64URL(parts[1])
	if err != nil {
		return ""
	}
	var claims struct {
		Email string `json:"email"`
	}
	if json.Unmarshal(payload, &claims) != nil {
		return ""
	}
	return claims.Email
}
