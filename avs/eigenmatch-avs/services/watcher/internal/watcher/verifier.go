package watcher

import (
	"crypto/ecdsa"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"math/big"
	"net/http"
	"strings"
	"time"

	"github.com/ethereum/go-ethereum/accounts"
	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/crypto"
)

var (
	ErrDigestMismatch      = errors.New("docker digest not allowed")
	ErrMeasurementMismatch = errors.New("tee measurement not allowed")
	ErrReplaySaltSeen      = errors.New("replay salt already processed")
)

type Config struct {
	MatcherEndpoint     string
	AllowedDigests      map[string]struct{}
	AllowedMeasurements map[string]struct{}
	PollInterval        time.Duration
	ExecutorEndpoint    string
	PoolID              string
	ExecutorContract    string
	ExecutorChainID     uint64
	WatcherPrivateKey   string
}

type Verifier struct {
	cfg        Config
	client     *http.Client
	lastBundle string
	executor   *ExecutorClient
	signer     *ecdsa.PrivateKey
	watcher    common.Address
	execAddr   common.Address
	seenSalts  map[string]struct{}
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

var watcherTypeHash = crypto.Keccak256Hash([]byte("EigenMatchBundle(bytes32 bundleId, bytes32 replaySalt, uint256 chainId, address executor)"))

func New(cfg Config) (*Verifier, error) {
	if cfg.MatcherEndpoint == "" {
		cfg.MatcherEndpoint = "http://localhost:8080"
	}
	if cfg.PollInterval == 0 {
		cfg.PollInterval = 5 * time.Second
	}
	v := &Verifier{
		cfg:       cfg,
		client:    &http.Client{Timeout: 5 * time.Second},
		seenSalts: make(map[string]struct{}),
	}
	if cfg.ExecutorEndpoint != "" {
		if cfg.PoolID == "" {
			return nil, errors.New("POOL_ID required when EXECUTOR_ENDPOINT is set")
		}
		if cfg.ExecutorContract == "" {
			return nil, errors.New("EXECUTOR_CONTRACT required when EXECUTOR_ENDPOINT is set")
		}
		if cfg.ExecutorChainID == 0 {
			return nil, errors.New("EXECUTOR_CHAIN_ID required when EXECUTOR_ENDPOINT is set")
		}
		if cfg.WatcherPrivateKey == "" {
			return nil, errors.New("WATCHER_PRIVATE_KEY required when EXECUTOR_ENDPOINT is set")
		}

		key, err := crypto.HexToECDSA(strings.TrimPrefix(cfg.WatcherPrivateKey, "0x"))
		if err != nil {
			return nil, fmt.Errorf("parse watcher private key: %w", err)
		}

		v.executor = NewExecutorClient(cfg.ExecutorEndpoint)
		v.signer = key
		v.watcher = crypto.PubkeyToAddress(key.PublicKey)
		v.execAddr = common.HexToAddress(cfg.ExecutorContract)
	}
	return v, nil
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

	replayKey := strings.ToLower(bundle.ReplaySalt)
	if replayKey == "" {
		return fmt.Errorf("bundle missing replay_salt")
	}
	if _, seen := v.seenSalts[replayKey]; seen {
		return ErrReplaySaltSeen
	}

	if _, ok := v.cfg.AllowedDigests[strings.ToLower(bundle.DockerDigest)]; !ok {
		return ErrDigestMismatch
	}
	if _, ok := v.cfg.AllowedMeasurements[strings.ToLower(bundle.TEEMeasurement)]; !ok {
		return ErrMeasurementMismatch
	}

	v.lastBundle = bundle.BundleID
	v.seenSalts[replayKey] = struct{}{}
	log.Printf("[watcher] bundle verified: id=%s epoch=%d\n", bundle.BundleID, bundle.Epoch)

	if v.executor != nil {
		if err := v.submitToExecutor(bundle); err != nil {
			return err
		}
	}
	return nil
}

func (v *Verifier) submitToExecutor(bundle bundleResponse) error {
	signature, err := v.signBundle(bundle)
	if err != nil {
		return fmt.Errorf("sign bundle: %w", err)
	}

	payload := ExecutorPayload{
		PoolID:           v.cfg.PoolID,
		Bundle:           bundle,
		WatcherAddress:   v.watcher.Hex(),
		Signature:        signature,
		ChainID:          v.cfg.ExecutorChainID,
		ExecutorContract: v.cfg.ExecutorContract,
	}

	if err := v.executor.Submit(payload); err != nil {
		return fmt.Errorf("executor submit: %w", err)
	}
	return nil
}

func (v *Verifier) signBundle(bundle bundleResponse) (string, error) {
	if v.signer == nil {
		return "", errors.New("signer not configured")
	}
	digest, err := v.bundleDigest(bundle)
	if err != nil {
		return "", err
	}
	sig, err := crypto.Sign(digest.Bytes(), v.signer)
	if err != nil {
		return "", err
	}
	if sig[64] < 27 {
		sig[64] += 27
	}
	return "0x" + hex.EncodeToString(sig), nil
}

func (v *Verifier) bundleDigest(bundle bundleResponse) (common.Hash, error) {
	bundleID, err := toHash(bundle.BundleID)
	if err != nil {
		return common.Hash{}, fmt.Errorf("bundleId: %w", err)
	}
	replaySalt, err := toHash(bundle.ReplaySalt)
	if err != nil {
		return common.Hash{}, fmt.Errorf("replaySalt: %w", err)
	}

	encoded := make([]byte, 0, 32*4)
	encoded = append(encoded, watcherTypeHash.Bytes()...)
	encoded = append(encoded, bundleID.Bytes()...)
	encoded = append(encoded, replaySalt.Bytes()...)
	encoded = append(encoded, uintToBytes32(v.cfg.ExecutorChainID)...)
	encoded = append(encoded, padAddress(v.execAddr)...)

	structHash := crypto.Keccak256Hash(encoded)
	return common.BytesToHash(accounts.TextHash(structHash.Bytes())), nil
}

func toHash(input string) (common.Hash, error) {
	s := strings.TrimPrefix(input, "0x")
	bytesLen := len(s) / 2
	if bytesLen > 32 {
		return common.Hash{}, fmt.Errorf("value %s exceeds 32 bytes", input)
	}
	buf, err := hex.DecodeString(s)
	if err != nil {
		return common.Hash{}, err
	}
	var out common.Hash
	copy(out[32-len(buf):], buf)
	return out, nil
}

func uintToBytes32(value uint64) []byte {
	out := make([]byte, 32)
	new(big.Int).SetUint64(value).FillBytes(out)
	return out
}

func padAddress(addr common.Address) []byte {
	out := make([]byte, 32)
	copy(out[12:], addr.Bytes())
	return out
}
