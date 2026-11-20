// Package server is the network edge: TLS, bind policy, device pairing and
// tokens, the WebSocket/JSON API for phones, and the local control socket.
package server

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/base64"
	"encoding/pem"
	"errors"
	"math/big"
	"net"
	"os"
	"path/filepath"
	"time"
)

// LoadOrCreateCert returns the daemon's self-signed certificate, creating it
// on first run. The key is written 0600 inside stateDir.
func LoadOrCreateCert(stateDir, name string) (tls.Certificate, error) {
	certPath := filepath.Join(stateDir, "tls.crt")
	keyPath := filepath.Join(stateDir, "tls.key")
	if c, err := tls.LoadX509KeyPair(certPath, keyPath); err == nil {
		return c, nil
	}
	priv, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return tls.Certificate{}, err
	}
	serial, err := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 127))
	if err != nil {
		return tls.Certificate{}, err
	}
	tmpl := &x509.Certificate{
		SerialNumber:          serial,
		Subject:               pkix.Name{CommonName: "porthole-" + name},
		NotBefore:             time.Now().Add(-time.Hour),
		NotAfter:              time.Now().Add(10 * 365 * 24 * time.Hour),
		KeyUsage:              x509.KeyUsageDigitalSignature | x509.KeyUsageKeyEncipherment,
		ExtKeyUsage:           []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		BasicConstraintsValid: true,
		DNSNames:              []string{"porthole", "localhost"},
		IPAddresses:           []net.IP{net.IPv4(127, 0, 0, 1), net.IPv6loopback},
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &priv.PublicKey, priv)
	if err != nil {
		return tls.Certificate{}, err
	}
	keyDER, err := x509.MarshalECPrivateKey(priv)
	if err != nil {
		return tls.Certificate{}, err
	}
	if err := os.WriteFile(keyPath, pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE KEY", Bytes: keyDER}), 0o600); err != nil {
		return tls.Certificate{}, err
	}
	if err := os.WriteFile(certPath, pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}), 0o600); err != nil {
		return tls.Certificate{}, err
	}
	return tls.LoadX509KeyPair(certPath, keyPath)
}

// ResetCert deletes the key pair so the next start mints a new identity.
// Every paired device must re-pair afterwards (pinning fails), which is the
// intended incident response.
func ResetCert(stateDir string) error {
	for _, f := range []string{"tls.crt", "tls.key"} {
		if err := os.Remove(filepath.Join(stateDir, f)); err != nil && !errors.Is(err, os.ErrNotExist) {
			return err
		}
	}
	return nil
}

// Fingerprint is the SHA-256 of the leaf certificate (DER), base64url, which
// the app pins. Certificate pinning (rather than SPKI) is fine here because
// the daemon controls rotation and re-pairing is the rotation path.
func Fingerprint(c tls.Certificate) string {
	sum := sha256.Sum256(c.Certificate[0])
	return base64.RawURLEncoding.EncodeToString(sum[:])
}

// TLSConfig is TLS 1.3 only with the daemon certificate.
func TLSConfig(c tls.Certificate) *tls.Config {
	return &tls.Config{
		Certificates: []tls.Certificate{c},
		MinVersion:   tls.VersionTLS13,
		NextProtos:   []string{"http/1.1"},
	}
}
