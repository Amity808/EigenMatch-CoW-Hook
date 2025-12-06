package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"os"
	"strings"
	"sync"
	"time"

	"github.com/Layr-Labs/hourglass-avs-template/contracts/bindings/l1/taskavsregistrar"
	"github.com/Layr-Labs/hourglass-monorepo/ponos/pkg/performer/contracts"
	"github.com/Layr-Labs/hourglass-monorepo/ponos/pkg/performer/server"
	performerV1 "github.com/Layr-Labs/protocol-apis/gen/protos/eigenlayer/hourglass/v1/performer"
	"github.com/ethereum/go-ethereum/ethclient"
	"go.uber.org/zap"
)

// This offchain binary is run by Operators running the Hourglass Executor. It contains
// the business logic of the AVS and performs worked based on the tasked sent to it.
// The Hourglass Aggregator ingests tasks from the TaskMailbox and distributes work
// to Executors configured to run the AVS Performer. Performers execute the work and
// return the result to the Executor where the result is signed and return to the
// Aggregator to place in the outbox once the signing threshold is met.

type TaskWorker struct {
	logger        *zap.Logger
	contractStore *contracts.ContractStore
	l1Client      *ethclient.Client
	l2Client      *ethclient.Client
	allowedDigest map[string]struct{}
	allowedTEE    map[string]struct{}
	maxBundleAge  time.Duration
	replayCache   sync.Map
	matcher       matcherVerifier
}

type matcherVerifier interface {
	Verify(ctx context.Context, bundle SettlementBundleTask, payloadHash string) error
}

func NewTaskWorker(logger *zap.Logger) *TaskWorker {
	// Initialize contract store from environment variables
	contractStore, err := contracts.NewContractStore()
	if err != nil {
		logger.Warn("Failed to load contract store", zap.Error(err))
	}

	// Initialize Ethereum clients if RPC URLs are provided
	var l1Client, l2Client *ethclient.Client

	if l1RpcUrl := os.Getenv("L1_RPC_URL"); l1RpcUrl != "" {
		l1Client, err = ethclient.Dial(l1RpcUrl)
		if err != nil {
			logger.Error("Failed to connect to L1 RPC", zap.Error(err))
		}
	}

	if l2RpcUrl := os.Getenv("L2_RPC_URL"); l2RpcUrl != "" {
		l2Client, err = ethclient.Dial(l2RpcUrl)
		if err != nil {
			logger.Error("Failed to connect to L2 RPC", zap.Error(err))
		}
	}

	allowedDigest := toSet(os.Getenv("ALLOWED_DOCKER_DIGESTS"))
	allowedTEE := toSet(os.Getenv("ALLOWED_TEE_MEASUREMENTS"))

	maxAge := 90 * time.Second
	if override := os.Getenv("MAX_BUNDLE_AGE_SECONDS"); override != "" {
		if parsed, errConv := time.ParseDuration(fmt.Sprintf("%ss", override)); errConv == nil {
			maxAge = parsed
		}
	}

	var matcher matcherVerifier = noopMatcher{}
	if endpoint := strings.TrimSpace(os.Getenv("MATCHER_ENDPOINT")); endpoint != "" {
		matcher = &httpMatcherVerifier{
			endpoint: strings.TrimRight(endpoint, "/"),
			client: &http.Client{
				Timeout: 10 * time.Second,
			},
		}
	}

	return &TaskWorker{
		logger:        logger,
		contractStore: contractStore,
		l1Client:      l1Client,
		l2Client:      l2Client,
		allowedDigest: allowedDigest,
		allowedTEE:    allowedTEE,
		maxBundleAge:  maxAge,
		matcher:       matcher,
	}
}

func (tw *TaskWorker) ValidateTask(t *performerV1.TaskRequest) error {
	bundle, payloadHash, err := decodeBundle(t.Payload)
	if err != nil {
		return err
	}

	if _, ok := tw.allowedDigest[strings.ToLower(bundle.DockerDigest)]; !ok && len(tw.allowedDigest) > 0 {
		return fmt.Errorf("docker digest %s not allowlisted", bundle.DockerDigest)
	}
	if _, ok := tw.allowedTEE[strings.ToLower(bundle.TEEMeasurement)]; !ok && len(tw.allowedTEE) > 0 {
		return fmt.Errorf("TEE measurement %s not allowlisted", bundle.TEEMeasurement)
	}
	if time.Since(bundle.MatchTime()) > tw.maxBundleAge {
		return fmt.Errorf("bundle %s expired", bundle.BundleID)
	}
	if bundle.ReplaySalt == "" {
		return errors.New("bundle missing replaySalt")
	}
	if _, loaded := tw.replayCache.LoadOrStore(bundle.ReplaySalt, struct{}{}); loaded {
		return fmt.Errorf("bundle %s replayed (salt %s)", bundle.BundleID, bundle.ReplaySalt)
	}
	if len(bundle.MatchGroups) == 0 {
		return fmt.Errorf("bundle %s missing match_groups", bundle.BundleID)
	}
	for idx, group := range bundle.MatchGroups {
		if len(group.IntentIDs) < 2 {
			return fmt.Errorf("bundle %s match_group[%d] has <2 intents", bundle.BundleID, idx)
		}
		if strings.TrimSpace(group.ClearingPrice) == "" || strings.TrimSpace(group.MatchedAmount) == "" {
			return fmt.Errorf("bundle %s match_group[%d] missing clearing data", bundle.BundleID, idx)
		}
	}

	tw.logger.Info("validated bundle",
		zap.String("bundleId", bundle.BundleID),
		zap.String("hash", payloadHash),
		zap.Int("matchGroupCount", len(bundle.MatchGroups)),
	)
	return nil
}

func (tw *TaskWorker) HandleTask(t *performerV1.TaskRequest) (*performerV1.TaskResponse, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()

	bundle, payloadHash, err := decodeBundle(t.Payload)
	if err != nil {
		return nil, err
	}

	if err := tw.matcher.Verify(ctx, bundle, payloadHash); err != nil {
		return nil, fmt.Errorf("matcher verification failed: %w", err)
	}

	// The following section shows how contract bindings can still be used for telemetry
	if tw.contractStore != nil {
		if taskRegistrarAddr, err := tw.contractStore.GetTaskAVSRegistrar(); err == nil {
			if tw.l1Client != nil {
				if registrar, err := taskavsregistrar.NewTaskAVSRegistrar(taskRegistrarAddr, tw.l1Client); err == nil {
					_ = registrar // placeholder for future slashable logic
				}
			}
		}
	}

	result := &performerV1.TaskResponse{
		TaskId: t.TaskId,
		Result: []byte(payloadHash),
	}
	tw.logger.Info("bundle verified",
		zap.String("bundleId", bundle.BundleID),
		zap.String("hash", payloadHash),
		zap.String("proofUri", bundle.AttestationURI),
	)
	return result, nil
}

type SettlementBundleTask struct {
	BundleID       string       `json:"bundle_id"`
	DockerDigest   string       `json:"docker_digest"`
	TEEMeasurement string       `json:"tee_measurement"`
	ReplaySalt     string       `json:"replay_salt"`
	Epoch          uint64       `json:"epoch"`
	GeneratedAt    time.Time    `json:"generated_at"`
	AttestationURI string       `json:"attestation_uri"`
	MatchGroups    []MatchGroup `json:"match_groups"`
}

type MatchGroup struct {
	IntentIDs     []string `json:"intent_ids"`
	ClearingPrice string   `json:"clearing_price"`
	MatchedAmount string   `json:"matched_amount"`
	FeesSavedBps  uint32   `json:"fees_saved_bps"`
}

func (s SettlementBundleTask) MatchTime() time.Time {
	if !s.GeneratedAt.IsZero() {
		return s.GeneratedAt.UTC()
	}
	if s.Epoch == 0 {
		return time.Time{}
	}
	return time.Unix(int64(s.Epoch), 0).UTC()
}

func decodeBundle(payload []byte) (SettlementBundleTask, string, error) {
	var bundle SettlementBundleTask
	if err := json.Unmarshal(payload, &bundle); err != nil {
		return SettlementBundleTask{}, "", fmt.Errorf("unable to decode bundle payload: %w", err)
	}
	if bundle.BundleID == "" {
		return SettlementBundleTask{}, "", errors.New("bundleId missing")
	}
	hash := sha256.Sum256(payload)
	payloadHash := hex.EncodeToString(hash[:])
	canonicalID, err := canonicalBundleID(bundle)
	if err != nil {
		return SettlementBundleTask{}, "", fmt.Errorf("compute canonical bundleId: %w", err)
	}
	if !strings.EqualFold(bundle.BundleID, canonicalID) {
		return SettlementBundleTask{}, "", fmt.Errorf("bundleId mismatch (%s != %s)", bundle.BundleID, canonicalID)
	}
	return bundle, payloadHash, nil
}

func hashFromBundle(bundle SettlementBundleTask) (string, error) {
	payload, err := json.Marshal(bundle)
	if err != nil {
		return "", err
	}
	sum := sha256.Sum256(payload)
	return hex.EncodeToString(sum[:]), nil
}

func canonicalBundleID(bundle SettlementBundleTask) (string, error) {
	copy := bundle
	copy.BundleID = ""
	return hashFromBundle(copy)
}

type noopMatcher struct{}

func (noopMatcher) Verify(context.Context, SettlementBundleTask, string) error { return nil }

type httpMatcherVerifier struct {
	endpoint string
	client   *http.Client
}

func (h *httpMatcherVerifier) Verify(ctx context.Context, bundle SettlementBundleTask, payloadHash string) error {
	url := h.endpoint
	if !strings.HasSuffix(url, "/bundles/latest") {
		url = url + "/bundles/latest"
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return err
	}

	resp, err := h.client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("matcher endpoint returned %s", resp.Status)
	}

	var latest SettlementBundleTask
	if err := json.NewDecoder(resp.Body).Decode(&latest); err != nil {
		return fmt.Errorf("decode matcher response: %w", err)
	}
	if latest.BundleID == "" {
		return errors.New("matcher has not produced any bundles yet")
	}
	if !strings.EqualFold(latest.BundleID, bundle.BundleID) {
		return fmt.Errorf("bundleId mismatch (%s != %s)", latest.BundleID, bundle.BundleID)
	}
	canonicalHash, err := hashFromBundle(latest)
	if err != nil {
		return fmt.Errorf("compute canonical hash: %w", err)
	}
	if !strings.EqualFold(canonicalHash, payloadHash) {
		return fmt.Errorf("bundle hash mismatch (%s != %s)", canonicalHash, payloadHash)
	}
	return nil
}

func toSet(raw string) map[string]struct{} {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return nil
	}
	res := make(map[string]struct{})
	for _, item := range strings.Split(raw, ",") {
		item = strings.ToLower(strings.TrimSpace(item))
		if item != "" {
			res[item] = struct{}{}
		}
	}
	return res
}

func main() {
	ctx := context.Background()
	l, _ := zap.NewProduction()

	w := NewTaskWorker(l)

	pp, err := server.NewPonosPerformerWithRpcServer(&server.PonosPerformerConfig{
		Port:    8080,
		Timeout: 5 * time.Second,
	}, w, l)
	if err != nil {
		panic(fmt.Errorf("failed to create performer: %w", err))
	}

	if err := pp.Start(ctx); err != nil {
		panic(err)
	}
}
