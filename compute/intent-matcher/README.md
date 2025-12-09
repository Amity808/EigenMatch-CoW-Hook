# EigenMatch Intent Matcher (EigenCompute)

This service receives signed intents from EigenLayer AVS operators, runs deterministic netting inside EigenCompute, and emits settlement bundles that the on-chain hook consumes.

## Goals
- **Deterministic matching**: same input set → same match outcome, enabling reproducible attestation proofs.
- **TEE guarantees**: run exclusively inside EigenCompute (Intel TDX) so bundle recipients can trust the enclave measurement and Docker digest.
- **Minimal interfaces**: gRPC for AVS operators, HTTPS for watcher ingestion, Prometheus metrics.

## Architecture

| Stage | Description |
| --- | --- |
| Intent Ingest | Operators push `SubmitIntent` RPCs (EIP-712 signed payloads) into a canonical queue. |
| Matcher | Every 5 s epoch, intents are ordered by pair → price → nonce, then matched greedily. |
| Bundle Builder | Produces `SettlementBundle` objects with `bundleId`, attestation metadata, replay salt. |
| Storage | Bundle metadata persisted to Postgres/SQLite for auditing; raw payload stays in EigenCompute enclave storage. |
| APIs | Watchers fetch bundles via HTTPS (mutual TLS) and acknowledge once quorum thresholds met. |

## HTTP Endpoints

| Method | Path | Description |
| --- | --- | --- |
| `POST /intents` | Submit a signed intent (JSON payload mirrors `Intent` struct). |
| `GET /bundles/latest` | Fetch the most recent settlement bundle emitted by the matcher. |
| `GET /healthz` | Basic health probe exposing epoch timestamp. |

More endpoints (gRPC, watcher ACKs, metrics) will be added as we integrate with EigenLayer AVS + watchers.

## Deployment workflow
1. **Develop locally** with Docker Compose (`dev.docker-compose.yaml`). Keep deterministic tests and clippy/go vet in CI.
2. **Package image**: push to OCI registry (e.g., GHCR) with reproducible builds.
3. **EigenX CLI**: use `eigenx env select` + `eigenx app deploy` to upload the Docker digest, referencing `config/app.eigenx.yaml`.
4. **Secrets**: declare environment variables per EigenCompute rules: `_PUBLIC` suffix for non-sensitive diagnostics; all others encrypted (see `config/example.env`).
5. **Verification**: after deploy, verify measurement on https://verify.eigencloud.xyz/ and update the hook’s allowed docker digests list.

## Files
- `api/intent_matcher.proto` – gRPC service definition shared with AVS operators + watchers.
- `docker/Dockerfile` – Go-based image tuned for EigenCompute (distroless, reproducible build).
- `Makefile` – convenient targets: `make lint`, `make proto`, `make docker`.
- `config/example.env` – documented environment variables (EigenX auth, Postgres DSN, attestation settings).

## References
- EigenCompute overview & trust boundaries (`context/eigencloud-docs/docs/eigencompute/concepts/eigencompute-overview.md`, `security-trust-model.md`).
- Secrets & keys guidance (`context/eigencloud-docs/docs/eigencompute/concepts/keys-overview.md`, `privacy-overview.md`).
- Deployment/billing steps (`context/eigencloud-docs/docs/eigencompute/get-started/quickstart.md`, `billing.md`).

## Optional EigenAI Scoring

Set `EIGENAI_ENDPOINT` to route each submitted intent through an EigenAI scorer (per `context/eigencloud-docs/docs/eigenai/**`). The scorer can approve/reject intents or adjust limit prices before they enter the deterministic matching queue, while keeping sensitive inputs private inside the EigenCompute enclave.

