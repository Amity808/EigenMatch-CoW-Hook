package matcher

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"time"

	"github.com/shopspring/decimal"
)

type Scorer interface {
	Score(ctx context.Context, intent *Intent) error
}

type Option func(*Matcher)

func WithScorer(s Scorer) Option {
	return func(m *Matcher) {
		m.scorer = s
	}
}

type EigenAIScorer struct {
	endpoint string
	client   *http.Client
}

type eigenAIScoreRequest struct {
	Intent Intent `json:"intent"`
}

type eigenAIScoreResponse struct {
	Approved           bool   `json:"approved"`
	AdjustedLimitPrice string `json:"adjusted_limit_price"`
	Reason             string `json:"reason"`
}

func NewEigenAIScorer(endpoint string) *EigenAIScorer {
	return &EigenAIScorer{
		endpoint: endpoint,
		client:   &http.Client{Timeout: 5 * time.Second},
	}
}

func (s *EigenAIScorer) Score(ctx context.Context, intent *Intent) error {
	if s == nil || s.endpoint == "" {
		return nil
	}

	payload, err := json.Marshal(eigenAIScoreRequest{Intent: *intent})
	if err != nil {
		return fmt.Errorf("marshal eigenai request: %w", err)
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, s.endpoint, bytes.NewReader(payload))
	if err != nil {
		return fmt.Errorf("build eigenai request: %w", err)
	}
	req.Header.Set("Content-Type", "application/json")

	resp, err := s.client.Do(req)
	if err != nil {
		return fmt.Errorf("call eigenai scorer: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode >= 300 {
		return fmt.Errorf("eigenai scorer returned %s", resp.Status)
	}

	var score eigenAIScoreResponse
	if err := json.NewDecoder(resp.Body).Decode(&score); err != nil {
		return fmt.Errorf("decode eigenai response: %w", err)
	}

	if !score.Approved {
		return fmt.Errorf("intent rejected by EigenAI: %s", score.Reason)
	}

	if score.AdjustedLimitPrice != "" {
		if newPrice, err := decimalFromString(score.AdjustedLimitPrice); err == nil {
			intent.LimitPrice = newPrice
		}
	}
	return nil
}

func decimalFromString(value string) (decimal.Decimal, error) {
	return decimal.NewFromString(value)
}
