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

func (c *ExecutorClient) Submit(bundle bundleResponse) error {
	body, err := json.Marshal(bundle)
	if err != nil {
		return fmt.Errorf("marshal bundle: %w", err)
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
