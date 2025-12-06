package main

import (
	"encoding/json"
	"os"
	"testing"
	"time"

	performerV1 "github.com/Layr-Labs/protocol-apis/gen/protos/eigenlayer/hourglass/v1/performer"
	"go.uber.org/zap"
)

func Test_TaskRequestPayload(t *testing.T) {
	// ------------------------------------------------------------------------
	// Write your test cases here
	// ------------------------------------------------------------------------

	_ = os.Setenv("ALLOWED_DOCKER_DIGESTS", "digest-1")
	_ = os.Setenv("ALLOWED_TEE_MEASUREMENTS", "tee-1")
	_ = os.Unsetenv("MATCHER_ENDPOINT")

	logger, err := zap.NewDevelopment()
	if err != nil {
		t.Errorf("Failed to create logger: %v", err)
	}

	taskWorker := NewTaskWorker(logger)

	now := time.Now().UTC()
	bundle := SettlementBundleTask{
		BundleID:       "bundle-1",
		DockerDigest:   "digest-1",
		TEEMeasurement: "tee-1",
		ReplaySalt:     "salt-1",
		Epoch:          uint64(now.Unix()),
		GeneratedAt:    now,
		MatchGroups: []MatchGroup{
			{
				IntentIDs:     []string{"intent-a", "intent-b"},
				ClearingPrice: "2000",
				MatchedAmount: "5",
				FeesSavedBps:  80,
			},
		},
	}
	canonicalID, err := canonicalBundleID(bundle)
	if err != nil {
		t.Fatalf("compute canonical bundle id: %v", err)
	}
	bundle.BundleID = canonicalID
	payload, _ := json.Marshal(bundle)

	taskRequest := &performerV1.TaskRequest{
		TaskId:  []byte("test-task-id"),
		Payload: payload,
	}
	err = taskWorker.ValidateTask(taskRequest)
	if err != nil {
		t.Errorf("ValidateTask failed: %v", err)
	}

	resp, err := taskWorker.HandleTask(taskRequest)
	if err != nil {
		t.Errorf("HandleTask failed: %v", err)
	}

	if len(resp.Result) == 0 {
		t.Fatalf("expected response hash, got empty result")
	}

	// Ensure replay protection trips on the same salt
	if err := taskWorker.ValidateTask(taskRequest); err == nil {
		t.Fatalf("expected replay validation failure")
	}
}
