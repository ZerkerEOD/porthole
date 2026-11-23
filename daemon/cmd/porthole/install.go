package main

import (
	"context"
	"fmt"
	"os"
	"time"

	"github.com/spf13/cobra"

	"github.com/ZerkerEOD/porthole/daemon/internal/config"
	"github.com/ZerkerEOD/porthole/daemon/internal/install"
	"github.com/ZerkerEOD/porthole/daemon/internal/server"
)

func installCmd() *cobra.Command {
	var noService, noHooks bool
	c := &cobra.Command{
		Use:   "install",
		Short: "Put porthole in ~/.local/bin, start it as a user service, and install the hooks",
		RunE: func(cmd *cobra.Command, args []string) error {
			if os.Geteuid() == 0 {
				return fmt.Errorf("run porthole install as the user who runs claude/codex, not root")
			}
			if err := config.EnsureDirs(); err != nil {
				return err
			}
			bin, err := install.Binary(binaryPath())
			if err != nil {
				return err
			}
			fmt.Println("binary:", bin)
			if !noService {
				notes, err := install.Service(cmd.Context(), bin)
				if err != nil {
					fmt.Fprintln(os.Stderr, "service:", err)
					fmt.Fprintln(os.Stderr, "You can still run `porthole serve` by hand.")
				}
				for _, n := range notes {
					fmt.Println("service:", n)
				}
				waitForDaemon(cmd.Context(), 5*time.Second)
			}
			fmt.Println()
			if err := doctor(cmd.Context()); err != nil {
				return err
			}
			fmt.Println()
			if !noHooks {
				hooks := installHooksCmd()
				hooks.SetArgs(nil)
				if err := hooks.ExecuteContext(cmd.Context()); err != nil {
					fmt.Fprintln(os.Stderr, "hooks:", err)
				}
			}
			cfg, err := config.Load(flagConfig)
			if err != nil {
				return err
			}
			fmt.Println()
			fmt.Println("Next:")
			if len(cfg.Workspaces) == 0 && len(cfg.Repos) == 0 {
				fmt.Println("  cd <your repository> && porthole add     # offer it in the app (repeat per repo, or --workspace for a parent folder)")
			}
			fmt.Println("  porthole pair                             # scan the QR code with the app")
			fmt.Println("  porthole status                           # check the daemon")
			return nil
		},
	}
	c.Flags().BoolVar(&noService, "no-service", false, "do not register a user service")
	c.Flags().BoolVar(&noHooks, "no-hooks", false, "do not install the Claude Code / Codex hooks")
	return c
}

// waitForDaemon gives a freshly started service time to bind its addresses so
// the checks that follow describe the running state, not the start-up gap.
func waitForDaemon(ctx context.Context, max time.Duration) {
	deadline := time.Now().Add(max)
	for time.Now().Before(deadline) {
		var st server.Status
		if err := server.NewLocalClient().Call(ctx, "GET", "/status", nil, &st, time.Second); err == nil && len(st.Bound) > 0 {
			return
		}
		time.Sleep(250 * time.Millisecond)
	}
}
