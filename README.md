# EigenMatch-CoW-Hook

EigenMatch CoW Hook: Coincidence-of-Wants Intent Netting
Brief Description
EigenMatch CoW Hook reduces trading costs and LP slippage by internally matching opposing trade intents before routing unmatched residuals to the Uniswap pool. Using an EigenLayer AVS network where restakers collect signed intents in real-time, and EigenCompute TEEs to run deterministic matching algorithms, the hook identifies offsetting trades (e.g., Alice buying 10 ETH while Bob sells 5 ETH) and settles matched portions internally at mid-market price with zero fees and zero slippage. Only the net unmatched volume (Alice's remaining 5 ETH buy) touches the AMM liquidity, saving traders 0.1-0.3% in fees on matched volume while reducing toxic flow that hits LP reserves. This creates a hybrid model: instant peer-to-peer settlement for matched trades + AMM fallback for price discovery, capturing 20-30% of order flow as internal matches.

The Problem (One Sentence)
AMMs blindly route every swap through liquidity pools even when opposing trades could be netted internally—wasting 0.1-0.3% in fees per side and creating unnecessary LP slippage when offsetting orders could settle peer-to-peer at fair mid-market prices.

The Solution (One Sentence)
Use EigenLayer AVS restakers to collect signed trade intents and EigenCompute TEEs to run deterministic matching engines that settle offsetting trades internally (zero fees, zero slippage), only routing net unmatched volume through the Uniswap pool for price discovery.

Key Innovation
Real-Time Intent Matching with Deterministic Settlement:

EigenLayer AVS for Intent Collection

Restaker-operated network collects signed trade intents
Slashable operators ensure intents aren't censored or withheld
Decentralized aggregation prevents single-point manipulation


EigenCompute TEE for Fair Matching

Deterministic matching algorithm (same intents = same matches)
Runs every 5 seconds in secure enclave
Cryptographic proofs of fair execution


Hybrid Settlement Model

Matched volume: Internal transfer at mid-market (0% fees)
Unmatched volume: Route to AMM (normal 0.05-0.3% fees)
Best of both: CoW efficiency + AMM liquidity backstop



Result: Traders save fees on matched portions, LPs face less toxic flow, and everyone benefits from reduced slippage.

Architecture Highlights
Order Flow:
1. Traders submit signed intents to EigenLayer AVS:
   - Alice: Buy 10 ETH for USDC (limit: $2,005/ETH)
   - Bob: Sell 5 ETH for USDC (limit: $1,995/ETH)
   - Carol: Buy 3 ETH for USDC (limit: $2,003/ETH)
   
2. AVS operators forward intents to the EigenCompute TEE matcher (code in `compute/intent-matcher`, packaged per EigenCloud compute-app docs) every 5 seconds.
   
3. TEE matching engine runs deterministically:
   - Alice wants +10 ETH, Bob wants -5 ETH, Carol wants +3 ETH
   - Net demand: +8 ETH (10 + 3 - 5)
   - Match internally: 5 ETH (Alice ↔ Bob at $2,000 mid-price)
   - Match internally: 3 ETH (Carol ↔ remaining from Alice at $2,000)
   - Residual to AMM: Alice's remaining 2 ETH buy
   
4. TEE generates settlement instructions + attestation
   
5. EigenMatch Hook validates and executes:
   - Internal settlements: Alice gets 5 ETH, Bob gets $10,000 USDC (NO FEES!)
   - Internal settlement: Carol gets 3 ETH (NO FEES!)
   - AMM swap: Alice's final 2 ETH buy (pays 0.3% fee on 2 ETH only)
   
6. Savings calculation:
   - Without matching: 18 ETH through AMM = $108 in fees (0.3%)
   - With matching: 8 ETH matched (0 fees) + 2 ETH AMM ($12 fees)
   - Total saved: $96 (89% fee reduction!) 🎉

## End-to-end validation

The full operator → EigenCompute → watcher → executor → hook flow is
documented in `docs/e2e-test-plan.md`. Run that checklist whenever you
need to show the README architecture working in practice or before
pushing major changes.
