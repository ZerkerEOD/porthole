package server

import (
	"net/netip"
	"testing"
)

func TestClassifyAddr(t *testing.T) {
	cases := []struct {
		ip, iface, want string
	}{
		{"127.0.0.1", "lo", KindLoopback},
		{"::1", "lo", KindLoopback},
		{"::ffff:127.0.0.1", "lo", KindLoopback},
		{"192.168.1.10", "eth0", KindLAN},
		{"10.0.0.5", "wlan0", KindLAN},
		{"172.16.4.2", "eno1", KindLAN},
		{"fd12::1", "eth0", KindLAN},
		{"169.254.10.1", "eth0", KindLAN},
		{"100.101.102.103", "eth0", KindVPN},
		{"192.168.1.10", "tailscale0", KindVPN},
		{"10.8.0.2", "wg0", KindVPN},
		{"10.8.0.2", "utun3", KindVPN},
		{"10.8.0.2", "tun0", KindVPN},
		{"10.9.0.2", "nebula1", KindVPN},
		{"10.9.0.2", "zt0", KindVPN},
		{"203.0.113.7", "eth0", KindPublic},
		{"2001:db8::1", "eth0", KindPublic},
	}
	for _, c := range cases {
		if got := ClassifyAddr(netip.MustParseAddr(c.ip), c.iface); got != c.want {
			t.Errorf("ClassifyAddr(%s, %s) = %s, want %s", c.ip, c.iface, got, c.want)
		}
	}
}

func TestDescribeAddrsOrder(t *testing.T) {
	bound := []netip.Addr{netip.MustParseAddr("127.0.0.1"), netip.MustParseAddr("192.168.1.10"), netip.MustParseAddr("100.64.0.9")}
	got := DescribeAddrs(bound, 7433)
	if len(got) != 3 {
		t.Fatalf("got %d listeners", len(got))
	}
	if got[0].Kind != KindVPN || got[0].Addr != "100.64.0.9:7433" {
		t.Errorf("first should be vpn, got %+v", got[0])
	}
	if got[1].Kind != KindLAN || got[2].Kind != KindLoopback {
		t.Errorf("order wrong: %+v", got)
	}
}
