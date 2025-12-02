# EigenMatch CoW Hook – Product Requirements

## 1. Summary
- **Problem**: AMMs route every swap through liquidity pools even when opposing intents exist, creating 0.1–0.3 % fee drag per side and unnecessary LP slippage (see `README.md`).
- **Solution**: Collect signed intents via EigenLayer AVS operators, run deterministic netting inside EigenCompute TEEs, internally settle matched volume at mid-price, and only forward the residual delta to Uniswap v4 liquidity using a custom hook (`context/uniswap-v4-docs/docs/contracts/v4/concepts/hooks.mdx`).
- **Approach**: Hybrid flow—peer-to-peer settlement backed by verifiable off-chain compute, with AMM fallback for unmatched volume.

## 2. Objectives & KPIs
- ≥ **20 %** of intents netted internally over any trailing 24 h window (primary efficiency KPI).
- ≥ **80 %** fee reduction on the matched portion versus routing all flow through the pool.
- **< 250 ms** hook execution overhead per swap (post-EigenCompute instruction ingestion).
- **< 2 s** total settlement latency for matched legs (TEE attestation + executor call).
- **0 critical** privacy incidents: encrypted payloads never leak outside approved paths.

## 3. Actors
| Actor | Role |
| --- | --- |
| Intent Submitters | Traders or routers generating signed intents (EIP-712). |
| EigenLayer Restakers / AVS Operators | Collect, validate, and forward intents every 5 s epoch; slashable for withholding. |
| EigenCompute TEE | Deterministically matches intents, proves execution via attestation (`context/eigencloud-docs/docs/eigencompute/concepts/eigencompute-overview.md`). |
| Watcher / Settlement Verifier | Verifies attestation, enforces replay protection, forwards instructions. |
| Uniswap v4 Hook | Applies internal settlement or falls back to AMM; permissions encoded per `Hooks.mdx`. |
| Settlement Executor | Moves funds per TEE output, interacts with PoolManager, treasury. |
| Governance Stakeholders | Protocol, infra, and security owners signing off on releases. |

## 4. Functional Requirements
1. **Intent Intake**  
   - Accept intents from ≥ N operators, de-dupe, and validate signatures.  
   - Maintain canonical order book keyed by asset pair, limit, expiry, nonce.
2. **Deterministic Matching**  
   - Run epoch-based matching inside EigenCompute every 5 s.  
   - Produce match groups, pricing proofs, fee deltas, and residual orders.
3. **Attested Settlement Instructions**  
   - Include TEE measurement, Docker digest, and epoch metadata.  
   - Enforce replay window ≤ 30 s and single-use settlement IDs.
4. **Hook Execution**  
   - Implement at minimum `beforeSwap`, `afterSwap`, `afterAddLiquidity`, `afterRemoveLiquidity`, and donate hooks for fee refunds (align with `context/uniswap-v4-docs/docs/contracts/v4/guides/hooks/hook-deployment.mdx`).  
   - Respect permission-bit encoding; deployment tooling must mine correct address bits.  
   - Enforce mid-market pricing on internal matches; fallback to AMM for residual volume.
5. **Accounting & Fees**  
   - Track fee savings per user, matched volume, LP benefit metrics.  
   - Support ERC6909-based internal ledger if shared inventory required.

## 5. Guardrails & Policies
1. **Hook Testing Policy**  
   - All new hook logic must have comprehensive Foundry test coverage.
   - Tests must assert hook permission bits match documented pattern (per `Hooks.mdx`).  
   - Integration tests must validate hook behavior with mock EigenCompute attestations.
2. **Determinism**  
   - No randomness, clock, or network-driven variability inside matching engine; use ordered inputs only.  
   - Floating point operations must use deterministic fixed-point math or reproducible libraries.
3. **Privacy & Trust Boundaries**  
   - Follow EigenCompute trust model (`context/eigencloud-docs/docs/eigencompute/concepts/security-trust-model.md`): app logic responsible for secret hygiene, platform handles TEE/KMS.  
   - No plaintext secrets in logs; use `_PUBLIC` suffix env vars for non-sensitive data.
4. **Permissions & Upgrades**  
   - Hook upgrades require governance approval and redeployment via mined address.  
   - Executor/tresury contracts must support emergency pause.

## 6. Dependencies & Inventory
- **EigenLayer AVS**: Operator registry, slash conditions, gossip layer, pricing feed.
- **EigenCompute**: EigenX CLI, billing subscription, container registry, attestation dashboards.
- **Uniswap v4 Deployment**: PoolManager, v4-template-based repo, Hook deployment scripts.
- **Watcher Network**: Off-chain service verifying attestations and sequencing transactions.
- **Testing Tooling**: Foundry, Anvil nodes, historical data replayer, mock AVS intent feed.

## 7. Milestones & Sign-offs
| Milestone | Owner | Exit Criteria | Sign-off |
| --- | --- | --- | --- |
| PRD approval | Product | All requirements captured, KPIs confirmed | Product + Protocol lead |
| Architecture review | Engineering | System design doc reviewed, threats mapped | Infra + Security |
| EigenCompute MVP | Off-chain | Hello-world attested deployment + deterministic tests | Off-chain lead |
| Hook Alpha | On-chain | All hook functions + comprehensive test suite passing | Protocol + Security |
| Bridging & Ops | DevOps | Watchers, dashboards, runbooks ready | Infra lead |
| Launch Readiness | Cross-func | Audits done, staged rollout plan approved | Product + Protocol + Security |

## 8. Risks & Mitigations
- **TEE attestation verification complexity** → Early integration testing with EigenCompute verification dashboards.  
- **TEE capacity limits** → Reserve EigenCompute quota early; maintain failover plan.  
- **Liquidity acquisition** → Engage with Uniswap routing teams, consider incentives for initial LPs.  
- **Regulatory/accounting** → Document internal settlement behavior for compliance review.

## 9. Out-of-Scope (Current Phase)
- Cross-chain intent settlement.  
- Automated market-making inventory owned by hook (custom curves).  
- Permissionless hook deployment by third parties.

