package watcher

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net/http"
	"time"
)

type ExecutorClient struct {
	endpoint string
	client   *http.Client
}

func NewExecutorClient(endpoint string) *ExecutorClient {
	return &ExecutorClient{
		endpoint: endpoint,
		client:   &http.Client{Timeout: 5 * time.Second},
	}
}

type ExecutorPayload struct {
	PoolID           string         `json:"pool_id"`
	Bundle           bundleResponse `json:"bundle"`
	WatcherAddress   string         `json:"watcher_address"`
	Signature        string         `json:"signature"`
	ChainID          uint64         `json:"chain_id"`
	ExecutorContract string         `json:"executor_contract"`
}

func (c *ExecutorClient) Submit(payload ExecutorPayload) error {
	body, err := json.Marshal(payload)
	if err != nil {
		return fmt.Errorf("marshal payload: %w", err)
	}

	resp, err := c.client.Post(c.endpoint, "application/json", bytes.NewReader(body))
	if err != nil {
		return fmt.Errorf("post executor: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode >= 300 {
		return fmt.Errorf("executor returned %s", resp.Status)
	}
	return nil
}
