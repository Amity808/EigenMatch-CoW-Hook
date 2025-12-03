# EigenMatch Watcher Service

This service monitors EigenCompute settlement bundles, validates their attestation metadata, and (later) relays approved bundles to the settlement executor. It follows the telemetry plan described in `docs/system-design.md` and the privacy/trust boundaries defined in `context/eigencloud-docs/docs/eigencompute/concepts/*.md`.

## Responsibilities
1. **Bundle polling**: Fetch bundles from the EigenCompute matcher API (`/bundles/latest`).
2. **Attestation checks**: Ensure docker digest + TEE measurement match the allowlist configured via environment variables (respecting EigenCompute `_PUBLIC` disclosure rules).
3. **Replay protection**: Track last accepted bundle ID per epoch to avoid duplicates.
4. **Telemetry**: Emit structured logs/metrics for Grafana/alerting (“bundle verified”, “digest mismatch”, “epoch missed”).
5. **Future work**: Submit validated bundles to the settlement executor contract and record on-chain tx hashes for observer dashboards.

## Environment variables (`config/example.env`)

| Variable | Description |
| --- | --- |
| `MATCHER_ENDPOINT` | HTTP endpoint for the intent matcher (e.g. `https://matcher.eigenmatch.xyz`). |
| `ALLOWED_DOCKER_DIGESTS` | Comma-separated list of EigenCompute docker digests the hook trusts. |
| `ALLOWED_TEE_MEASUREMENTS` | Comma-separated list of TEE measurement hashes. |
| `POLL_INTERVAL_SECONDS` | How often to poll the matcher for new bundles (default 5s). |
| `EXECUTOR_ENDPOINT` | Optional HTTP endpoint for the settlement executor relay. When set, the watcher POSTs each verified bundle to this URL. |

Secrets (API tokens, etc.) should follow EigenCompute secret-handling rules: keep sensitive values without `_PUBLIC` suffix so they remain encrypted inside the TEE if deployed there.

## Usage
```bash
cd services/watcher
go run ./cmd/watcher
```

The binary logs bundle verification status and (optionally) relays each verified bundle to the settlement executor via `EXECUTOR_ENDPOINT`.

