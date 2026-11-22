package server

import (
	"errors"
	"fmt"
	"net"
	"net/netip"
	"sort"
	"strings"
)

var cgnat = netip.MustParsePrefix("100.64.0.0/10")

// IsPrivateAddr reports whether an address may be bound or accepted: loopback,
// link-local, RFC1918, CGNAT (Tailscale), or IPv6 ULA.
func IsPrivateAddr(a netip.Addr) bool {
	a = a.Unmap()
	return a.IsLoopback() || a.IsLinkLocalUnicast() || a.IsPrivate() || cgnat.Contains(a)
}

// vpnIface reports whether an interface name looks like a VPN tunnel.
func vpnIface(name string) bool {
	for _, p := range []string{"tailscale", "wg", "utun", "tun", "nebula", "zt"} {
		if strings.HasPrefix(name, p) {
			return true
		}
	}
	return false
}

// noiseIface reports container/virtual bridges that are never a phone's path.
func noiseIface(name string) bool {
	for _, p := range []string{"docker", "br-", "veth", "virbr", "lxc", "cni", "flannel", "podman"} {
		if strings.HasPrefix(name, p) {
			return true
		}
	}
	return false
}

// ListenAddrs resolves the configured listen list. "auto" expands to every
// private/VPN unicast address on the machine plus loopback. Public addresses
// are refused unless allowPublic is set.
func ListenAddrs(configured []string, allowPublic bool) ([]netip.Addr, error) {
	set := map[netip.Addr]bool{}
	for _, c := range configured {
		if c == "auto" || c == "" {
			ifs, err := net.Interfaces()
			if err != nil {
				return nil, err
			}
			for _, ifc := range ifs {
				if ifc.Flags&net.FlagUp == 0 || noiseIface(ifc.Name) {
					continue
				}
				addrs, err := ifc.Addrs()
				if err != nil {
					continue
				}
				for _, ad := range addrs {
					pfx, err := netip.ParsePrefix(ad.String())
					if err != nil {
						continue
					}
					a := pfx.Addr().Unmap()
					if a.IsLinkLocalUnicast() && !a.Is4() {
						continue // fe80:: needs a zone; skip
					}
					if IsPrivateAddr(a) || (vpnIface(ifc.Name) && !a.IsMulticast()) {
						set[a] = true
					}
				}
			}
			set[netip.MustParseAddr("127.0.0.1")] = true
			continue
		}
		a, err := netip.ParseAddr(c)
		if err != nil {
			return nil, fmt.Errorf("listen %q: %w", c, err)
		}
		if !IsPrivateAddr(a) && !allowPublic {
			return nil, fmt.Errorf("listen %q is a public address; refusing without --allow-public-bind-i-understand", c)
		}
		set[a.Unmap()] = true
	}
	if len(set) == 0 {
		return nil, errors.New("no listen addresses")
	}
	out := make([]netip.Addr, 0, len(set))
	for a := range set {
		out = append(out, a)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Less(out[j]) })
	return out, nil
}

// Address kinds reported for bound listeners.
const (
	KindLoopback = "loopback"
	KindLAN      = "lan"
	KindVPN      = "vpn"
	KindPublic   = "public"
)

// ClassifyAddr labels an address by how a phone would reach it: "loopback",
// "vpn" (VPN-named interface or CGNAT range), "lan" (other private), or
// "public" for anything else.
func ClassifyAddr(ip netip.Addr, ifname string) string {
	ip = ip.Unmap()
	switch {
	case ip.IsLoopback():
		return KindLoopback
	case vpnIface(ifname) || cgnat.Contains(ip):
		return KindVPN
	case IsPrivateAddr(ip):
		return KindLAN
	}
	return KindPublic
}

// Listener describes one bound address for status output.
type Listener struct {
	Addr  string `json:"addr"`
	Iface string `json:"iface"`
	Kind  string `json:"kind"`
}

// ifaceOf maps every local address to the interface that carries it.
func ifaceOf() map[netip.Addr]string {
	ifOf := map[netip.Addr]string{}
	ifs, _ := net.Interfaces()
	for _, ifc := range ifs {
		addrs, _ := ifc.Addrs()
		for _, ad := range addrs {
			if pfx, err := netip.ParsePrefix(ad.String()); err == nil {
				ifOf[pfx.Addr().Unmap()] = ifc.Name
			}
		}
	}
	return ifOf
}

// DescribeAddrs labels bound addresses with their interface and kind, VPN
// first, loopback last, sorted by address within a kind.
func DescribeAddrs(bound []netip.Addr, port int) []Listener {
	ifOf := ifaceOf()
	out := make([]Listener, 0, len(bound))
	for _, a := range bound {
		a = a.Unmap()
		out = append(out, Listener{Addr: netip.AddrPortFrom(a, uint16(port)).String(), Iface: ifOf[a], Kind: ClassifyAddr(a, ifOf[a])})
	}
	rank := map[string]int{KindVPN: 0, KindLAN: 1, KindPublic: 2, KindLoopback: 3}
	sort.SliceStable(out, func(i, j int) bool {
		if rank[out[i].Kind] != rank[out[j].Kind] {
			return rank[out[i].Kind] < rank[out[j].Kind]
		}
		return out[i].Addr < out[j].Addr
	})
	return out
}

// AdvertiseAddrs picks the addresses worth putting in a pairing QR: VPN and
// private addresses, excluding loopback, VPN first.
func AdvertiseAddrs(bound []netip.Addr) []string {
	type cand struct {
		a   string
		vpn bool
	}
	var cs []cand
	ifOf := ifaceOf()
	for _, a := range bound {
		if a.IsLoopback() {
			continue
		}
		cs = append(cs, cand{a.String(), ClassifyAddr(a, ifOf[a]) == KindVPN})
	}
	sort.SliceStable(cs, func(i, j int) bool { return cs[i].vpn && !cs[j].vpn })
	out := make([]string, 0, len(cs))
	for _, c := range cs {
		out = append(out, c.a)
	}
	return out
}

// RemoteAllowed checks an accepted connection's source.
func RemoteAllowed(remote string, allowPublic bool) bool {
	host, _, err := net.SplitHostPort(remote)
	if err != nil {
		host = remote
	}
	a, err := netip.ParseAddr(host)
	if err != nil {
		return false
	}
	return allowPublic || IsPrivateAddr(a)
}
