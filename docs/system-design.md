# EigenMatch CoW Hook – System Design

## 1. Overview
EigenMatch routes opposing intents through an EigenCompute-hosted deterministic matcher, then enforces the resulting settlements via a Uniswap v4 hook. Matched volume settles peer-to-peer while residual deltas traverse the AMM (`README.md`). This document details component responsibilities, interfaces, data schemas, trust boundaries, and failure handling. All hook behavior and deployment constraints reference the canonical v4 docs (`context/uniswap-v4-docs/docs/contracts/v4/concepts/hooks.mdx`, `quickstart/hooks/setup.mdx`). EigenCompute guarantees and responsibilities derive from `context/eigencloud-docs/docs/eigencompute/concepts/eigencompute-overview.md` and `security-trust-model.md`.

## 2. Component Map
| Component | Description |
| --- | --- |
| **Intent Gateway** | Public RPC/API where routers submit signed intents. Performs signature validation, dedupe, and rate limiting. |
| **AVS Operator Mesh** | EigenLayer restakers running gossip + aggregation, forwarding intents to TEEs in 5 s epochs. Slashable for censorship/withholding. |
| **Canonical Order Book** | Deterministic ordering of intents keyed by pair, price, timestamp, nonce. Stored inside EigenCompute persistent volume (encrypted). |
| **EigenCompute Matcher** | Dockerized service in Intel TDX enclave; runs matching algorithm, emits settlement bundles + proofs, logs metrics. |
| **Match Proof Store** | On-chain record referencing Docker digest + epoch metadata to tie settlements to attested code. |
| **Watcher / Relay Network** | Independently verifies TEE attestations via EigenCompute dashboard APIs, ensures replay protection, sequences calldata to hook. |
| **Settlement Executor** | Solidity contract receiving settlement bundles, funding transfers, and calling hook entry points. Holds treasury buffers and can pause. |
| **Uniswap v4 Hook** | BaseHook-derived contract intercepting swap/liquidity flows, applying settlement deltas or falling back to PoolManager. |
| **Treasury & Fee Ledger** | ERC6909 or ERC20-based accounting for user rebates, protocol fees, LP incentives. |
| **Observability Stack** | Off-chain metrics (Prometheus/Grafana), EigenCompute logs, Uniswap pool state monitors.

## 3. Data Schemas
```text
Intent {
  intentId: keccak256(...)
  trader: address
  pair: { base: address, quote: address }
  side: enum { BUY, SELL }
  amount: uint256
  limitPrice: uint256  // Q64.96 fixed point
  expiry: uint64
  nonce: uint64
  signature: bytes  // EIP-712
}

MatchGroup {
  matchGroupId: bytes32
  intents: IntentId[]
  clearingPrice: uint256
  matchedAmount: uint256
  feesSavedBps: uint16
}

SettlementBundle {
  epoch: uint64
  bundleId: bytes32  // attested hash
  matchGroups: MatchGroup[]
  residualOrders: Intent[]
  teeMeasurement: bytes32
  dockerDigest: bytes32
  attestationSignature: bytes
  replaySalt: bytes32
}

FeeLedgerEntry {
  user: address
  matchedVolume: uint256
  feeSaved: uint256
  timestamp: uint64
}
```

All schemas must be serializable deterministically (sorted arrays, canonical encoding). Signed intents are verifiable on-chain; matching happens deterministically within the TEE's isolated environment.

## 4. Flow
1. **Intent Submission**  
   - Traders submit intents via routers; gateway validates signatures and enqueues into AVS gossip.  
   - Operators collect intents for the current epoch (5 s window) and forward batched payloads to EigenCompute.
2. **Deterministic Matching**  
   - Matcher ingests sorted intents (by pair, price, timestamp, intentId).  
   - Runs netting algorithm: pair opposing sides, compute clearing price (mid between overlapping limits), enforce limit/slippage rules, derive MatchGroups.  
   - Produces residual orders for unmatched quantities.
3. **Settlement Bundle Creation**  
   - Generate bundle struct + fee ledger deltas; sign with enclave key bound to Docker digest.  
   - Post digest reference on-chain (match proof store) for auditability.
4. **Watcher Verification**  
   - Watchers fetch bundle, verify EigenCompute attestation (via `verify.eigencloud.xyz`) ensuring measurement + docker digest match published values.  
   - Check replaySalt uniqueness, epoch ordering, and aggregate thresholds (≥2 watchers) before broadcasting executor transaction.
5. **Hook Execution Path**  
   - Settlement executor calls hook entrypoint with bundle data.  
   - Hook verifies permission bits (per `Hooks` library) and ensures pool-specific constraints.  
   - `beforeSwap`/`afterSwap`: adjust balances to account for internal matches; only residual delta touches PoolManager.  
   - Liquidity hooks handle adjustments when settlement requires LP inventory updates.  
   - Donate hooks credit fee savings back to LP treasury.
6. **Fallback & Residuals**  
   - For any unmatched portion, hook invokes PoolManager swap with original params.  
   - Fee ledger updates stored on-chain (ERC6909) for transparency.

## 5. Trust Boundaries
- **Inside TEE**: matching algorithm, encrypted params, attestation keys, interim order book state. Governed by EigenCompute guarantees (hardware isolation, dedicated wallet, secret management).  
- **Outside TEE (watchers, executors)**: only attested bundle metadata and encrypted payload IDs.  
- **Hook Contract**: deterministic on-chain logic; trusts only settlement bundles whose attestation matches allowlist.  
- Responsibilities: Application team secures code and secret usage; EigenLabs secures infrastructure, attestation, KMS (per `security-trust-model.md`).

## 6. Hook Permissions & Multi-Pool Support
- Hook contract deployed once, serving multiple pools via pool-specific storage keyed by `PoolId`.  
- Permissions struct must set:  
  - `beforeSwap`, `afterSwap`, `afterAddLiquidity`, `afterRemoveLiquidity`, `beforeDonate`, `afterDonate`.  
  - Optional `beforeSwapReturnDelta` when async swap plumbing enabled.  
- Deployment requires address-mining to encode permission bits (`context/uniswap-v4-docs/docs/contracts/v4/guides/hooks/hook-deployment.mdx`).  
- Hook maintains per-pool config: supported pairs, fee tiers, allowed EigenCompute bundle IDs.  
- Flash accounting integration: use BaseHook’s custom accounting to ensure transient storage invariants remain within Cancun requirements (`quickstart/hooks/setup.mdx`).

## 7. Deterministic Scheduling & Replay Protection
- Epoch length: **5 s** (configurable).  
- Each epoch includes: `epochNumber`, `intentStartBlock`, `intentEndBlock`.  
- Bundle replay protection: combine `epochNumber` + `bundleNonce` into `replaySalt`; hook rejects duplicates.  
- Watchers maintain sliding window of accepted bundles per pool.  
- Residual orders re-queued automatically for next epoch (with decreased TTL).

## 8. Failure Handling
| Scenario | Detection | Response |
| --- | --- | --- |
| **TEE crash** | Missing bundle heartbeat > 2 epochs | Watchers trigger alert, hook auto-fallback to AMM only, intents stay queued. |
| **Attestation mismatch** | Watcher validation fails | Bundle discarded; slash signal sent to operators; re-run epoch. |
| **Executor revert** | Hook emits `SettlementRejected` | Pause internal settlement, escalate to governance, require manual review. |
| **AVS reorg / inconsistency** | Conflicting intent views | Deterministic ordering ensures stable output; unmatched intents roll forward. |
| **Liquidity shortfall** | Hook detects insufficient balances | Partial settlement applied, remainder sent to pool; ledger logs deficit. |

## 9. Observability & Ops
- **Metrics**: match ratio, fee savings, epoch duration, attestation verification latency, hook gas usage, executor failures.  
- **Logs**: structured JSON from EigenCompute (scrub secrets), watcher decisions, hook events (`Matched`, `ResidualSwapped`, `FeeRebate`).  
- **Dashboards**: Grafana panels for KPIs; EigenCompute verification dashboard links embedded.  
- **Runbooks**: TEE key rotation, hook upgrade steps, EigenCompute redeploy (new digest publish + address allowlist), Uniswap pool parameter adjustments, emergency pause procedures.  
- **Rate Limits & Sequencing**: Watchers enforce max settlements per block, throttle residual swap submissions, and maintain multi-sig approval for resume after pause.
- **Watcher responsibilities**:
  - Validate EigenCompute bundle attestation (docker digest, measurement) against hook allowlist before broadcasting.
  - Enforce quorum (`MIN_WATCHER_ACKS`) and replay window (reject duplicate salts/epochs).
  - Surface real-time alerts when a bundle fails verification or misses the 5 s epoch deadline.
  - Generate bundle metadata (bundleId, epoch, fee stats) that feeds into the shared telemetry pipeline.
- **Telemetry architecture**:
  - EigenCompute matcher exposes Prometheus metrics (`/metrics` on non-public port) aggregated by a dedicated monitoring instance. Per EigenCompute privacy model, only `_PUBLIC` metrics endpoints are exposed; sensitive metrics remain private within the TEE (see `context/eigencloud-docs/docs/eigencompute/concepts/privacy-overview.md`).
  - Watchers emit structured events (JSON over gRPC or REST) to a log collector; key fields include bundleId, validation result, attestation digest, and submission tx hash.
  - Settlement executor / hook contracts emit events tracked via on-chain indexers (e.g., subgraph or log consumer) to correlate matched volume to attested bundles.
  - Unified Grafana dashboard with panels for match ratio, fee savings, watcher quorum status, executor gas usage, and EigenCompute health endpoints.
  - Alerting rules (PagerDuty/Slack) for: missing bundles for >2 epochs, attestation mismatches, hook pause activation, watcher quorum not met, and EigenCompute attestation changes.

## 10. Outstanding Questions
1. Which EIP-712 domain separator should be used for intent signatures to avoid replay across networks?  
2. Precise slashable conditions for AVS operators forwarding malformed batches.  
3. EigenCompute capacity commitments (vCPU, memory, TLS certificate constraints).  
4. Liquidity routing agreements with Uniswap Interface / UniswapX for flow capture.

