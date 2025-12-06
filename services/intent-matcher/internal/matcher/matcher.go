package matcher

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"sync"
	"time"

	"github.com/shopspring/decimal"
)

var (
	ErrInvalidIntent = errors.New("invalid intent")
)

type Intent struct {
	IntentID   string          `json:"intent_id"`
	Trader     string          `json:"trader"`
	Pair       string          `json:"pair"`
	Side       string          `json:"side"` // BUY or SELL
	Amount     decimal.Decimal `json:"amount"`
	LimitPrice decimal.Decimal `json:"limit_price"`
	Expiry     time.Time       `json:"expiry"`
	Nonce      uint64          `json:"nonce"`
	Signature  string          `json:"signature"`
}

type MatchGroup struct {
	IntentIDs     []string `json:"intent_ids"`
	ClearingPrice string   `json:"clearing_price"`
	MatchedAmount string   `json:"matched_amount"`
	FeesSavedBps  uint32   `json:"fees_saved_bps"`
}

type SettlementBundle struct {
	Epoch          uint64       `json:"epoch"`
	BundleID       string       `json:"bundle_id"`
	DockerDigest   string       `json:"docker_digest"`
	TEEMeasurement string       `json:"tee_measurement"`
	ReplaySalt     string       `json:"replay_salt"`
	MatchGroups    []MatchGroup `json:"match_groups"`
	GeneratedAt    time.Time    `json:"generated_at"`
}

type Config struct {
	EpochSeconds   int
	DockerDigest   string
	TEEMeasurement string
}

type Matcher struct {
	cfg Config

	mu      sync.Mutex
	intents map[string][]*Intent // pair -> intents

	bundleMu     sync.RWMutex
	latestBundle SettlementBundle
	started      bool

	scorer Scorer
}

func New(cfg Config, opts ...Option) *Matcher {
	if cfg.EpochSeconds == 0 {
		cfg.EpochSeconds = 5
	}
	m := &Matcher{
		cfg:     cfg,
		intents: make(map[string][]*Intent),
	}
	for _, opt := range opts {
		opt(m)
	}
	return m
}

func (m *Matcher) Start(ctx context.Context) {
	m.mu.Lock()
	if m.started {
		m.mu.Unlock()
		return
	}
	m.started = true
	m.mu.Unlock()

	go m.loop(ctx)
}

func (m *Matcher) loop(ctx context.Context) {
	ticker := time.NewTicker(time.Duration(m.cfg.EpochSeconds) * time.Second)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return
		case t := <-ticker.C:
			bundle := m.matchEpoch(t)
			if bundle != nil {
				m.bundleMu.Lock()
				m.latestBundle = *bundle
				m.bundleMu.Unlock()
			}
		}
	}
}

func (m *Matcher) SubmitIntent(intent Intent) error {
	if intent.IntentID == "" || intent.Trader == "" || intent.Pair == "" {
		return ErrInvalidIntent
	}
	side := intent.Side
	if side != "BUY" && side != "SELL" {
		return ErrInvalidIntent
	}

	if m.scorer != nil {
		if err := m.scorer.Score(context.Background(), &intent); err != nil {
			return err
		}
	}

	m.mu.Lock()
	defer m.mu.Unlock()
	cpy := intent // copy
	m.intents[intent.Pair] = append(m.intents[intent.Pair], &cpy)
	return nil
}

func (m *Matcher) LatestBundle() SettlementBundle {
	m.bundleMu.RLock()
	defer m.bundleMu.RUnlock()
	return m.latestBundle
}

func (m *Matcher) matchEpoch(now time.Time) *SettlementBundle {
	m.mu.Lock()
	defer m.mu.Unlock()

	if len(m.intents) == 0 {
		return nil
	}

	epoch := uint64(now.Unix())
	var matchGroups []MatchGroup

	for pair, intents := range m.intents {
		var buys []*Intent
		var sells []*Intent
		var remaining []*Intent
		for _, in := range intents {
			if in.Expiry.Before(now) {
				continue
			}
			if in.Side == "BUY" {
				buys = append(buys, in)
			} else {
				sells = append(sells, in)
			}
		}

		// simple deterministic ordering
		sortIntents(buys, true)
		sortIntents(sells, false)

		i, j := 0, 0
		for i < len(buys) && j < len(sells) {
			buy := buys[i]
			sell := sells[j]

			if buy.LimitPrice.LessThan(sell.LimitPrice) {
				// No price overlap
				break
			}

			matchAmount := minDecimal(buy.Amount, sell.Amount)
			if matchAmount.IsZero() {
				break
			}

			clearing := buy.LimitPrice.Add(sell.LimitPrice).Div(decimal.NewFromInt(2))
			matchGroups = append(matchGroups, MatchGroup{
				IntentIDs:     []string{buy.IntentID, sell.IntentID},
				ClearingPrice: clearing.String(),
				MatchedAmount: matchAmount.String(),
				FeesSavedBps:  80,
			})

			buy.Amount = buy.Amount.Sub(matchAmount)
			sell.Amount = sell.Amount.Sub(matchAmount)

			if buy.Amount.IsZero() {
				i++
			}
			if sell.Amount.IsZero() {
				j++
			}
		}

		// collect remaining intents for next epoch
		remaining = remaining[:0]
		for _, in := range append(buys[i:], sells[j:]...) {
			if in.Amount.GreaterThan(decimal.Zero) {
				remaining = append(remaining, in)
			}
		}
		if len(remaining) > 0 {
			m.intents[pair] = remaining
		} else {
			delete(m.intents, pair)
		}
	}

	if len(matchGroups) == 0 {
		return nil
	}

	bundle := SettlementBundle{
		Epoch:          epoch,
		MatchGroups:    matchGroups,
		DockerDigest:   m.cfg.DockerDigest,
		TEEMeasurement: m.cfg.TEEMeasurement,
		ReplaySalt:     randomSalt(),
		GeneratedAt:    now.UTC(),
	}
	bundle.BundleID = bundle.computeID()
	return &bundle
}

func (b *SettlementBundle) computeID() string {
	payload, _ := json.Marshal(b)
	sum := sha256.Sum256(payload)
	return hex.EncodeToString(sum[:])
}

func randomSalt() string {
	buf := make([]byte, 32)
	_, _ = rand.Read(buf)
	return hex.EncodeToString(buf)
}

func sortIntents(intents []*Intent, buy bool) {
	less := func(i, j int) bool {
		if buy {
			if intents[i].LimitPrice.Equal(intents[j].LimitPrice) {
				return intents[i].Nonce < intents[j].Nonce
			}
			return intents[i].LimitPrice.GreaterThan(intents[j].LimitPrice)
		}
		if intents[i].LimitPrice.Equal(intents[j].LimitPrice) {
			return intents[i].Nonce < intents[j].Nonce
		}
		return intents[i].LimitPrice.LessThan(intents[j].LimitPrice)
	}
	for i := 1; i < len(intents); i++ {
		for j := i; j > 0 && less(j, j-1); j-- {
			intents[j], intents[j-1] = intents[j-1], intents[j]
		}
	}
}

func minDecimal(a, b decimal.Decimal) decimal.Decimal {
	if a.LessThan(b) {
		return a
	}
	return b
}
