package main

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"text/tabwriter"
	"time"

	"github.com/spf13/cobra"

	"github.com/ZerkerEOD/porthole/daemon/internal/config"
	"github.com/ZerkerEOD/porthole/daemon/internal/core"
	"github.com/ZerkerEOD/porthole/daemon/internal/server"
)

// resolveDir makes dir absolute and resolves symlinks.
func resolveDir(dir string) (string, error) {
	abs, err := filepath.Abs(config.Expand(dir))
	if err != nil {
		return "", err
	}
	return filepath.EvalSymlinks(abs)
}

// gitTopLevel walks up from dir to the directory that holds .git.
func gitTopLevel(dir string) (string, error) {
	real, err := resolveDir(dir)
	if err != nil {
		return "", err
	}
	for d := real; ; d = filepath.Dir(d) {
		if _, err := os.Stat(filepath.Join(d, ".git")); err == nil {
			return d, nil
		}
		if filepath.Dir(d) == d {
			return "", fmt.Errorf("%s is not inside a git repository (use --workspace to add a parent folder instead)", real)
		}
	}
}

func confirm(prompt string, yes bool) (bool, error) {
	if yes {
		return true, nil
	}
	if st, err := os.Stdin.Stat(); err != nil || st.Mode()&os.ModeCharDevice == 0 {
		return false, errors.New("not a terminal; pass --yes to confirm")
	}
	fmt.Printf("%s [Y/n] ", prompt)
	line, _ := bufio.NewReader(os.Stdin).ReadString('\n')
	line = strings.ToLower(strings.TrimSpace(line))
	return line == "" || line == "y" || line == "yes", nil
}

// reloadDaemon asks a running daemon to re-read its directory lists.
func reloadDaemon() {
	var res server.ReloadResult
	if err := server.NewLocalClient().Call(context.Background(), "POST", "/config/reload", nil, &res, 5*time.Second); err != nil {
		fmt.Println("daemon not running; the change applies when it starts")
		return
	}
	fmt.Println("daemon reloaded")
}

func addCmd() *cobra.Command {
	var workspace, yes bool
	c := &cobra.Command{
		Use:   "add [dir]",
		Short: "Offer a repository (or, with --workspace, a parent folder) in the app",
		Long: `Records the repository containing dir (default: the current directory) in
repos.toml next to config.toml and tells a running daemon to reload.
With --workspace the directory itself is recorded and scanned two levels
deep for git repositories.`,
		Args: cobra.MaximumNArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			cfg, err := config.Load(flagConfig)
			if err != nil {
				return err
			}
			dir := "."
			if len(args) == 1 {
				dir = args[0]
			}
			var target, what string
			if workspace {
				target, err = resolveDir(dir)
				if err != nil {
					return err
				}
				st, err := os.Stat(target)
				if err != nil || !st.IsDir() {
					return fmt.Errorf("%s is not a directory", target)
				}
				what = "workspace"
			} else {
				target, err = gitTopLevel(dir)
				if err != nil {
					return err
				}
				what = "repository"
			}
			for _, p := range append(cfg.Workspaces, cfg.Repos...) {
				if p == target {
					fmt.Printf("%s is already configured\n", target)
					return nil
				}
			}
			ok, err := confirm(fmt.Sprintf("Add %s %s to Porthole?", what, target), yes)
			if err != nil {
				return err
			}
			if !ok {
				fmt.Println("not added")
				return nil
			}
			added, err := config.AddManaged(config.ManagedPath(cfg.Path), target, workspace)
			if err != nil {
				return err
			}
			if added {
				fmt.Printf("added %s %s\n", what, target)
			}
			reloadDaemon()
			return nil
		},
	}
	c.Flags().BoolVar(&workspace, "workspace", false, "add the directory as a workspace (scanned for repositories) instead of one repository")
	c.Flags().BoolVarP(&yes, "yes", "y", false, "do not ask for confirmation")
	return c
}

func removeCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "remove [dir]",
		Short: "Stop offering a repository or workspace added with `porthole add`",
		Args:  cobra.MaximumNArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			cfg, err := config.Load(flagConfig)
			if err != nil {
				return err
			}
			dir := "."
			if len(args) == 1 {
				dir = args[0]
			}
			target, err := resolveDir(dir)
			if err != nil {
				return err
			}
			if top, err := gitTopLevel(target); err == nil {
				m, _ := config.LoadManaged(config.ManagedPath(cfg.Path))
				listed := false
				for _, p := range append(m.Repos, m.Workspaces...) {
					if config.Expand(p) == target {
						listed = true
					}
				}
				if !listed {
					target = top
				}
			}
			removed, err := config.RemoveManaged(config.ManagedPath(cfg.Path), target)
			if err != nil {
				return err
			}
			if !removed {
				for _, p := range append(cfg.Workspaces, cfg.Repos...) {
					if p == target {
						return fmt.Errorf("%s comes from %s; edit that file by hand", target, cfg.Path)
					}
				}
				return fmt.Errorf("%s is not configured", target)
			}
			fmt.Println("removed", target)
			reloadDaemon()
			return nil
		},
	}
}

func reposCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "repos",
		Short: "List the repositories the app can start sessions in",
		RunE: func(cmd *cobra.Command, args []string) error {
			var repos []core.Repo
			if err := server.NewLocalClient().Call(cmd.Context(), "GET", "/repos", nil, &repos, 10*time.Second); err != nil {
				cfg, lerr := config.Load(flagConfig)
				if lerr != nil {
					return lerr
				}
				fmt.Println("daemon not running; configured directories:")
				for _, w := range cfg.Workspaces {
					fmt.Println("  workspace", w)
				}
				for _, r := range cfg.Repos {
					fmt.Println("  repo     ", r)
				}
				if len(cfg.Workspaces) == 0 && len(cfg.Repos) == 0 {
					fmt.Println("  (none; run `porthole add` inside a repository)")
				}
				return nil
			}
			tw := tabwriter.NewWriter(os.Stdout, 0, 4, 2, ' ', 0)
			fmt.Fprintln(tw, "SOURCE\tBRANCH\tLAST USED\tPATH")
			for _, r := range repos {
				lu := ""
				if !r.LastUsed.IsZero() {
					lu = r.LastUsed.Local().Format("01-02 15:04")
				}
				fmt.Fprintf(tw, "%s\t%s\t%s\t%s\n", r.Source, r.Branch, lu, r.Path)
			}
			if len(repos) == 0 {
				fmt.Fprintln(tw, "(none)\t\t\trun `porthole add` inside a repository")
			}
			return tw.Flush()
		},
	}
}
