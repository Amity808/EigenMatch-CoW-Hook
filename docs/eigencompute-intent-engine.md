# EigenCompute Intent Engine – MVP Blueprint

> References: `context/eigencloud-docs/docs/eigencompute/concepts/eigencompute-overview.md`, `concepts/security-trust-model.md`, `concepts/privacy-overview.md`, `get-started/quickstart.md`, plus Uniswap v4 hook docs for downstream integration.

## 1. Goals
- Deliver a deterministic, attestable intent-matching service packaged as an EigenCompute deployment.
- Validate and process signed intents from AVS operators, ensuring cryptographic verifiability.
- Provide minimal but production-guided APIs (gRPC + HTTPS) for AVS operators and watchers.

## 2. Environment Setup
1. **EigenX CLI Bootstrap**
   - Install EigenX CLI via EigenCompute quickstart.
   - Generate authentication keys with `eigenx auth create`, store in OS keyring (`keys-overview.md`).
   - Configure environments: `eigenx env add mainnet`, `sepolia`.
2. **Billing & Subscription**
   - Follow `context/eigencloud-docs/docs/eigencompute/get-started/billing.md` to acquire subscription.
   - Record SKU, quota (vCPU/RAM), TLS enablement, and billing contacts.
3. **Container Registry & Secrets**
   - Use OCI registry (e.g., GHCR) with access tokens stored as EigenCompute encrypted env vars.
   - Define env var policy: `_PUBLIC` suffix for telemetry endpoints; everything else encrypted.
4. **Local Dev**
   - Provide Docker Compose for running matcher + mock AVS feed + watcher.  
   - Include test harness to validate intent signature verification and deterministic matching behavior.

## 3. Service Architecture
```
AVS Operator(s) --> Intent Ingress API --> Canonicalizer --> Matching Core
                                              |                 |
                                              v                 v
                                         Persistence        Settlement Builder
                                              \                /
                                               --> Metrics & Logger --> gRPC Watcher API
```

- **Intent Ingress**: Accepts POST/gRPC streams from AVS nodes; validates signatures, timestamps, quotas.
- **Canonicalizer**: Sorts intents deterministically, drops duplicates, handles expirations.
- **Matching Core**: Implements netting algorithm using fixed-point math; no randomness or multi-thread nondeterminism.
- **Settlement Builder**: Produces `SettlementBundle`, calculates fee savings, residual orders, attaches attestation metadata.
- **Metrics & Logger**: Structured JSON logs (no secrets) + Prometheus exporter for epoch duration, match rate, CPU usage.

## 4. APIs
### 4.1 Intent Ingress (gRPC)
`SubmitIntent(SubmitIntentRequest) returns (SubmitIntentResponse)`
- Request fields mirror `Intent` schema in `system-design.md`.
- Responses include acceptance code, epoch assignment, and optional rejection reason (rate limit, signature invalid).

### 4.2 Bundle Export (HTTPS + gRPC)
- `GET /bundles/:epoch` – returns signed bundle + attestation.  
- `POST /bundles/:epoch/ack` – watchers acknowledge receipt; tracked for quorum.
- Strict mTLS between watchers and TEE service; certificates rotated via EigenCompute TLS configuration (`howto/deploy-to-production/configure-tls.md`).

### 4.3 Metrics
- `/metrics` (Prometheus) – exposed only on private network or authenticated via token.

## 5. Determinism & Testing
- Use Rust or Go with deterministic build flags; pin toolchain via Docker digest.
- Disable system time variability by deriving timestamps solely from AVS batch metadata.
- Intent Validation Tests:  
  - Provide `tests/intent_validation.test.ts` (or Rust equivalent) to validate EIP-712 signature verification and intent format compliance.  
  - Validate that decrypted results only happen inside TEE mocks; otherwise ensure ciphertext remains opaque.
- Re-run differential tests against historical swap traces to ensure deterministic results across runs.

## 6. Packaging & Deployment
1. **Docker Image**
   - Multi-stage build producing minimal runtime image with deterministic binaries.
   - Embed build metadata (git SHA, toolchain versions) for attestation reproducibility.
2. **EigenCompute Manifest**
   - Define instance type (vCPU/RAM) using `context/eigencloud-docs/docs/eigencompute/howto/configure/specify-instance-type.md`.
   - Configure exposed ports (gRPC, HTTPS, Prometheus) per `howto/configure/expose-ports.md`.
   - Add TLS certificates or Let’s Encrypt automation as described in `howto/deploy-to-production/configure-tls.md`.
3. **Attestation**
   - Automate verification via EigenCompute dashboards; fail deployment if measurement mismatches expected digest.
   - Publish measurement + digest to on-chain proof store before enabling hook trust.

## 7. Observability & Ops
- **Logging**: Structured, no plaintext secrets, attach `epoch`, `bundleId`, `matchRatio`.
- **Metrics**: `match_ratio`, `epoch_duration_ms`, `residual_volume_pct`, `attestation_latency_ms`, `cpu_usage_pct`.
- **Tracing**: Optional OpenTelemetry exporter sending sanitized traces to collector outside TEE via encrypted channel.
- **Runbooks**:  
  - TEE restart & redeploy with same mnemonic (per `keys-overview.md`, `privacy-overview.md`).  
  - Secret rotation (regenerate env var payload, re-encrypt, redeploy).  
  - Bundle backlog drain procedure.

## 8. Security & Compliance Controls
- Follow EigenCompute trust model: treat app logic as security boundary; rely on Intel TDX + Google Confidential Space for hardware isolation.  
- Enforce attestation verification before watchers accept any bundle.  
- Rate-limit ingress to defend against DoS from malicious intent submitters; integrate EigenLayer slash conditions when defined.  
- Store encrypted params only in memory; never persist decrypted payloads to disk.

## 9. Delivery Checklist
- [ ] EigenX CLI authenticated for dev + staging.  
- [ ] Billing subscription active; quota documented.  
- [ ] Docker image builds reproducibly.  
- [ ] Deterministic test suite (unit + integration) passing in CI.  
- [ ] Attestation measurement recorded on-chain.  
- [ ] Watcher integration tests verifying replay protection.  
- [ ] Runbooks published for ops.  
- [ ] Security review scheduled (EigenCompute enclave + economic stress tests).

