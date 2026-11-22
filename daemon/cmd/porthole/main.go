// Command porthole is the daemon and its CLI.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
	"text/tabwriter"
	"time"

	qrcode "github.com/skip2/go-qrcode"
	"github.com/spf13/cobra"

	"github.com/ZerkerEOD/porthole/daemon/internal/config"
	"github.com/ZerkerEOD/porthole/daemon/internal/core"
	"github.com/ZerkerEOD/porthole/daemon/internal/hooks"
	"github.com/ZerkerEOD/porthole/daemon/internal/provider/claude"
	"github.com/ZerkerEOD/porthole/daemon/internal/provider/codex"
	"github.com/ZerkerEOD/porthole/daemon/internal/server"
	"github.com/ZerkerEOD/porthole/daemon/internal/version"
)

var (
	flagConfig   string
	flagLogLevel string
)

func main() {
	root := &cobra.Command{
		Use:           "porthole",
		Short:         "Porthole: a self-hosted remote for Claude Code and Codex sessions",
		SilenceUsage:  true,
		SilenceErrors: true,
		Version:       version.Version,
	}
	root.PersistentFlags().StringVar(&flagConfig, "config", "", "config file (default ~/.config/porthole/config.toml)")
	root.PersistentFlags().StringVar(&flagLogLevel, "log-level", "info", "debug|info|warn|error")
	root.AddCommand(serveCmd(), pairCmd(), devicesCmd(), sessionsCmd(), statusCmd(), installHooksCmd(), uninstallHooksCmd(), hookCmd(), codexNotifyCmd(), wrapCmd(), doctorCmd(), configCmd(), clientCmd(), addCmd(), removeCmd(), reposCmd(), installCmd())
	if err := root.Execute(); err != nil {
		fmt.Fprintln(os.Stderr, "error:", err)
		os.Exit(1)
	}
}

func logger() *slog.Logger {
	var lvl slog.Level
	switch flagLogLevel {
	case "debug":
		lvl = slog.LevelDebug
	case "warn":
		lvl = slog.LevelWarn
	case "error":
		lvl = slog.LevelError
	default:
		lvl = slog.LevelInfo
	}
	return slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: lvl}))
}

func serveCmd() *cobra.Command {
	var allowPublic bool
	c := &cobra.Command{
		Use:   "serve",
		Short: "Run the daemon",
		RunE: func(cmd *cobra.Command, args []string) error {
			if os.Geteuid() == 0 {
				return errors.New("refusing to run as root; run porthole as the user who owns the sessions")
			}
			cfg, err := config.Load(flagConfig)
			if err != nil {
				return err
			}
			if err := config.EnsureDirs(); err != nil {
				return err
			}
			log := logger()
			if allowPublic {
				log.Warn("PUBLIC BIND ENABLED: the daemon will accept connections from any address. This is not the intended deployment.")
			}
			store, err := server.OpenStore(config.StateDir())
			if err != nil {
				return err
			}
			ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
			defer stop()
			reg := core.New(cfg, log)
			srv := server.New(cfg, reg, store, log, allowPublic)
			local := server.NewLocal(cfg, reg, store, srv, log)
			errc := make(chan error, 3)
			go func() { errc <- local.Run(ctx) }()
			go func() { errc <- srv.Run(ctx) }()
			go func() { reg.Run(ctx); errc <- nil }()
			hup := make(chan os.Signal, 1)
			signal.Notify(hup, syscall.SIGHUP)
			defer signal.Stop(hup)
			go func() {
				for range hup {
					if _, _, err := reg.Reload(); err != nil {
						log.Warn("config reload failed", "err", err)
					}
				}
			}()
			log.Info("porthole", "version", version.Version, "name", cfg.Name, "port", cfg.Port, "workspaces", cfg.Workspaces, "repos", cfg.Repos)
			if len(cfg.Workspaces) == 0 && len(cfg.Repos) == 0 {
				log.Warn("no repositories configured: run `porthole add` inside a repository (directories with past agent sessions still appear in the app)")
			}
			select {
			case <-ctx.Done():
			case err := <-errc:
				if err != nil {
					stop()
					return err
				}
			}
			stop()
			time.Sleep(200 * time.Millisecond)
			return nil
		},
	}
	c.Flags().BoolVar(&allowPublic, "allow-public-bind-i-understand", false, "bind and accept on public addresses (NOT recommended; use a VPN)")
	return c
}

func pairCmd() *cobra.Command {
	var label string
	var asJSON bool
	c := &cobra.Command{
		Use:   "pair",
		Short: "Show a one-time pairing QR code for the app",
		RunE: func(cmd *cobra.Command, args []string) error {
			var info server.PairInfo
			if err := server.NewLocalClient().Call(cmd.Context(), "POST", "/pair/new", map[string]string{"label": label}, &info, 5*time.Second); err != nil {
				return err
			}
			b, _ := json.Marshal(info)
			if asJSON {
				fmt.Println(string(b))
				return nil
			}
			qr, err := qrcode.New("porthole://pair?d="+encodeB64(b), qrcode.Medium)
			if err != nil {
				return err
			}
			fmt.Println(qr.ToSmallString(false))
			fmt.Printf("Scan with the Porthole app within %s.\n", time.Until(info.ExpiresAt).Round(time.Second))
			fmt.Printf("Manual entry: host %s  port %d  code %s\n", strings.Join(info.Hosts, " or "), info.Port, info.Code)
			fmt.Printf("Certificate fingerprint: %s\n", info.Fingerprint)
			if len(info.Hosts) == 0 {
				fmt.Println("warning: no VPN or private address is bound; is your VPN up?")
			}
			return nil
		},
	}
	c.Flags().StringVar(&label, "label", "", "optional label for this pairing")
	c.Flags().BoolVar(&asJSON, "json", false, "print the pairing payload as JSON")
	return c
}

func encodeB64(b []byte) string {
	const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
	var out strings.Builder
	for i := 0; i < len(b); i += 3 {
		var n uint32
		rem := len(b) - i
		for j := 0; j < 3; j++ {
			n <<= 8
			if j < rem {
				n |= uint32(b[i+j])
			}
		}
		chars := 4
		if rem < 3 {
			chars = rem + 1
		}
		for j := 0; j < chars; j++ {
			out.WriteByte(alphabet[(n>>(18-6*j))&63])
		}
	}
	return out.String()
}

func devicesCmd() *cobra.Command {
	c := &cobra.Command{Use: "devices", Short: "List paired devices"}
	c.RunE = func(cmd *cobra.Command, args []string) error {
		var devs []server.Device
		if err := server.NewLocalClient().Call(cmd.Context(), "GET", "/devices", nil, &devs, 5*time.Second); err != nil {
			return err
		}
		tw := tabwriter.NewWriter(os.Stdout, 0, 4, 2, ' ', 0)
		fmt.Fprintln(tw, "ID\tNAME\tPAIRED\tLAST SEEN")
		for _, d := range devs {
			ls := "never"
			if !d.LastSeen.IsZero() {
				ls = d.LastSeen.Local().Format("2006-01-02 15:04")
			}
			fmt.Fprintf(tw, "%s\t%s\t%s\t%s\n", d.ID, d.Name, d.CreatedAt.Local().Format("2006-01-02"), ls)
		}
		return tw.Flush()
	}
	c.AddCommand(&cobra.Command{
		Use:   "revoke <id>",
		Short: "Revoke a device; its connections close immediately",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			if err := server.NewLocalClient().Call(cmd.Context(), "POST", "/devices/revoke", map[string]string{"id": args[0]}, nil, 5*time.Second); err != nil {
				return err
			}
			fmt.Println("revoked", args[0])
			return nil
		},
	})
	return c
}

func sessionsCmd() *cobra.Command {
	var asJSON bool
	c := &cobra.Command{
		Use:   "sessions",
		Short: "List sessions the daemon knows about",
		RunE: func(cmd *cobra.Command, args []string) error {
			var ss []core.Session
			if err := server.NewLocalClient().Call(cmd.Context(), "GET", "/sessions", nil, &ss, 10*time.Second); err != nil {
				return err
			}
			if asJSON {
				return json.NewEncoder(os.Stdout).Encode(ss)
			}
			tw := tabwriter.NewWriter(os.Stdout, 0, 4, 2, ' ', 0)
			fmt.Fprintln(tw, "PROVIDER\tSTATUS\tCTRL\tREPO\tTITLE\tUPDATED\tID")
			for _, s := range ss {
				ctrl := ""
				if s.Controllable {
					ctrl = s.TmuxSession
				}
				fmt.Fprintf(tw, "%s\t%s\t%s\t%s\t%s\t%s\t%s\n", s.Provider, s.Status, ctrl, s.Repo, trunc(s.Title, 40), s.UpdatedAt.Local().Format("01-02 15:04"), s.ID)
			}
			return tw.Flush()
		},
	}
	c.Flags().BoolVar(&asJSON, "json", false, "JSON output")
	return c
}

func trunc(s string, n int) string {
	r := []rune(s)
	if len(r) > n {
		return string(r[:n-1]) + "…"
	}
	return s
}

func statusCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "status",
		Short: "Show daemon status",
		RunE: func(cmd *cobra.Command, args []string) error {
			var st server.Status
			if err := server.NewLocalClient().Call(cmd.Context(), "GET", "/status", nil, &st, 5*time.Second); err != nil {
				return err
			}
			fmt.Printf("porthole %s (%s) pid %d up %s\n", st.Version, st.Name, st.PID, st.Uptime)
			fmt.Printf("sessions: %d (%d running)  devices: %d  tmux: %v  cswap: %v\n", st.Sessions, st.Running, st.Devices, st.Tmux, st.Cswap)
			fmt.Println("listening on:")
			printListeners(st.Listeners)
			fmt.Println("recent connections (newest first):")
			printConnections(st.RecentConnections, 10)
			return nil
		},
	}
}

func printListeners(ls []server.Listener) {
	if len(ls) == 0 {
		fmt.Println("  (none)")
		return
	}
	tw := tabwriter.NewWriter(os.Stdout, 2, 8, 2, ' ', 0)
	fmt.Fprintln(tw, "  ADDRESS\tINTERFACE\tKIND")
	for _, l := range ls {
		iface := l.Iface
		if iface == "" {
			iface = "-"
		}
		fmt.Fprintf(tw, "  %s\t%s\t%s\n", l.Addr, iface, l.Kind)
	}
	tw.Flush()
}

func printConnections(cs []server.ConnAttempt, max int) {
	if len(cs) == 0 {
		fmt.Println("  (none since start)")
		return
	}
	if len(cs) > max {
		cs = cs[:max]
	}
	tw := tabwriter.NewWriter(os.Stdout, 2, 8, 2, ' ', 0)
	fmt.Fprintln(tw, "  TIME\tFROM\tPATH\tRESULT\tDEVICE")
	for _, c := range cs {
		dev := firstNonEmpty(c.Name, c.Device, "-")
		fmt.Fprintf(tw, "  %s\t%s\t%s\t%s\t%s\n", c.At.Local().Format("15:04:05"), c.From, c.Path, c.Result, dev)
	}
	tw.Flush()
}

func binaryPath() string {
	p, err := os.Executable()
	if err != nil {
		return "porthole"
	}
	if r, err := filepath.EvalSymlinks(p); err == nil {
		return r
	}
	return p
}

func installHooksCmd() *cobra.Command {
	var profile, codexHome string
	var skipClaude, skipCodex bool
	c := &cobra.Command{
		Use:   "install-hooks",
		Short: "Add Porthole hooks to Claude Code settings and Codex notify",
		RunE: func(cmd *cobra.Command, args []string) error {
			cfg, err := config.Load(flagConfig)
			if err != nil {
				return err
			}
			bin := binaryPath()
			if !skipClaude {
				if profile == "" {
					profile = claude.DefaultProfileDir()
				}
				ch, err := hooks.InstallClaude(profile, bin, cfg.Hooks.PermissionTimeoutS)
				if err != nil {
					return err
				}
				if ch {
					fmt.Printf("claude: hooks installed in %s\n", filepath.Join(profile, "settings.json"))
				} else {
					fmt.Println("claude: hooks already installed")
				}
			}
			if !skipCodex {
				if codexHome == "" {
					codexHome = codex.DefaultProfileDir()
				}
				ch, err := hooks.InstallCodex(codexHome, bin)
				if err != nil {
					fmt.Fprintln(os.Stderr, "codex:", err)
				} else if ch {
					fmt.Printf("codex: notify set in %s\n", filepath.Join(codexHome, "config.toml"))
				} else {
					fmt.Println("codex: notify already set")
				}
			}
			fmt.Println("Hooks take effect for new sessions. Running sessions keep their old hook set.")
			return nil
		},
	}
	c.Flags().StringVar(&profile, "profile", "", "CLAUDE_CONFIG_DIR to install into (default ~/.claude)")
	c.Flags().StringVar(&codexHome, "codex-home", "", "CODEX_HOME to install into (default ~/.codex)")
	c.Flags().BoolVar(&skipClaude, "no-claude", false, "skip Claude Code")
	c.Flags().BoolVar(&skipCodex, "no-codex", false, "skip Codex")
	return c
}

func uninstallHooksCmd() *cobra.Command {
	var profile string
	c := &cobra.Command{
		Use:   "uninstall-hooks",
		Short: "Remove Porthole hooks from Claude Code settings",
		RunE: func(cmd *cobra.Command, args []string) error {
			if profile == "" {
				profile = claude.DefaultProfileDir()
			}
			ch, err := hooks.UninstallClaude(profile)
			if err != nil {
				return err
			}
			if ch {
				fmt.Println("claude: hooks removed")
			} else {
				fmt.Println("claude: nothing to remove")
			}
			fmt.Println("codex: remove the `notify = [...]` line from config.toml by hand if present")
			return nil
		},
	}
	c.Flags().StringVar(&profile, "profile", "", "CLAUDE_CONFIG_DIR (default ~/.claude)")
	return c
}

// hookCmd is what Claude Code runs. It forwards stdin to the daemon and
// prints the daemon's JSON (possibly a permission decision). It never fails
// loudly: if the daemon is down it prints {} and exits 0 so the CLI proceeds.
func hookCmd() *cobra.Command {
	return &cobra.Command{
		Use:    "hook",
		Hidden: true,
		RunE: func(cmd *cobra.Command, args []string) error {
			in, err := io.ReadAll(io.LimitReader(os.Stdin, 1<<20))
			if err != nil || len(in) == 0 {
				fmt.Println("{}")
				return nil
			}
			var raw json.RawMessage = in
			var out json.RawMessage
			cfg, _ := config.Load(flagConfig)
			timeout := 30 * time.Second
			if cfg != nil && strings.Contains(string(in), `"PermissionRequest"`) {
				timeout = time.Duration(cfg.Hooks.PermissionTimeoutS+5) * time.Second
			}
			if err := server.NewLocalClient().Call(cmd.Context(), "POST", "/hook", raw, &out, timeout); err != nil {
				fmt.Println("{}")
				return nil
			}
			fmt.Println(string(out))
			return nil
		},
	}
}

// codexNotifyCmd is what Codex runs: `porthole codex-notify '<json>'`.
func codexNotifyCmd() *cobra.Command {
	return &cobra.Command{
		Use:    "codex-notify [json]",
		Hidden: true,
		RunE: func(cmd *cobra.Command, args []string) error {
			if len(args) == 0 {
				return nil
			}
			var raw json.RawMessage = []byte(args[0])
			if !json.Valid(raw) {
				return nil
			}
			_ = server.NewLocalClient().Call(cmd.Context(), "POST", "/codex-notify", raw, nil, 5*time.Second)
			return nil
		},
	}
}

// wrapCmd runs a CLI inside tmux in the current directory so the daemon can
// control it, attaching the terminal to it.
func wrapCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "wrap <claude|codex> [args...]",
		Short: "Start claude or codex inside tmux here (controllable from the app)",
		Args:  cobra.MinimumNArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			cfg, err := config.Load(flagConfig)
			if err != nil {
				return err
			}
			prov := args[0]
			if prov != "claude" && prov != "codex" {
				return errors.New("first argument must be claude or codex")
			}
			cwd, _ := os.Getwd()
			name := fmt.Sprintf("%s-%s-%d", cfg.Tmux.SessionPrefix, prov, os.Getpid())
			tmuxBin, err := exec.LookPath(firstNonEmpty(cfg.Tmux.Binary, "tmux"))
			if err != nil {
				return errors.New("tmux is not installed")
			}
			targv := []string{"tmux", "new-session", "-s", name, "-c", cwd, "--", prov}
			targv = append(targv, args[1:]...)
			if os.Getenv("TMUX") != "" {
				// Already inside tmux: open a new window instead of nesting.
				targv = []string{"tmux", "new-window", "-c", cwd, "--", prov}
				targv = append(targv, args[1:]...)
			}
			return syscall.Exec(tmuxBin, targv, os.Environ())
		},
	}
}

func firstNonEmpty(ss ...string) string {
	for _, s := range ss {
		if s != "" {
			return s
		}
	}
	return ""
}

func doctorCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "doctor",
		Short: "Check the environment (tmux, CLIs, profiles, hooks, daemon)",
		RunE:  func(cmd *cobra.Command, args []string) error { return doctor(cmd.Context()) },
	}
}

// doctor prints the environment checks; shared by `doctor` and `install`.
func doctor(ctx context.Context) error {
	cfg, err := config.Load(flagConfig)
	if err != nil {
		fmt.Println("config: ERROR", err)
		return fmt.Errorf("fix the configuration file, then run doctor again")
	}
	fmt.Println("config:", cfg.Path)
	fmt.Println("workspaces:", cfg.Workspaces)
	fmt.Println("repos:", cfg.Repos, "(repos.toml:", config.ManagedPath(cfg.Path)+")")
	check := func(bin string) string {
		if p, err := exec.LookPath(bin); err == nil {
			return p
		}
		return "NOT FOUND"
	}
	fmt.Println("tmux:", check("tmux"))
	fmt.Println("claude:", check("claude"))
	fmt.Println("codex:", check("codex"))
	fmt.Println("cswap:", check("cswap"), "(optional)")
	for _, p := range claude.Profiles(cfg.Profiles, nil) {
		fmt.Println("claude profile:", p.Dir, "->", p.Projects)
		b, _ := os.ReadFile(filepath.Join(p.Dir, "settings.json"))
		if strings.Contains(string(b), "porthole hook") {
			fmt.Println("  hooks: installed")
		} else {
			fmt.Println("  hooks: not installed (run `porthole install-hooks`)")
		}
	}
	for _, p := range codex.Profiles(cfg.Profiles, nil) {
		fmt.Println("codex profile:", p.Dir, "->", p.Sessions)
	}
	var st server.Status
	if err := server.NewLocalClient().Call(ctx, "GET", "/status", nil, &st, 3*time.Second); err != nil {
		fmt.Println("daemon: not running")
	} else {
		fmt.Printf("daemon: running (%s) on %s\n", st.Version, strings.Join(st.Bound, ", "))
		printListeners(st.Listeners)
	}
	port := cfg.Port
	if port == 0 {
		port = config.Default().Port
	}
	for _, line := range firewallHint(ctx, port) {
		fmt.Println(line)
	}
	fmt.Println("note: VPN traffic often bypasses the host firewall; LAN traffic does not.")
	if len(cfg.Workspaces) == 0 && len(cfg.Repos) == 0 {
		fmt.Println("hint: run `porthole add` inside a repository (or `porthole add --workspace ~/Programming`) so the app can start sessions there")
	}
	return nil
}

func configCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "config",
		Short: "Print the effective configuration and paths",
		RunE: func(cmd *cobra.Command, args []string) error {
			cfg, err := config.Load(flagConfig)
			if err != nil {
				return err
			}
			fmt.Println("config dir: ", config.ConfigDir())
			fmt.Println("state dir:  ", config.StateDir())
			fmt.Println("socket:     ", config.SocketPath())
			b, _ := json.MarshalIndent(cfg, "", "  ")
			fmt.Println(string(b))
			return nil
		},
	}
}
