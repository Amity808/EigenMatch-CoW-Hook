package main

import (
	"log"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/Amity808/EigenMatch-CoW-Hook/services/watcher/internal/watcher"
)

func main() {
	cfg := watcher.Config{
		MatcherEndpoint:     getEnv("MATCHER_ENDPOINT", "http://localhost:8080"),
		AllowedDigests:      toSet(os.Getenv("ALLOWED_DOCKER_DIGESTS")),
		AllowedMeasurements: toSet(os.Getenv("ALLOWED_TEE_MEASUREMENTS")),
		PollInterval:        time.Duration(getEnvInt("POLL_INTERVAL_SECONDS", 5)) * time.Second,
		ExecutorEndpoint:    os.Getenv("EXECUTOR_ENDPOINT"),
		PoolID:              os.Getenv("POOL_ID"),
		ExecutorContract:    os.Getenv("EXECUTOR_CONTRACT"),
		ExecutorChainID:     getEnvUint64("EXECUTOR_CHAIN_ID"),
		WatcherPrivateKey:   os.Getenv("WATCHER_PRIVATE_KEY"),
	}

	if len(cfg.AllowedDigests) == 0 {
		log.Fatal("ALLOWED_DOCKER_DIGESTS must be set")
	}
	if len(cfg.AllowedMeasurements) == 0 {
		log.Fatal("ALLOWED_TEE_MEASUREMENTS must be set")
	}

	verifier, err := watcher.New(cfg)
	if err != nil {
		log.Fatalf("failed to init watcher: %v", err)
	}
	log.Printf("[watcher] starting; matcher=%s interval=%s\n", cfg.MatcherEndpoint, cfg.PollInterval)

	stop := make(chan struct{})
	defer close(stop)
	verifier.Run(stop)
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

func getEnvUint64(key string) uint64 {
	if v := os.Getenv(key); v != "" {
		if parsed, err := strconv.ParseUint(v, 10, 64); err == nil {
			return parsed
		}
	}
	return 0
}

func toSet(csv string) map[string]struct{} {
	set := make(map[string]struct{})
	for _, item := range strings.Split(csv, ",") {
		trim := strings.ToLower(strings.TrimSpace(item))
		if trim != "" {
			set[trim] = struct{}{}
		}
	}
	return set
}
