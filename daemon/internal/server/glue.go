package server

import (
	"crypto/tls"
	"net"

	"github.com/ZerkerEOD/porthole/daemon/internal/tmux"
)

// tmux0 aliases the pane screen type for the hub's coalescing map.
type tmux0 = tmux.Screen

func tls0(l net.Listener, c *tls.Config) net.Listener { return tls.NewListener(l, c) }
