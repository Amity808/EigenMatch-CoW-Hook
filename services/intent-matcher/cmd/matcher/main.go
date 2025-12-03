package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"strconv"
	"time"

	"github.com/shopspring/decimal"

	"github.com/Amity808/EigenMatch-CoW-Hook/services/intent-matcher/internal/matcher"
)

func main() {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	cfg := matcher.Config{
		EpochSeconds:   getEnvInt("MATCH_EPOCH_SECONDS", 5),
		DockerDigest:   os.Getenv("MATCHER_DOCKER_DIGEST"),
		TEEMeasurement: os.Getenv("MATCHER_TEE_MEASUREMENT"),
	}
	m := matcher.New(cfg)
	m.Start(ctx)

	addr := getEnv("API_PORT_PUBLIC", ":8080")
	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, map[string]any{
			"status": "ok",
			"epoch":  time.Now().Unix(),
		})
	})

	mux.HandleFunc("/intents", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}

		var payload struct {
			IntentID   string `json:"intent_id"`
			Trader     string `json:"trader"`
			Pair       string `json:"pair"`
			Side       string `json:"side"`
			Amount     string `json:"amount"`
			LimitPrice string `json:"limit_price"`
			Expiry     int64  `json:"expiry"`
			Nonce      uint64 `json:"nonce"`
			Signature  string `json:"signature"`
		}
		if err := json.NewDecoder(r.Body).Decode(&payload); err != nil {
			http.Error(w, "invalid JSON", http.StatusBadRequest)
			return
		}

		amount, err := decimal.NewFromString(payload.Amount)
		if err != nil {
			http.Error(w, "invalid amount", http.StatusBadRequest)
			return
		}
		limit, err := decimal.NewFromString(payload.LimitPrice)
		if err != nil {
			http.Error(w, "invalid limit price", http.StatusBadRequest)
			return
		}

		intent := matcher.Intent{
			IntentID:   payload.IntentID,
			Trader:     payload.Trader,
			Pair:       payload.Pair,
			Side:       payload.Side,
			Amount:     amount,
			LimitPrice: limit,
			Expiry:     time.Unix(payload.Expiry, 0),
			Nonce:      payload.Nonce,
			Signature:  payload.Signature,
		}

		if err := m.SubmitIntent(intent); err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}

		writeJSON(w, map[string]string{"status": "ACCEPTED"})
	})

	mux.HandleFunc("/bundles/latest", func(w http.ResponseWriter, r *http.Request) {
		bundle := m.LatestBundle()
		if bundle.BundleID == "" {
			writeJSON(w, map[string]string{"status": "NO_BUNDLE"})
			return
		}
		writeJSON(w, bundle)
	})

	log.Printf("intent matcher listening on %s (epoch %ds)\n", addr, cfg.EpochSeconds)
	if err := http.ListenAndServe(addr, mux); err != nil {
		log.Fatalf("server failed: %v", err)
	}
}

func getEnv(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

func getEnvInt(key string, def int) int {
	if v := os.Getenv(key); v != "" {
		if parsed, err := strconv.Atoi(v); err == nil {
			return parsed
		}
	}
	return def
}

func writeJSON(w http.ResponseWriter, v any) {
	w.Header().Set("Content-Type", "application/json")
	if err := json.NewEncoder(w).Encode(v); err != nil {
		http.Error(w, fmt.Sprintf("encode error: %v", err), http.StatusInternalServerError)
	}
}
