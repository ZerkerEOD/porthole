package server

import (
	"net"
	"sync"
	"time"
)

// Connection attempt paths and results reported in the local status.
const (
	PathPair      = "pair"
	PathWebSocket = "websocket"
	PathHTTP      = "http"

	ResultAccepted       = "accepted"
	ResultRejectedPublic = "rejected-public"
	ResultUnauthorized   = "401"
	ResultRateLimited    = "rate-limited"
)

const connLogSize = 20

// ConnAttempt is one connection attempt seen by the TLS edge.
type ConnAttempt struct {
	At     time.Time `json:"at"`
	From   string    `json:"from"`
	Path   string    `json:"path"`   // pair|websocket|http
	Result string    `json:"result"` // accepted|rejected-public|401|rate-limited
	Device string    `json:"device,omitempty"`
	Name   string    `json:"name,omitempty"`
}

// connLog is a fixed-size ring of the most recent connection attempts.
type connLog struct {
	mu   sync.Mutex
	buf  []ConnAttempt
	next int
	n    int
}

func newConnLog(size int) *connLog {
	if size <= 0 {
		size = 1
	}
	return &connLog{buf: make([]ConnAttempt, size)}
}

// add records an attempt, overwriting the oldest when full.
func (c *connLog) add(a ConnAttempt) {
	if a.At.IsZero() {
		a.At = time.Now()
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	c.buf[c.next] = a
	c.next = (c.next + 1) % len(c.buf)
	if c.n < len(c.buf) {
		c.n++
	}
}

// recent returns the stored attempts, newest first.
func (c *connLog) recent() []ConnAttempt {
	c.mu.Lock()
	defer c.mu.Unlock()
	out := make([]ConnAttempt, 0, c.n)
	for i := 1; i <= c.n; i++ {
		out = append(out, c.buf[(c.next-i+len(c.buf))%len(c.buf)])
	}
	return out
}

// pathKind maps a request path to its connection log kind.
func pathKind(p string) string {
	switch p {
	case "/v1/pair":
		return PathPair
	case "/v1/ws":
		return PathWebSocket
	}
	return PathHTTP
}

// remoteHost strips the port from an accepted connection's address.
func remoteHost(remote string) string {
	if host, _, err := net.SplitHostPort(remote); err == nil {
		return host
	}
	return remote
}
