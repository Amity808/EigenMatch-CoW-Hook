# EigenMatch Watcher Service

This service monitors EigenCompute settlement bundles, validates their attestation metadata, and (later) relays approved bundles to the settlement executor. It follows the telemetry plan described in `docs/system-design.md` and the privacy/trust boundaries defined in `context/eigencloud-docs/docs/eigencompute/concepts/*.md`.

## Responsibilities
1. **Bundle polling**: Fetch bundles from the EigenCompute matcher API (`/bundles/latest`).
2. **Attestation checks**: Ensure docker digest + TEE measurement match the allowlist configured via environment variables (respecting EigenCompute `_PUBLIC` disclosure rules).
3. **Replay protection**: Track last accepted bundle ID per epoch to avoid duplicates.
4. **Telemetry**: Emit structured logs/metrics for Grafana/alerting (“bundle verified”, “digest mismatch”, “epoch missed”).
5. **Settlement relay**: When `EXECUTOR_ENDPOINT` is configured the watcher signs each bundle (using the same digest defined in `EigenMatchSettlementExecutor`) and POSTs it to the executor relay so watcher signatures can be aggregated before calling the on-chain contract.

## Environment variables (`config/example.env`)

| Variable | Description |
| --- | --- |
| `MATCHER_ENDPOINT` | HTTP endpoint for the intent matcher (e.g. `https://matcher.eigenmatch.xyz`). |
| `ALLOWED_DOCKER_DIGESTS` | Comma-separated list of EigenCompute docker digests the hook trusts. |
| `ALLOWED_TEE_MEASUREMENTS` | Comma-separated list of TEE measurement hashes. |
| `POLL_INTERVAL_SECONDS` | How often to poll the matcher for new bundles (default 5s). |
| `EXECUTOR_ENDPOINT` | Optional HTTP endpoint for the settlement executor relay. When set, the watcher POSTs each verified bundle to this URL. |
| `POOL_ID` | `bytes32` pool identifier (hex) that the settlement bundle targets. Required when `EXECUTOR_ENDPOINT` is set. |
| `EXECUTOR_CONTRACT` | Address of the deployed `EigenMatchSettlementExecutor` contract. Required when `EXECUTOR_ENDPOINT` is set. |
| `EXECUTOR_CHAIN_ID` | Chain ID of the network hosting the executor contract. Required when `EXECUTOR_ENDPOINT` is set. |
| `WATCHER_PRIVATE_KEY` | Hex-encoded ECDSA key used to sign bundles. Required when `EXECUTOR_ENDPOINT` is set. |

Secrets (API tokens, etc.) should follow EigenCompute secret-handling rules: keep sensitive values without `_PUBLIC` suffix so they remain encrypted inside the TEE if deployed there.

## Usage
```bash
cd services/watcher
go run ./cmd/watcher
```

The binary logs bundle verification status and (optionally) relays each verified bundle to the settlement executor via `EXECUTOR_ENDPOINT`.

