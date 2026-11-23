package push

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestKeyAgreementAndSeal(t *testing.T) {
	aPriv, aPub, _ := Keypair()
	bPriv, bPub, _ := Keypair()
	ka, err := DeriveKey(aPriv, bPub)
	if err != nil {
		t.Fatal(err)
	}
	kb, _ := DeriveKey(bPriv, aPub)
	if string(ka) != string(kb) {
		t.Fatal("keys differ")
	}
	ct, err := Encrypt(ka, []byte("hello"))
	if err != nil {
		t.Fatal(err)
	}
	pt, err := Decrypt(kb, ct)
	if err != nil || string(pt) != "hello" {
		t.Fatalf("roundtrip: %q %v", pt, err)
	}
	ct[len(ct)-1] ^= 1
	if _, err := Decrypt(kb, ct); err == nil {
		t.Fatal("tampered ciphertext accepted")
	}
	if _, err := DeriveKey(aPriv[:5], bPub); err == nil {
		t.Fatal("short key accepted")
	}
}

func TestSendShape(t *testing.T) {
	var got map[string]string
	srv := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/v1/push" || r.Method != http.MethodPost {
			w.WriteHeader(404)
			return
		}
		_ = json.NewDecoder(r.Body).Decode(&got)
		if got["grant"] == "bad" {
			w.WriteHeader(403)
			return
		}
		w.WriteHeader(202)
	}))
	defer srv.Close()
	c, err := NewClient(srv.URL)
	if err != nil {
		t.Fatal(err)
	}
	c.HTTP = srv.Client()
	_, pub, _ := Keypair()
	priv, _, _ := Keypair()
	key, _ := DeriveKey(priv, pub)
	n := Notification{Kind: "permission", SessionKey: "claude:x", Title: strings.Repeat("t", 200), Daemon: "desk", At: 1}
	if status, err := c.Send(context.Background(), "g1", key, n, "claude:x"); err != nil || status != 202 {
		t.Fatal(status, err)
	}
	if got["grant"] != "g1" || got["ct"] == "" || got["collapse"] != "claude:x" {
		t.Fatalf("body: %v", got)
	}
	if _, err := c.Send(context.Background(), "bad", key, n, ""); err == nil {
		t.Fatal("expected rejection")
	}
	if _, err := NewClient("http://insecure"); err == nil {
		t.Fatal("http relay accepted")
	}
}
