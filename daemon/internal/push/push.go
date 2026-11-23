// Package push is the opt-in relay client. It is inert unless a relay URL is
// configured and a device has registered a push grant. Payloads are
// encrypted end to end with a key agreed at pairing, so the relay, FCM and
// the platforms see only ciphertext.
package push

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"

	"golang.org/x/crypto/chacha20poly1305"
	"golang.org/x/crypto/curve25519"
	"golang.org/x/crypto/hkdf"
)

// MaxPayload is the relay's ciphertext cap (bytes, before base64).
const MaxPayload = 480

// Keypair generates an X25519 keypair.
func Keypair() (priv, pub []byte, err error) {
	priv = make([]byte, 32)
	if _, err := rand.Read(priv); err != nil {
		return nil, nil, err
	}
	pub, err = curve25519.X25519(priv, curve25519.Basepoint)
	return priv, pub, err
}

// DeriveKey computes the shared push key from our private key and the peer's
// public key: HKDF-SHA256(X25519(priv, pub), info="porthole-push-v1").
func DeriveKey(priv, peerPub []byte) ([]byte, error) {
	if len(priv) != 32 || len(peerPub) != 32 {
		return nil, errors.New("push: bad key length")
	}
	shared, err := curve25519.X25519(priv, peerPub)
	if err != nil {
		return nil, err
	}
	key := make([]byte, chacha20poly1305.KeySize)
	if _, err := io.ReadFull(hkdf.New(sha256.New, shared, nil, []byte("porthole-push-v1")), key); err != nil {
		return nil, err
	}
	return key, nil
}

// Encrypt seals plaintext with XChaCha20-Poly1305; output is nonce||ciphertext.
func Encrypt(key, plaintext []byte) ([]byte, error) {
	aead, err := chacha20poly1305.NewX(key)
	if err != nil {
		return nil, err
	}
	nonce := make([]byte, aead.NonceSize())
	if _, err := rand.Read(nonce); err != nil {
		return nil, err
	}
	return aead.Seal(nonce, nonce, plaintext, nil), nil
}

// Decrypt reverses Encrypt (used by tests and the dev client).
func Decrypt(key, sealed []byte) ([]byte, error) {
	aead, err := chacha20poly1305.NewX(key)
	if err != nil {
		return nil, err
	}
	if len(sealed) < aead.NonceSize() {
		return nil, errors.New("push: short ciphertext")
	}
	return aead.Open(nil, sealed[:aead.NonceSize()], sealed[aead.NonceSize():], nil)
}

// Notification is what the phone decrypts. Keep it tiny: the app fetches
// details from the daemon over the VPN after waking.
type Notification struct {
	Kind       string `json:"k"`           // permission|input|done|error
	SessionKey string `json:"s,omitempty"` // which session
	Title      string `json:"t,omitempty"` // session title, clipped
	Daemon     string `json:"d,omitempty"` // daemon name
	At         int64  `json:"at"`          // unix seconds
}

// Client posts to the relay.
type Client struct {
	RelayURL string
	HTTP     *http.Client
}

// NewClient validates the relay URL (https only) and returns a client.
func NewClient(relayURL string) (*Client, error) {
	u, err := url.Parse(relayURL)
	if err != nil || u.Scheme != "https" || u.Host == "" {
		return nil, fmt.Errorf("push: relay_url must be an https URL")
	}
	return &Client{RelayURL: strings.TrimRight(relayURL, "/"), HTTP: &http.Client{Timeout: 10 * time.Second}}, nil
}

// ErrRejected means the relay refused the grant (expired, revoked, limited).
var ErrRejected = errors.New("push: relay rejected the push")

// Send encrypts n with key and posts it under grant. collapse groups
// notifications for the same session so only the latest is shown. The
// relay's HTTP status is returned when a response arrived.
func (c *Client) Send(ctx context.Context, grant string, key []byte, n Notification, collapse string) (int, error) {
	if len(n.Title) > 80 {
		n.Title = n.Title[:80]
	}
	pt, err := json.Marshal(n)
	if err != nil {
		return 0, err
	}
	ct, err := Encrypt(key, pt)
	if err != nil {
		return 0, err
	}
	if len(ct) > MaxPayload {
		return 0, errors.New("push: payload too large")
	}
	body, _ := json.Marshal(map[string]string{
		"grant":    grant,
		"ct":       base64.RawURLEncoding.EncodeToString(ct),
		"collapse": collapse,
	})
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, c.RelayURL+"/v1/push", bytes.NewReader(body))
	if err != nil {
		return 0, err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("User-Agent", "porthole-daemon")
	resp, err := c.HTTP.Do(req)
	if err != nil {
		return 0, err
	}
	defer resp.Body.Close()
	_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, 4096))
	switch {
	case resp.StatusCode == 200 || resp.StatusCode == 202:
		return resp.StatusCode, nil
	case resp.StatusCode == 401 || resp.StatusCode == 403 || resp.StatusCode == 410 || resp.StatusCode == 429:
		return resp.StatusCode, fmt.Errorf("%w (%d)", ErrRejected, resp.StatusCode)
	default:
		return resp.StatusCode, fmt.Errorf("push: relay returned %s", resp.Status)
	}
}
