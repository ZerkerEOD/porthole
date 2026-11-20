package server

import (
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base32"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

// Device is a paired phone.
type Device struct {
	ID        string    `json:"id"`
	Name      string    `json:"name"`
	TokenHash string    `json:"token_hash"` // hex sha256
	Scopes    []string  `json:"scopes,omitempty"`
	CreatedAt time.Time `json:"created_at"`
	LastSeen  time.Time `json:"last_seen,omitempty"`
	// PushSecret is the HKDF-derived XChaCha20 key agreed at pairing (hex);
	// present only when the app offered a push key. The daemon's ephemeral
	// private key is discarded after derivation.
	PushSecret string `json:"push_secret,omitempty"`
	// PushGrant is the opaque relay grant the app registered, and when it
	// expires; empty when push is off for this device.
	PushGrant    string    `json:"push_grant,omitempty"`
	PushGrantExp time.Time `json:"push_grant_exp,omitempty"`
}

// Store persists devices and holds pending pairing codes in memory.
type Store struct {
	path string
	mu   sync.Mutex
	devs []Device
	// pairing
	codes map[string]pairingCode
	// per-source failed attempts for brute-force limiting
	attempts map[string][]time.Time
	// revoked device ids, drained by the server to close live sockets
	revoked []string
}

type pairingCode struct {
	hash    string
	expires time.Time
	label   string
}

const (
	pairingTTL        = 2 * time.Minute
	pairingMaxPerMin  = 5
	tokenBytes        = 32
	pairingCodeLength = 8
)

// OpenStore loads devices.json (0600) or starts empty.
func OpenStore(stateDir string) (*Store, error) {
	s := &Store{path: filepath.Join(stateDir, "devices.json"), codes: map[string]pairingCode{}, attempts: map[string][]time.Time{}}
	b, err := os.ReadFile(s.path)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return s, nil
		}
		return nil, err
	}
	var doc struct {
		Devices []Device `json:"devices"`
	}
	if err := json.Unmarshal(b, &doc); err != nil {
		return nil, err
	}
	s.devs = doc.Devices
	return s, nil
}

func (s *Store) save() error {
	b, err := json.MarshalIndent(struct {
		Devices []Device `json:"devices"`
	}{s.devs}, "", "  ")
	if err != nil {
		return err
	}
	tmp := s.path + ".tmp"
	if err := os.WriteFile(tmp, b, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, s.path)
}

func hashToken(tok string) string {
	h := sha256.Sum256([]byte(tok))
	return hex.EncodeToString(h[:])
}

// NewPairingCode mints a single-use code valid for pairingTTL.
func (s *Store) NewPairingCode(label string) (code string, expires time.Time, err error) {
	var raw [5]byte
	if _, err = rand.Read(raw[:]); err != nil {
		return "", time.Time{}, err
	}
	code = strings.ToUpper(base32.StdEncoding.WithPadding(base32.NoPadding).EncodeToString(raw[:]))[:pairingCodeLength]
	expires = time.Now().Add(pairingTTL)
	s.mu.Lock()
	defer s.mu.Unlock()
	for k, c := range s.codes {
		if time.Now().After(c.expires) {
			delete(s.codes, k)
		}
	}
	s.codes[hashToken(code)] = pairingCode{hash: hashToken(code), expires: expires, label: label}
	return code, expires, nil
}

// ErrRateLimited is returned when a source has failed too often.
var ErrRateLimited = errors.New("too many pairing attempts")

// ErrBadCode is returned for an unknown, expired or used code.
var ErrBadCode = errors.New("invalid or expired pairing code")

// Pair consumes a code and returns the new device and its plaintext token
// (shown exactly once).
func (s *Store) Pair(source, code, deviceName, pushSecretHex string) (Device, string, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	now := time.Now()
	var recent []time.Time
	for _, t := range s.attempts[source] {
		if now.Sub(t) < time.Minute {
			recent = append(recent, t)
		}
	}
	s.attempts[source] = recent
	if len(recent) >= pairingMaxPerMin {
		return Device{}, "", ErrRateLimited
	}
	h := hashToken(strings.ToUpper(strings.TrimSpace(code)))
	var found *pairingCode
	for k, c := range s.codes {
		if subtle.ConstantTimeCompare([]byte(k), []byte(h)) == 1 {
			cc := c
			found = &cc
			break
		}
	}
	if found == nil || now.After(found.expires) || len(code) != pairingCodeLength {
		s.attempts[source] = append(recent, now)
		return Device{}, "", ErrBadCode
	}
	delete(s.codes, h)
	var tok [tokenBytes]byte
	if _, err := rand.Read(tok[:]); err != nil {
		return Device{}, "", err
	}
	token := base64.RawURLEncoding.EncodeToString(tok[:])
	var idb [8]byte
	_, _ = rand.Read(idb[:])
	name := strings.TrimSpace(deviceName)
	if name == "" {
		name = "phone"
	}
	if len(name) > 64 {
		name = name[:64]
	}
	d := Device{ID: hex.EncodeToString(idb[:]), Name: name, TokenHash: hashToken(token), CreatedAt: now, PushSecret: pushSecretHex}
	s.devs = append(s.devs, d)
	if err := s.save(); err != nil {
		s.devs = s.devs[:len(s.devs)-1]
		return Device{}, "", err
	}
	return d, token, nil
}

// Authenticate resolves a bearer token to a device.
func (s *Store) Authenticate(token string) (Device, bool) {
	if token == "" {
		return Device{}, false
	}
	h := hashToken(token)
	s.mu.Lock()
	defer s.mu.Unlock()
	for i := range s.devs {
		if subtle.ConstantTimeCompare([]byte(s.devs[i].TokenHash), []byte(h)) == 1 {
			s.devs[i].LastSeen = time.Now()
			return s.devs[i], true
		}
	}
	return Device{}, false
}

// Touch persists LastSeen occasionally (called by the server, not per request).
func (s *Store) Touch() { s.mu.Lock(); _ = s.save(); s.mu.Unlock() }

// Devices lists paired devices without secrets.
func (s *Store) Devices() []Device {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := make([]Device, len(s.devs))
	for i, d := range s.devs {
		d.TokenHash, d.PushSecret, d.PushGrant = "", "", ""
		out[i] = d
	}
	return out
}

// SetPushGrant stores (or clears, with empty grant) a device's relay grant.
func (s *Store) SetPushGrant(id, grant string, exp time.Time) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	for i := range s.devs {
		if s.devs[i].ID == id {
			s.devs[i].PushGrant, s.devs[i].PushGrantExp = grant, exp
			return s.save()
		}
	}
	return errors.New("no such device")
}

// PushTargets returns devices with a live grant and a push secret, with
// their secrets (for the push sender only).
func (s *Store) PushTargets() []Device {
	s.mu.Lock()
	defer s.mu.Unlock()
	var out []Device
	for _, d := range s.devs {
		if d.PushGrant != "" && d.PushSecret != "" && time.Now().Before(d.PushGrantExp) {
			out = append(out, d)
		}
	}
	return out
}

// Revoke removes a device. The server closes its connections.
func (s *Store) Revoke(id string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	for i, d := range s.devs {
		if d.ID == id {
			s.devs = append(s.devs[:i], s.devs[i+1:]...)
			s.revoked = append(s.revoked, id)
			return s.save()
		}
	}
	return errors.New("no such device")
}

// DrainRevoked returns and clears device ids revoked since the last call.
func (s *Store) DrainRevoked() []string {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := s.revoked
	s.revoked = nil
	return out
}

// IsDevice reports whether id is still paired.
func (s *Store) IsDevice(id string) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, d := range s.devs {
		if d.ID == id {
			return true
		}
	}
	return false
}
