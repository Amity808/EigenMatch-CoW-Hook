# EigenMatch End-to-End Test Plan

This plan validates that every component described in `README.md`
functions together: AVS operators collect intents, EigenCompute performs
deterministic matching, watchers attest the bundle, and the Uniswap v4
hook executes the settlement. Follow these steps anytime we need to
prove the architecture works as promised.

## Goals

| KPI (README.md) | Test objective |
| --- | --- |
| Deterministic matching in EigenCompute | Same intent set → same bundle hash coming out of `compute/intent-matcher`. |
| Replay-protected watcher handoff | Watchers reject duplicate bundle IDs / stale replay salts and only sign once. |
| Settlement executor gating | Bundles execute on L2 only when watcher signatures + digest registry allowlists match. |
| Hook settlement fidelity | `EigenMatchHook.processSettlementBundle` runs without touching AMM liquidity for matched flow. |

## Preconditions

1. Toolchain installed per `avs/README.md`: Docker, Go 1.23, Foundry, DevKit CLI, jq, yq.
2. `.env` in `avs/eigenmatch-avs/` populated with the user’s Alchemy RPC endpoints and private keys.
3. `compute/intent-matcher/config/example.env` copied to `.env` (or inline env vars) with the EigenCompute deployment values you intend to test.
4. Watcher secrets set via `avs/eigenmatch-avs/services/watcher/config/example.env`.
5. `forge test` and `go test ./...` currently green (sanity check before integration).

## Step-by-step

### 1. Bootstrap and build the AVS

```bash
make -C avs bootstrap
make -C avs context          # regenerates eigenmatch + devnet contexts
devkit --version             # confirm CLI installed
```

### 2. Launch the local devnet

```bash
make -C avs devnet-start
```

Artifacts to record after startup (all under `avs/eigenmatch-avs/.devkit/outputs`):

- `devnet-l1-contracts.json` – contains the `EigenMatchDigestRegistry` address.
- `devnet-l2-contracts.json` – contains the deployed `EigenMatchSettlementExecutor` and the scaffolded hook instance (until we swap in `src/EigenMatchHook.sol`).

These addresses feed the watcher + executor environment variables below.

### 3. Run the AVS performer (if not already running)

If you started devnet with `--skip-avs-run`, run the performer separately:

```bash
cd avs/eigenmatch-avs
devkit avs run --context eigenmatch
```

### 4. Run the EigenCompute intent matcher locally

This mimics the EigenCompute deployment using the same code that would
ship as a TEE workload.

```bash
cd compute/intent-matcher
MATCH_EPOCH_SECONDS=5 \
MATCHER_DOCKER_DIGEST=0x... \
MATCHER_TEE_MEASUREMENT=0x... \
go run ./cmd/matcher
```

The matcher listens on `:8080` by default. Use `curl` (or the future
intent feeder) to submit sample intents:

```bash
curl -X POST http://localhost:8080/intents \
  -H "content-type: application/json" \
  -d @sample_intent.json
```

After at least two opposing intents land, `GET /bundles/latest`
should return a populated bundle with `match_groups`.

### 5. Configure and run the watcher

```bash
cd avs/eigenmatch-avs/services/watcher
export MATCHER_ENDPOINT="http://localhost:8080"
export ALLOWED_DOCKER_DIGESTS="0x..."
export ALLOWED_TEE_MEASUREMENTS="0x..."
export EXECUTOR_ENDPOINT="http://127.0.0.1:8547"   # devnet executor relay
export POOL_ID="0x${POOL_ID_HEX}"
export EXECUTOR_CONTRACT="$(jq -r '.EigenMatchSettlementExecutor' ../../.devkit/outputs/devnet-l2-contracts.json)"
export EXECUTOR_CHAIN_ID=31338                      # devnet L2 chain ID
export WATCHER_PRIVATE_KEY="0x..."
go run ./cmd/watcher
```

Watch for logs:
- `bundle_verified` → attestation checks passed.
- `executor_submit_ok` → watcher signature posted to the executor relay.

### 6. Confirm settlement executor + hook activity

From another terminal:

```bash
cd avs/eigenmatch-avs
cast call $EXECUTOR_CONTRACT "executedBundles(bytes32)(bool)" 0x<bundleId> --rpc-url http://localhost:9545
cast call $HOOK_ADDRESS "isBundleProcessed(bytes32)(bool)" 0x<bundleId> --rpc-url http://localhost:9545
```

Both should return `true` after the watcher successfully relays the
bundle. Additionally, inspect the hook events:

```bash
cast logs $HOOK_ADDRESS --from-block latest-100 --event "SettlementProcessed(bytes32 indexed bundleId)"
```

### 7. Clean up

```bash
make -C avs devnet-stop
pkill -f compute/intent-matcher || true
pkill -f services/watcher || true
```

## Assertions & Observability

| Check | How |
| --- | --- |
| Deterministic bundle hash | Restart matcher, resubmit same intents, compare `bundle_id` + payload hash. |
| Watcher replay protection | Replay the same bundle; watcher should log `duplicate_bundle` and executor should stay idle. |
| Digest registry enforcement | Toggle `setMeasurementAllowed` in `EigenMatchDigestRegistry` via `cast send` and confirm watcher/executor rejects revoked digests. |
| Hook replay guard | Call `processSettlementBundle` twice via Foundry script; second call must revert. Covered by integration portion of the 100-test effort. |

## Relation to future test suites

This manual plan feeds into the upcoming automated suite:

- Unit/Forge tests for `EigenMatchHook.sol`.
- Integration tests wiring `EigenMatchSettlementExecutor` ↔ hook ↔ registry (Foundry).
- Invariants/fuzz that hammer replay protection, fee math, and pool state.

Until that automation lands, this document is the canonical checklist to
prove we satisfy the README promise end-to-end.

