package watcher

import (
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net/http"
	"strings"
	"time"
)

var (
	ErrDigestMismatch      = errors.New("docker digest not allowed")
	ErrMeasurementMismatch = errors.New("tee measurement not allowed")
)

type Config struct {
	MatcherEndpoint     string
	AllowedDigests      map[string]struct{}
	AllowedMeasurements map[string]struct{}
	PollInterval        time.Duration
}

type Verifier struct {
	cfg        Config
	client     *http.Client
	lastBundle string
}

type bundleResponse struct {
	Status         string          `json:"status"`
	Epoch          uint64          `json:"epoch"`
	BundleID       string          `json:"bundle_id"`
	DockerDigest   string          `json:"docker_digest"`
	TEEMeasurement string          `json:"tee_measurement"`
	ReplaySalt     string          `json:"replay_salt"`
	MatchGroups    json.RawMessage `json:"match_groups"`
}

func New(cfg Config) *Verifier {
	if cfg.MatcherEndpoint == "" {
		cfg.MatcherEndpoint = "http://localhost:8080"
	}
	if cfg.PollInterval == 0 {
		cfg.PollInterval = 5 * time.Second
	}
	return &Verifier{
		cfg:    cfg,
		client: &http.Client{Timeout: 5 * time.Second},
	}
}

func (v *Verifier) Run(stop <-chan struct{}) {
	ticker := time.NewTicker(v.cfg.PollInterval)
	defer ticker.Stop()

	for {
		select {
		case <-stop:
			return
		case <-ticker.C:
			if err := v.checkOnce(); err != nil {
				log.Printf("[watcher] check failed: %v\n", err)
			}
		}
	}
}

func (v *Verifier) checkOnce() error {
	resp, err := v.client.Get(v.cfg.MatcherEndpoint + "/bundles/latest")
	if err != nil {
		return fmt.Errorf("fetch bundle: %w", err)
	}
	defer resp.Body.Close()

	var bundle bundleResponse
	if err := json.NewDecoder(resp.Body).Decode(&bundle); err != nil {
		return fmt.Errorf("decode bundle: %w", err)
	}

	if bundle.BundleID == "" {
		log.Println("[watcher] no bundle available yet")
		return nil
	}
	if bundle.BundleID == v.lastBundle {
		return nil
	}

	if _, ok := v.cfg.AllowedDigests[strings.ToLower(bundle.DockerDigest)]; !ok {
		return ErrDigestMismatch
	}
	if _, ok := v.cfg.AllowedMeasurements[strings.ToLower(bundle.TEEMeasurement)]; !ok {
		return ErrMeasurementMismatch
	}

	v.lastBundle = bundle.BundleID
	log.Printf("[watcher] bundle verified: id=%s epoch=%d\n", bundle.BundleID, bundle.Epoch)
	return nil
}
