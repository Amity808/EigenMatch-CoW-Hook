package watcher

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/crypto"
)

func TestNewVerifierRequiresExecutorFields(t *testing.T) {
	_, err := New(Config{
		ExecutorEndpoint: "http://executor.local",
	})
	if err == nil || !strings.Contains(err.Error(), "POOL_ID") {
		t.Fatalf("expected POOL_ID error, got %v", err)
	}
}

func TestCheckOnceRejectsDigestMismatch(t *testing.T) {
	matcher := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		json.NewEncoder(w).Encode(bundleResponse{
			BundleID:       "0x1",
			DockerDigest:   "sha256:bad",
			TEEMeasurement: "tee",
			ReplaySalt:     "0x2",
		})
	}))
	defer matcher.Close()

	v := &Verifier{
		cfg: Config{
			MatcherEndpoint:     matcher.URL,
			AllowedDigests:      map[string]struct{}{"sha256:good": {}},
			AllowedMeasurements: map[string]struct{}{"tee": {}},
		},
		client: matcher.Client(),
	}

	if err := v.checkOnce(); err != ErrDigestMismatch {
		t.Fatalf("expected ErrDigestMismatch, got %v", err)
	}
}

func TestVerifierSubmitsToExecutor(t *testing.T) {
	var received ExecutorPayload
	executorSrv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		defer r.Body.Close()
		if err := json.NewDecoder(r.Body).Decode(&received); err != nil {
			t.Fatalf("decode executor payload: %v", err)
		}
		w.WriteHeader(http.StatusOK)
	}))
	defer executorSrv.Close()

	bundle := bundleResponse{
		BundleID:       "0xdeadbeef",
		DockerDigest:   "sha256:good",
		TEEMeasurement: "tee",
		ReplaySalt:     "0x01",
		Status:         "ok",
	}

	matcher := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		json.NewEncoder(w).Encode(bundle)
	}))
	defer matcher.Close()

	priv, _ := crypto.GenerateKey()
	pkHex := "0x" + common.Bytes2Hex(crypto.FromECDSA(priv))

	cfg := Config{
		MatcherEndpoint:     matcher.URL,
		AllowedDigests:      map[string]struct{}{"sha256:good": {}},
		AllowedMeasurements: map[string]struct{}{"tee": {}},
		ExecutorEndpoint:    executorSrv.URL,
		PoolID:              "0xpool",
		ExecutorContract:    "0x000000000000000000000000000000000000c0de",
		ExecutorChainID:     123,
		WatcherPrivateKey:   pkHex,
		PollInterval:        time.Millisecond,
	}

	verifier, err := New(cfg)
	if err != nil {
		t.Fatalf("new verifier: %v", err)
	}
	verifier.client = matcher.Client()
	verifier.executor.client = executorSrv.Client()
	verifier.executor.endpoint = executorSrv.URL

	if err := verifier.checkOnce(); err != nil {
		t.Fatalf("checkOnce: %v", err)
	}

	if received.Bundle.BundleID != bundle.BundleID {
		t.Fatalf("expected bundle id %s, got %s", bundle.BundleID, received.Bundle.BundleID)
	}
	if received.PoolID != cfg.PoolID {
		t.Fatalf("pool mismatch: %s", received.PoolID)
	}
	if received.WatcherAddress != crypto.PubkeyToAddress(priv.PublicKey).Hex() {
		t.Fatalf("watcher address mismatch")
	}
	if received.Signature == "" || !strings.HasPrefix(received.Signature, "0x") {
		t.Fatalf("expected signature, got %s", received.Signature)
	}
}

func TestVerifierRejectsReplaySaltSeen(t *testing.T) {
	callCount := 0
	matcher := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		callCount++
		resp := bundleResponse{
			BundleID:       "0x01",
			DockerDigest:   "sha256:good",
			TEEMeasurement: "tee",
			ReplaySalt:     "0x02",
			Status:         "ok",
		}
		if callCount > 1 {
			resp.BundleID = "0x03"
		}
		json.NewEncoder(w).Encode(resp)
	}))
	defer matcher.Close()

	verifier := &Verifier{
		cfg: Config{
			MatcherEndpoint:     matcher.URL,
			AllowedDigests:      map[string]struct{}{"sha256:good": {}},
			AllowedMeasurements: map[string]struct{}{"tee": {}},
		},
		client:    matcher.Client(),
		seenSalts: make(map[string]struct{}),
	}

	if err := verifier.checkOnce(); err != nil {
		t.Fatalf("first checkOnce failed: %v", err)
	}
	if err := verifier.checkOnce(); err != ErrReplaySaltSeen {
		t.Fatalf("expected ErrReplaySaltSeen, got %v", err)
	}
	if callCount != 2 {
		t.Fatalf("expected matcher called twice, got %d", callCount)
	}
}
