package main

import (
	"bufio"
	"context"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"os"
	"strings"
	"time"

	"github.com/coder/websocket"
	"github.com/spf13/cobra"

	"github.com/ZerkerEOD/porthole/daemon/internal/server"
)

// clientCmd is a developer tool: a pinned-TLS WebSocket client that pairs,
// sends messages from the command line, and prints what the daemon pushes.
func clientCmd() *cobra.Command {
	var host, fp, token, code, name string
	var port, seconds int
	c := &cobra.Command{
		Use:    "client [type [json-payload]]...",
		Short:  "Developer WebSocket client (pair with --code, then send messages)",
		Hidden: true,
		RunE: func(cmd *cobra.Command, args []string) error {
			tcfg := &tls.Config{
				InsecureSkipVerify: true, // we pin the leaf instead
				MinVersion:         tls.VersionTLS13,
				VerifyPeerCertificate: func(raw [][]byte, _ [][]*x509.Certificate) error {
					if len(raw) == 0 {
						return errors.New("no certificate")
					}
					sum := sha256.Sum256(raw[0])
					if got := base64.RawURLEncoding.EncodeToString(sum[:]); got != fp {
						return fmt.Errorf("certificate fingerprint mismatch: %s", got)
					}
					return nil
				},
			}
			hc := &http.Client{Transport: &http.Transport{TLSClientConfig: tcfg}, Timeout: 15 * time.Second}
			base := fmt.Sprintf("https://%s:%d", host, port)
			if code != "" {
				body, _ := json.Marshal(map[string]string{"code": code, "device_name": name})
				resp, err := hc.Post(base+"/v1/pair", "application/json", strings.NewReader(string(body)))
				if err != nil {
					return err
				}
				defer resp.Body.Close()
				var out map[string]any
				if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
					return fmt.Errorf("pair: %s", resp.Status)
				}
				b, _ := json.Marshal(out)
				fmt.Println(string(b))
				token, _ = out["token"].(string)
				if token == "" {
					return errors.New("pairing failed")
				}
			}
			if token == "" {
				return errors.New("--token or --code required")
			}
			ctx, cancel := context.WithTimeout(cmd.Context(), time.Duration(seconds)*time.Second)
			defer cancel()
			ws, _, err := websocket.Dial(ctx, strings.Replace(base, "https://", "wss://", 1)+"/v1/ws", &websocket.DialOptions{
				HTTPClient:   hc,
				HTTPHeader:   http.Header{"Authorization": {"Bearer " + token}},
				Subprotocols: []string{"porthole.v1"},
			})
			if err != nil {
				return err
			}
			defer ws.Close(websocket.StatusNormalClosure, "bye")
			ws.SetReadLimit(4 << 20)
			go func() {
				for i := 0; i+1 <= len(args); i += 2 {
					payload := "{}"
					if i+1 < len(args) {
						payload = args[i+1]
					}
					m, _ := json.Marshal(server.Message{Type: args[i], ID: fmt.Sprint(i/2 + 1), Payload: json.RawMessage(payload)})
					if err := ws.Write(ctx, websocket.MessageText, m); err != nil {
						return
					}
					time.Sleep(300 * time.Millisecond)
				}
				if len(args) == 0 {
					// Interactive: read lines "type payload" from stdin.
					sc := bufio.NewScanner(os.Stdin)
					for sc.Scan() {
						t, p, _ := strings.Cut(sc.Text(), " ")
						if p == "" {
							p = "{}"
						}
						m, _ := json.Marshal(server.Message{Type: t, ID: "i", Payload: json.RawMessage(p)})
						_ = ws.Write(ctx, websocket.MessageText, m)
					}
				}
			}()
			for {
				_, data, err := ws.Read(ctx)
				if err != nil {
					return nil
				}
				var m server.Message
				_ = json.Unmarshal(data, &m)
				pl := string(m.Payload)
				if len(pl) > 1500 {
					pl = pl[:1500] + "…"
				}
				fmt.Printf("<- %s %s %s\n", m.Type, m.ID, pl)
			}
		},
	}
	c.Flags().StringVar(&host, "host", "127.0.0.1", "daemon host")
	c.Flags().IntVar(&port, "port", 7433, "daemon port")
	c.Flags().StringVar(&fp, "fp", "", "certificate fingerprint to pin (from `porthole pair`)")
	c.Flags().StringVar(&token, "token", "", "device token")
	c.Flags().StringVar(&code, "code", "", "pairing code (pairs first, prints the token)")
	c.Flags().StringVar(&name, "name", "dev-client", "device name when pairing")
	c.Flags().IntVar(&seconds, "seconds", 5, "how long to listen")
	return c
}
