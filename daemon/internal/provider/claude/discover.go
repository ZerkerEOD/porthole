package claude

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"time"

	"github.com/ZerkerEOD/porthole/daemon/internal/provider"
	"github.com/ZerkerEOD/porthole/daemon/internal/tmux"
)

// Profile is one CLAUDE_CONFIG_DIR.
type Profile struct {
	Dir      string // as configured / seen in env
	Projects string // real path of <dir>/projects
}

// DefaultProfileDir is ~/.claude unless CLAUDE_CONFIG_DIR is set for the daemon.
func DefaultProfileDir() string {
	if v := os.Getenv("CLAUDE_CONFIG_DIR"); v != "" {
		return v
	}
	h, _ := os.UserHomeDir()
	return filepath.Join(h, ".claude")
}

// Profiles unions the default dir, dirs from running claude processes, and
// extras, deduped by the real path of their projects directory.
func Profiles(extra []string, procs map[int]tmux.Process) []Profile {
	cands := []string{DefaultProfileDir()}
	cands = append(cands, extra...)
	for pid, p := range procs {
		if p.Name != "claude" && !strings.Contains(p.Args, "/claude ") && !strings.HasSuffix(p.Args, "/claude") {
			continue
		}
		if v := tmux.Environ(pid)["CLAUDE_CONFIG_DIR"]; v != "" {
			cands = append(cands, v)
		}
	}
	seen := map[string]bool{}
	var out []Profile
	for _, d := range cands {
		proj := filepath.Join(d, "projects")
		real, err := filepath.EvalSymlinks(proj)
		if err != nil {
			continue
		}
		if seen[real] {
			continue
		}
		seen[real] = true
		out = append(out, Profile{Dir: d, Projects: real})
	}
	return out
}

// Agent is one row of `claude agents --json`.
type Agent struct {
	PID       int    `json:"pid"`
	Cwd       string `json:"cwd"`
	Kind      string `json:"kind"` // interactive|background
	StartedAt int64  `json:"startedAt"`
	SessionID string `json:"sessionId"`
	Name      string `json:"name"`
	Status    string `json:"status"` // busy|idle|...
}

// Agents asks Claude Code for its running sessions under a profile.
func Agents(ctx context.Context, binary, profileDir string) ([]Agent, error) {
	if binary == "" {
		binary = "claude"
	}
	ctx, cancel := context.WithTimeout(ctx, 8*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, binary, "agents", "--json")
	cmd.Env = append(os.Environ(), "CLAUDE_CONFIG_DIR="+profileDir)
	out, err := cmd.Output()
	if err != nil {
		return nil, err
	}
	var agents []Agent
	if err := json.Unmarshal(out, &agents); err != nil {
		return nil, err
	}
	return agents, nil
}

var nonAlnum = regexp.MustCompile(`[^A-Za-z0-9]`)

// EscapeCwd mirrors how Claude Code names a project directory.
func EscapeCwd(cwd string) string { return nonAlnum.ReplaceAllString(cwd, "-") }

// TranscriptPath finds the transcript for a session id under a profile.
func TranscriptPath(profile Profile, cwd, sessionID string) string {
	if cwd != "" {
		p := filepath.Join(profile.Projects, EscapeCwd(cwd), sessionID+".jsonl")
		if _, err := os.Stat(p); err == nil {
			return p
		}
	}
	matches, _ := filepath.Glob(filepath.Join(profile.Projects, "*", sessionID+".jsonl"))
	if len(matches) > 0 {
		return matches[0]
	}
	return ""
}

// Info summarizes a transcript for the session list without parsing all of it.
type Info struct {
	SessionID   string    `json:"session_id"`
	Path        string    `json:"path"`
	Cwd         string    `json:"cwd"`
	GitBranch   string    `json:"git_branch,omitempty"`
	Version     string    `json:"version,omitempty"`
	Title       string    `json:"title,omitempty"`
	FirstPrompt string    `json:"first_prompt,omitempty"`
	LastPrompt  string    `json:"last_prompt,omitempty"`
	Model       string    `json:"model,omitempty"`
	StartedAt   time.Time `json:"started_at"`
	UpdatedAt   time.Time `json:"updated_at"`
	Size        int64     `json:"size"`
	Sidechain   bool      `json:"sidechain,omitempty"` // whole file is a subagent transcript
}

const headBytes = 128 * 1024
const tailBytes = 128 * 1024

// Summarize reads the head and tail of a transcript to fill Info.
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
	info := &Info{Path: path, Size: st.Size(), UpdatedAt: st.ModTime()}
	info.SessionID = strings.TrimSuffix(filepath.Base(path), ".jsonl")

	scan := func(r io.Reader, fn func(e entry)) {
		sc := bufio.NewScanner(r)
		sc.Buffer(make([]byte, 1<<20), 1<<20)
		for sc.Scan() {
			var e entry
			if json.Unmarshal(sc.Bytes(), &e) == nil {
				fn(e)
			}
		}
	}
	head := io.LimitReader(f, headBytes)
	scan(head, func(e entry) {
		if info.Cwd == "" && e.Cwd != "" {
			info.Cwd, info.GitBranch, info.Version = e.Cwd, e.GitBranch, e.Version
			if e.SessionID != "" {
				info.SessionID = e.SessionID
			}
		}
		if info.StartedAt.IsZero() && e.Timestamp != "" {
			info.StartedAt = parseTime(e.Timestamp)
		}
		if info.FirstPrompt == "" && e.Type == "user" && !e.IsMeta {
			var m message
			if json.Unmarshal(e.Message, &m) == nil {
				var s string
				if json.Unmarshal(m.Content, &s) != nil {
					s = contentText(m.Content)
				}
				if s != "" && !isSystemInjected(s) {
					info.FirstPrompt = firstLine(s, 120)
					info.Sidechain = e.Sidechain
				}
			}
		}
		applyMeta(info, e)
	})
	if st.Size() > headBytes {
		start := st.Size() - tailBytes
		if start < headBytes {
			start = headBytes
		}
		if _, err := f.Seek(start, io.SeekStart); err == nil {
			r := bufio.NewReader(f)
			_, _ = r.ReadBytes('\n') // skip partial
			scan(r, func(e entry) { applyMeta(info, e) })
		}
	}
	if info.Title == "" {
		info.Title = info.FirstPrompt
	}
	return info, nil
}

func applyMeta(info *Info, e entry) {
	switch e.Type {
	case "ai-title":
		if e.AITitle != "" {
			info.Title = e.AITitle
		}
	case "summary":
		if e.Summary != "" && info.Title == "" {
			info.Title = e.Summary
		}
	case "last-prompt":
		info.LastPrompt = firstLine(e.LastPrompt, 120)
	case "assistant":
		var m message
		if json.Unmarshal(e.Message, &m) == nil && m.Model != "" {
			info.Model = m.Model
		}
		if t := parseTime(e.Timestamp); !t.IsZero() {
			info.UpdatedAt = t
		}
	case "user":
		if t := parseTime(e.Timestamp); !t.IsZero() {
			info.UpdatedAt = t
		}
	}
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

// ListTranscripts returns every transcript under a profile, newest first,
// skipping files smaller than minSize (empty sessions).
func ListTranscripts(profile Profile, minSize int64) ([]Info, error) {
	dirs, err := os.ReadDir(profile.Projects)
	if err != nil {
		return nil, err
	}
	var out []Info
	for _, d := range dirs {
		if !d.IsDir() {
			continue
		}
		files, err := os.ReadDir(filepath.Join(profile.Projects, d.Name()))
		if err != nil {
			continue
		}
		for _, f := range files {
			if f.IsDir() || !strings.HasSuffix(f.Name(), ".jsonl") {
				continue
			}
			st, err := f.Info()
			if err != nil || st.Size() < minSize {
				continue
			}
			out = append(out, Info{Path: filepath.Join(profile.Projects, d.Name(), f.Name()), SessionID: strings.TrimSuffix(f.Name(), ".jsonl"), Size: st.Size(), UpdatedAt: st.ModTime()})
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].UpdatedAt.After(out[j].UpdatedAt) })
	return out, nil
}

// Builtin slash commands always available in the Claude Code TUI.
var Builtin = []string{"clear", "compact", "config", "cost", "doctor", "help", "init", "mcp", "memory", "model", "permissions", "plan", "resume", "review", "status", "fast", "effort", "rename", "usage"}

// Skills lists user, project, plugin and builtin slash commands for a profile.
func Skills(profileDir, repo string) []provider.Skill {
	var out []provider.Skill
	out = append(out, provider.SkillDirs(filepath.Join(profileDir, "skills"), "user", "claude")...)
	out = append(out, provider.CommandFiles(filepath.Join(profileDir, "commands"), "user", "claude")...)
	if repo != "" {
		out = append(out, provider.SkillDirs(filepath.Join(repo, ".claude", "skills"), "project", "claude")...)
		out = append(out, provider.CommandFiles(filepath.Join(repo, ".claude", "commands"), "project", "claude")...)
	}
	out = append(out, pluginSkills(profileDir)...)
	for _, b := range Builtin {
		out = append(out, provider.Skill{Name: b, Source: "builtin", Provider: "claude"})
	}
	return provider.Dedupe(out)
}

// pluginSkills reads enabled plugins from settings.json and their cached skills.
// Plugin skills are invoked as /<plugin>:<skill>.
func pluginSkills(profileDir string) []provider.Skill {
	b, err := os.ReadFile(filepath.Join(profileDir, "settings.json"))
	if err != nil {
		return nil
	}
	var settings struct {
		EnabledPlugins map[string]bool `json:"enabledPlugins"`
	}
	if json.Unmarshal(b, &settings) != nil {
		return nil
	}
	var out []provider.Skill
	for key, on := range settings.EnabledPlugins {
		if !on {
			continue
		}
		name, market, ok := strings.Cut(key, "@")
		if !ok {
			continue
		}
		vers, _ := filepath.Glob(filepath.Join(profileDir, "plugins", "cache", market, name, "*"))
		for _, v := range vers {
			for _, s := range provider.SkillDirs(filepath.Join(v, "skills"), "plugin", "claude") {
				s.Name = name + ":" + s.Name
				out = append(out, s)
			}
		}
	}
	return out
}

// ErrNotFound is returned when a session has no transcript yet.
var ErrNotFound = errors.New("claude: transcript not found")
