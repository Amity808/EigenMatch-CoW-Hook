# EigenMatch Hook Test Plan

This document enumerates the **100 tests** we need to fully cover
`src/EigenMatchHook.sol` and its interactions with the settlement
executor, digest registry, watcher relay, and Uniswap PoolManager. The
plan tracks three categories:

| Category | IDs | Count | Scope |
| --- | --- | --- | --- |
| Unit | U01–U40 | 40 | Pure contract logic inside `EigenMatchHook` (admin, bundle processing, beforeSwap behavior, storage accounting). |
| Integration | I01–I40 | 40 | Hook + `EigenMatchSettlementExecutor` + `EigenMatchDigestRegistry` + watcher client using Foundry or Go harnesses. |
| Invariant/Fuzz | F01–F20 | 20 | Stateful fuzzing + invariants targeting replay, fee accounting, and pause safety. |

Status legend: `[ ]` pending, `[~]` in progress, `[x]` implemented.

---

## Unit tests (U01–U40)

1. `[ ] U01 – Hook permissions match README expectations (only beforeSwap true).`
2. `[ ] U02 – Constructor reverts when owner is zero address.`
3. `[ ] U03 – Constructor reverts when settlement executor is zero.`
4. `[ ] U04 – `setSettlementExecutor` only callable by owner.`
5. `[ ] U05 – `setSettlementExecutor` rejects zero address.`
6. `[ ] U06 – `enablePool` rejects `maxSettlementDelay == 0`.`
7. `[ ] U07 – `enablePool` copies the digest allowlist without sharing storage.`
8. `[ ] U08 – `enablePool` toggles `enabled` flag and is persisted.`
9. `[ ] U09 – `getPoolConfig` returns a defensive copy (mutating result does not mutate storage).`
10. `[ ] U10 – `getPendingSettlement` returns zero struct before any queueing.`
11. `[ ] U11 – `processSettlementBundle` requires `msg.sender == settlementExecutor`.`
12. `[ ] U12 – `processSettlementBundle` reverts if pool not enabled.`
13. `[ ] U13 – `processSettlementBundle` reverts when `traderSettlements` array empty.`
14. `[ ] U14 – `processSettlementBundle` marks bundle and replay salt as processed.`
15. `[ ] U15 – `processSettlementBundle` reverts on duplicate `bundleId`.`
16. `[ ] U16 – `processSettlementBundle` reverts on duplicate `replaySalt`.`
17. `[ ] U17 – `processSettlementBundle` rejects docker digests not in allowlist.`
18. `[ ] U18 – `processSettlementBundle` enforces `maxSettlementDelay`.`
19. `[ ] U19 – `_queueSettlement` rejects zero trader address.`
20. `[ ] U20 – `_queueSettlement` rejects expired instructions.`
21. `[ ] U21 – `_queueSettlement` stores deltas + expiry + bundleId exactly.`
22. `[ ] U22 – `beforeSwap` returns zero delta when pool disabled.`
23. `[ ] U23 – `beforeSwap` returns zero delta when sender has no settlement.`
24. `[ ] U24 – `beforeSwap` reverts with `PoolIsPaused` when pool paused.`
25. `[ ] U25 – `beforeSwap` reverts with `SettlementExpired` when queued settlement expired.`
26. `[ ] U26 – `beforeSwap` consumes settlement and deletes storage.`
27. `[ ] U27 – `beforeSwap` emits `SettlementConsumed` with correct payload.`
28. `[ ] U28 – Fee ledger accumulates matched volume + feeSaved correctly after each consumption.`
29. `[ ] U29 – Multiple settlements for same trader overwrite pending delta but fee ledger only updates upon consumption.`
30. `[ ] U30 – `processSettlementBundle` emits `BundleProcessed` totals for sums of fees and matched amounts.`
31. `[ ] U31 – `processSettlementBundle` handles multiple traders with different deltas.`
32. `[ ] U32 – `_absInt128` returns correct magnitude for positive + negative numbers.`
33. `[ ] U33 – `_toInt128` reverts when value exceeds int128 bounds.`
34. `[ ] U34 – `setPoolPaused` onlyOwner guard.`
35. `[ ] U35 – `setPoolPaused` emits `PoolPaused`.`
36. `[ ] U36 – `setSettlementExecutor` updates storage and subsequent bundles must be sent by the new address.`
37. `[ ] U37 – `isBundleProcessed` reflects both bundleId and replayKey entries.`
38. `[ ] U38 – Pending settlement retrieval returns last queued bundle info for each trader.`
39. `[ ] U39 – `processSettlementBundle` rejects instructions whose expiry is already elapsed (covers `_queueSettlement`).`
40. `[ ] U40 – `processSettlementBundle` allows multiple allowed digests and accepts any one of them.`

---

## Integration tests (I01–I40)

1. `[ ] I01 – End-to-end: Watcher submits bundle signatures → executor verifies and calls hook, settlement consumed.`
2. `[ ] I02 – Executor rejects digest when `EigenMatchDigestRegistry` revokes measurement; hook never sees bundle.`
3. `[ ] I03 – Executor rejects insufficient watcher signatures, ensuring hook not called.`
4. `[ ] I04 – Executor prevents duplicate watcher signatures.`
5. `[ ] I05 – Executor records bundle replay protection so hook cannot be called twice even if watchers resend.`
6. `[ ] I06 – Hook’s `processSettlementBundle` reverts if executor misconfigures pool (integration with registry).`
7. `[ ] I07 – Digest registry update propagates to watcher allowlist + executor/hook pipeline.`
8. `[ ] I08 – Watcher signs bundle hash computed from canonical payload; executor verifies ECDSA and forwards.`
9. `[ ] I09 – Watcher rejects bundle from matcher when docker digest not allowlisted.`
10. `[ ] I10 – Watcher rejects bundle when replay salt already seen locally.`
11. `[ ] I11 – Watcher fails to submit when executor endpoint unreachable; verify retry/backoff.`
12. `[ ] I12 – Watcher successfully sends HTTP payload to executor mock and handles 200 OK.`
13. `[ ] I13 – Executor emits `SettlementForwarded` event consumed in tests.`
14. `[ ] I14 – Hook integrates with actual `PoolManager` mock to confirm delta application before AMM swap.`
15. `[ ] I15 – Hook with real `BeforeSwapDelta` ensures AMM receives reduced amount.`
16. `[ ] I16 – Hook + executor handles multi-trader bundle where only subset of traders perform swap.`
17. `[ ] I17 – Hook + executor ensures paused pool blocks settlements even if executor tries to call.`
18. `[ ] I18 – Hook + executor ensures `maxSettlementDelay` enforced even when executor tries late submission.`
19. `[ ] I19 – Hook + executor ensures `allowedDockerDigests` respected after owner updates config.`
20. `[ ] I20 – Executor cannot call hook when not owner after `setSettlementExecutor`.`
21. `[ ] I21 – Watcher referencing `POOL_ID` mismatched results in executor revert; verify telemetry.`
22. `[ ] I22 – Watcher aggregator collects multiple watcher signatures before executor invocation (mock aggregator).`
23. `[ ] I23 – Executor verifies EIP-191 message hash matches watcher library implementation.`
24. `[ ] I24 – Hook + executor gracefully handle zero-fee `feeSaved` values.`
25. `[ ] I25 – Hook + executor handle mixture of positive/negative deltas (buy vs sell).`
26. `[ ] I26 – Hook + executor ensure `TraderSettlement` expiry prevents stale watchers forcing swap.`
27. `[ ] I27 – Hook + executor ensures pending settlement is per trader per pool (two pools unaffected).`
28. `[ ] I28 – Hook + executor tracks total matched amount emitted in `BundleProcessed`.`
29. `[ ] I29 – Hook + executor ensures `processedBundles` prevents duplicates even across pools sharing replay salt.`
30. `[ ] I30 – Hook + executor ensures revert reasons propagate to watcher (HTTP 400).`
31. `[ ] I31 – Hook + executor ensures `feeLedger` view exposed after multiple bundles.`
32. `[ ] I32 – Hook + executor ensures `isBundleProcessed` view returns true after executor call.`
33. `[ ] I33 – End-to-end scenario where watcher signs but executor fails due to digest revocation mid-flight.`
34. `[ ] I34 – End-to-end scenario where two watcher signatures disagree; executor rejects.`
35. `[ ] I35 – End-to-end scenario where performer rejects bundle (pre-watcher), verifying docs.`
36. `[ ] I36 – Hook integrates with devnet `PoolManager` harness to ensure `beforeSwap` delta influences swap outcome.`
37. `[ ] I37 – Hook + executor ensures `SettlementQueued` events consumed by analytics pipeline (event decoding harness).`
38. `[ ] I38 – Hook + executor ensures `SettlementConsumed` emitted only once per bundle/trader pair.`
39. `[ ] I39 – Hook + executor ensures multiple bundles in same block processed sequentially without interference.`
40. `[ ] I40 – Full devnet smoke: run `docs/e2e-test-plan.md` automatically via script to confirm README flow.`

---

## Invariant + fuzz tests (F01–F20)

1. `[ ] F01 – Replay invariant: `processedBundles` mapping must never return false for a bundle already consumed.`
2. `[ ] F02 – Fee ledger monotonicity: `matchedVolume` and `feeSaved` never decrease.`
3. `[ ] F03 – Settlement expiry invariant: if `block.timestamp > expiry`, pending settlement must be absent.`
4. `[ ] F04 – Pause safety: when pool paused, `_beforeSwap` always reverts regardless of fuzzed inputs.`
5. `[ ] F05 – Bundle uniqueness: for arbitrary bundle/replay salts, hook either reverts or marks them processed exactly once.`
6. `[ ] F06 – Digest allowlist invariant: only digests present in config may lead to state changes.`
7. `[ ] F07 – Delta bounds: fuzzed inputs must stay within int128 or `_toInt128` reverts; verify no silent truncation.`
8. `[ ] F08 – Fee ledger overflow check via fuzzed large matched amounts.`
9. `[ ] F09 – Pending settlement overwrite: multiple bundles for same trader leave at most one pending entry.`
10. `[ ] F10 – `SettlementQueued` and `SettlementConsumed` event ordering matches queue/consume order.`
11. `[ ] F11 – `BundleProcessed` totals equal sum of individual instructions.`
12. `[ ] F12 – No residual state leakage between pools (fuzz pool IDs).`
13. `[ ] F13 – `paused` flag toggling preserves other pools’ state.`
14. `[ ] F14 – Hook never emits `ResidualRouted` when settlement fully satisfies order (reserved for AMM flow).`
15. `[ ] F15 – Invariant harness ensures `_beforeSwap` never returns non-zero delta when no settlement queued.`
16. `[ ] F16 – Invariant ensures settlement expiry cannot be extended by re-queueing same bundle without executor call.`
17. `[ ] F17 – Invariant ensures `feeLedger.lastUpdated` matches last consumption time.`
18. `[ ] F18 – Invariant ensures hooking does not allow `deltaSpecified` or `deltaUnspecified` to exceed int128 range.`
19. `[ ] F19 – Invariant ensures `processedBundles` entries are cleared only via `processSettlementBundle` (no deletes).`
20. `[ ] F20 – Invariant ensures operator pause/unpause cycles never leave partially processed bundles accessible.`

---

## Tracking + next steps

- Implementation order: tackle unit tests first (U01–U40), then build the
  integration harness (I01–I40), and finally wire Foundry invariants
  (F01–F20).
- Each test will be committed with its identifier (e.g., `test_U11_RequiresExecutor`)
  so we can map progress to this checklist.
- CI target: run all 100 tests + invariants along with the Go watcher unit
  tests and the devnet smoke described in `docs/e2e-test-plan.md`.

