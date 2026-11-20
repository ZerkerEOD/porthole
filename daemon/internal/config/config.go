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
	// Profiles are extra CLAUDE_CONFIG_DIR / CODEX_HOME directories to watch
	// even when no process is using them.
	Profiles []string `toml:"profiles"`

	Claude ProviderConfig `toml:"claude"`
	Codex  ProviderConfig `toml:"codex"`
	Tmux   TmuxConfig     `toml:"tmux"`
	Hooks  HooksConfig    `toml:"hooks"`
	Push   PushConfig     `toml:"push"`
	Cswap  CswapConfig    `toml:"cswap"`
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
		Tmux:       TmuxConfig{Binary: "tmux", SessionPrefix: "ph"},
		Hooks:      HooksConfig{PermissionTimeoutS: 60},
		Cswap:      CswapConfig{Binary: "cswap", PollIntervalS: 150},
		Claude:     ProviderConfig{Binary: "claude"},
		Codex:      ProviderConfig{Binary: "codex"},
	}
}

// Load reads path (or the default location when empty) over the defaults.
// A missing file is not an error.
func Load(path string) (*Config, error) {
	cfg := Default()
	if path == "" {
		path = filepath.Join(ConfigDir(), "config.toml")
	}
	b, err := os.ReadFile(path)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return cfg, nil
		}
		return nil, err
	}
	if _, err := toml.Decode(string(b), cfg); err != nil {
		return nil, fmt.Errorf("parse %s: %w", path, err)
	}
	if cfg.Port <= 0 || cfg.Port > 65535 {
		return nil, fmt.Errorf("port %d out of range", cfg.Port)
	}
	for i, w := range cfg.Workspaces {
		cfg.Workspaces[i] = Expand(w)
	}
	for i, p := range cfg.Profiles {
		cfg.Profiles[i] = Expand(p)
	}
	return cfg, nil
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
