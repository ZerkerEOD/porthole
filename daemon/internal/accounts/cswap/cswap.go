// Package cswap reads claude-swap's machine-readable output. It is a cache
// read: cswap serves usage younger than its serve TTL without any network
// call and owns the poll cadence to Anthropic's usage endpoint, so Porthole
// never calls that endpoint itself.
package cswap

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"os/exec"
	"time"
)

// Client runs cswap.
type Client struct {
	Binary string
}

// Available reports whether cswap is on PATH.
func (c *Client) Available() bool {
	bin := c.Binary
	if bin == "" {
		bin = "cswap"
	}
	_, err := exec.LookPath(bin)
	return err == nil
}

// Snapshot is the raw `cswap list --json` document (schemaVersion 1) plus
// when Porthole fetched it. The daemon forwards it unchanged so the app can
// render whatever fields exist.
type Snapshot struct {
	FetchedAt time.Time       `json:"fetched_at"`
	Raw       json.RawMessage `json:"raw"`
	Active    string          `json:"active_email,omitempty"`
	Schema    int             `json:"schema_version,omitempty"`
}

// List returns the account list with usage.
func (c *Client) List(ctx context.Context) (*Snapshot, error) {
	bin := c.Binary
	if bin == "" {
		bin = "cswap"
	}
	ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, bin, "list", "--json")
	// cswap honours CLAUDE_CONFIG_DIR; it must target the default profile.
	env := os.Environ()
	out := env[:0]
	for _, kv := range env {
		if len(kv) >= 18 && kv[:18] == "CLAUDE_CONFIG_DIR=" {
			continue
		}
		out = append(out, kv)
	}
	cmd.Env = out
	b, err := cmd.Output()
	if err != nil {
		var ee *exec.ExitError
		if errors.As(err, &ee) && len(b) > 0 {
			// cswap may exit non-zero while still printing JSON (e.g. a dead account).
		} else {
			return nil, err
		}
	}
	var probe struct {
		SchemaVersion int `json:"schemaVersion"`
		Accounts      []struct {
			Email  string `json:"email"`
			Active bool   `json:"active"`
		} `json:"accounts"`
	}
	if err := json.Unmarshal(b, &probe); err != nil {
		return nil, err
	}
	s := &Snapshot{FetchedAt: time.Now(), Raw: json.RawMessage(b), Schema: probe.SchemaVersion}
	for _, a := range probe.Accounts {
		if a.Active {
			s.Active = a.Email
		}
	}
	return s, nil
}
