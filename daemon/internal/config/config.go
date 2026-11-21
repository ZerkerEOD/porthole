// Package config loads the daemon configuration and resolves the well-known
// directories (config, state, runtime).
package config

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/BurntSushi/toml"
)

// Config is the daemon configuration (~/.config/porthole/config.toml).
type Config struct {
	// Name is shown in the app as the machine name. Defaults to the hostname.
	Name string `toml:"name"`
	// Listen is "auto" (every loopback, private, CGNAT and VPN address) or an
	// explicit list of IP addresses. Public addresses are refused unless the
	// serve command is given --allow-public-bind-i-understand.
	Listen []string `toml:"listen"`
	Port   int      `toml:"port"`
	// Workspaces are parent directories scanned for git repositories.
	Workspaces []string `toml:"workspaces"`
	// Repos are individual repositories offered in the app without scanning.
	// `porthole add` records them in repos.toml; this key lets config.toml
	// list them too.
	Repos []string `toml:"repos"`
	// Profiles are extra CLAUDE_CONFIG_DIR / CODEX_HOME directories to watch
	// even when no process is using them.
	Profiles []string `toml:"profiles"`

	Claude ProviderConfig `toml:"claude"`
	Codex  ProviderConfig `toml:"codex"`
	Tmux   TmuxConfig     `toml:"tmux"`
	Hooks  HooksConfig    `toml:"hooks"`
	Push   PushConfig     `toml:"push"`
	Cswap  CswapConfig    `toml:"cswap"`

	// Path is the config.toml the values came from (set by Load).
	Path string `toml:"-"`
}

// ProviderConfig toggles one CLI integration.
type ProviderConfig struct {
	Enabled *bool  `toml:"enabled"`
	Binary  string `toml:"binary"`
}

// On reports whether the provider is enabled (default true).
func (p ProviderConfig) On() bool { return p.Enabled == nil || *p.Enabled }

// TmuxConfig controls how spawned sessions are named.
type TmuxConfig struct {
	Binary        string `toml:"binary"`
	SessionPrefix string `toml:"session_prefix"`
}

// HooksConfig controls the permission broker.
type HooksConfig struct {
	// PermissionTimeoutS is how long a PermissionRequest hook waits for a phone
	// before falling back to the terminal prompt.
	PermissionTimeoutS int `toml:"permission_timeout_s"`
}

// PushConfig is the opt-in relay. Empty RelayURL means push is off.
type PushConfig struct {
	RelayURL string `toml:"relay_url"`
}

// CswapConfig controls the optional claude-swap integration.
type CswapConfig struct {
	Enabled       *bool  `toml:"enabled"`
	Binary        string `toml:"binary"`
	PollIntervalS int    `toml:"poll_interval_s"`
}

// On reports whether cswap integration is enabled (default true, auto-detected).
func (c CswapConfig) On() bool { return c.Enabled == nil || *c.Enabled }

// Default returns the built-in defaults.
func Default() *Config {
	host, _ := os.Hostname()
	if host == "" {
		host = "porthole"
	}
	return &Config{
		Name:       host,
		Listen:     []string{"auto"},
		Port:       7433,
		Workspaces: []string{},
		Repos:      []string{},
		Tmux:       TmuxConfig{Binary: "tmux", SessionPrefix: "ph"},
		Hooks:      HooksConfig{PermissionTimeoutS: 60},
		Cswap:      CswapConfig{Binary: "cswap", PollIntervalS: 150},
		Claude:     ProviderConfig{Binary: "claude"},
		Codex:      ProviderConfig{Binary: "codex"},
	}
}

// Load reads path (or the default location when empty) over the defaults,
// then merges the CLI-managed repos.toml next to it. A missing file is not
// an error.
func Load(path string) (*Config, error) {
	cfg := Default()
	if path == "" {
		path = filepath.Join(ConfigDir(), "config.toml")
	}
	cfg.Path = path
	b, err := os.ReadFile(path)
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		return nil, err
	}
	if err == nil {
		if _, err := toml.Decode(string(b), cfg); err != nil {
			return nil, fmt.Errorf("parse %s: %w", path, err)
		}
	}
	if cfg.Port <= 0 || cfg.Port > 65535 {
		return nil, fmt.Errorf("port %d out of range", cfg.Port)
	}
	m, err := LoadManaged(ManagedPath(path))
	if err != nil {
		return nil, err
	}
	cfg.Workspaces = expandAll(cfg.Workspaces, m.Workspaces)
	cfg.Repos = expandAll(cfg.Repos, m.Repos)
	cfg.Profiles = expandAll(cfg.Profiles)
	return cfg, nil
}

// expandAll expands and de-duplicates the lists in order.
func expandAll(lists ...[]string) []string {
	out := []string{}
	seen := map[string]bool{}
	for _, l := range lists {
		for _, p := range l {
			if strings.TrimSpace(p) == "" {
				continue
			}
			e := Expand(p)
			if !seen[e] {
				seen[e] = true
				out = append(out, e)
			}
		}
	}
	return out
}

// Managed is repos.toml: the lists `porthole add` and `porthole remove`
// maintain, kept apart from config.toml so a hand-written file is never
// rewritten.
type Managed struct {
	Repos      []string `toml:"repos"`
	Workspaces []string `toml:"workspaces"`
}

// ManagedPath is repos.toml next to the given config.toml.
func ManagedPath(configPath string) string {
	if configPath == "" {
		configPath = filepath.Join(ConfigDir(), "config.toml")
	}
	return filepath.Join(filepath.Dir(configPath), "repos.toml")
}

// LoadManaged reads repos.toml; a missing file yields empty lists.
func LoadManaged(path string) (Managed, error) {
	var m Managed
	b, err := os.ReadFile(path)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return m, nil
		}
		return m, err
	}
	if _, err := toml.Decode(string(b), &m); err != nil {
		return m, fmt.Errorf("parse %s: %w", path, err)
	}
	return m, nil
}

const managedHeader = "# Written by `porthole add` and `porthole remove`. Edit config.toml for everything else.\n"

// SaveManaged writes repos.toml atomically with mode 0600.
func SaveManaged(path string, m Managed) error {
	if m.Repos == nil {
		m.Repos = []string{}
	}
	if m.Workspaces == nil {
		m.Workspaces = []string{}
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	var buf strings.Builder
	buf.WriteString(managedHeader)
	if err := toml.NewEncoder(&buf).Encode(m); err != nil {
		return err
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, []byte(buf.String()), 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

// AddManaged records dir as a repository (or a workspace) in repos.toml.
// It reports false when the entry was already present.
func AddManaged(path, dir string, workspace bool) (bool, error) {
	m, err := LoadManaged(path)
	if err != nil {
		return false, err
	}
	list := &m.Repos
	if workspace {
		list = &m.Workspaces
	}
	for _, p := range *list {
		if Expand(p) == dir {
			return false, nil
		}
	}
	*list = append(*list, dir)
	return true, SaveManaged(path, m)
}

// RemoveManaged drops dir from both lists in repos.toml. It reports false
// when nothing matched.
func RemoveManaged(path, dir string) (bool, error) {
	m, err := LoadManaged(path)
	if err != nil {
		return false, err
	}
	removed := false
	filter := func(l []string) []string {
		out := l[:0:0]
		for _, p := range l {
			if Expand(p) == dir {
				removed = true
				continue
			}
			out = append(out, p)
		}
		return out
	}
	m.Repos, m.Workspaces = filter(m.Repos), filter(m.Workspaces)
	if !removed {
		return false, nil
	}
	return true, SaveManaged(path, m)
}

// Expand resolves a leading ~ and environment variables.
func Expand(p string) string {
	p = os.ExpandEnv(p)
	if strings.HasPrefix(p, "~/") || p == "~" {
		if h, err := os.UserHomeDir(); err == nil {
			p = filepath.Join(h, strings.TrimPrefix(p, "~"))
		}
	}
	return filepath.Clean(p)
}

func xdg(env, fallback string) string {
	if v := os.Getenv(env); v != "" {
		return filepath.Join(v, "porthole")
	}
	h, _ := os.UserHomeDir()
	return filepath.Join(h, fallback, "porthole")
}

// ConfigDir is where config.toml lives.
func ConfigDir() string { return xdg("XDG_CONFIG_HOME", ".config") }

// StateDir holds the TLS key, device store and cursors (0700).
func StateDir() string { return xdg("XDG_STATE_HOME", filepath.Join(".local", "state")) }

// RuntimeDir holds the control socket (0700). Falls back to StateDir/run when
// XDG_RUNTIME_DIR is unset (macOS).
func RuntimeDir() string {
	var dir string
	if v := os.Getenv("XDG_RUNTIME_DIR"); v != "" {
		dir = filepath.Join(v, "porthole")
	} else {
		dir = filepath.Join(StateDir(), "run")
	}
	// Unix socket paths are limited to ~104 bytes; fall back to the temp dir.
	if len(filepath.Join(dir, "porthole.sock")) > 100 {
		dir = filepath.Join(os.TempDir(), fmt.Sprintf("porthole-%d", os.Getuid()))
	}
	return dir
}

// SocketPath is the local control/hook socket.
func SocketPath() string { return filepath.Join(RuntimeDir(), "porthole.sock") }

// EnsureDirs creates the state and runtime dirs with 0700.
func EnsureDirs() error {
	for _, d := range []string{ConfigDir(), StateDir(), RuntimeDir()} {
		if err := os.MkdirAll(d, 0o700); err != nil {
			return err
		}
		if err := os.Chmod(d, 0o700); err != nil {
			return err
		}
	}
	return nil
}
