package main

import (
	"fmt"
	"log"
	"net/http"
	"os"
	"time"
)

func main() {
	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprintf(w, `{"status":"ok","epoch":%d}`, time.Now().Unix())
	})

	addr := ":8080"
	if fromEnv := os.Getenv("API_PORT_PUBLIC"); fromEnv != "" {
		addr = fromEnv
	}

	log.Printf("intent matcher stub listening on %s\n", addr)
	if err := http.ListenAndServe(addr, mux); err != nil {
		log.Fatalf("server failed: %v", err)
	}
}

