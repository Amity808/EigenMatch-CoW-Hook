# EigenMatch-CoW-Hook

EigenMatch CoW Hook: Coincidence-of-Wants Intent Netting

## Table of Contents

- [Quick Start](#quick-start)
- [Overview](#overview)
- [Prerequisites](#prerequisites)
- [Setup & Installation](#setup--installation)
- [Compilation](#compilation)
- [Testing](#testing)
- [Project Structure](#project-structure)
- [Architecture](#architecture)

## Quick Start

Get up and running in minutes:

```bash
# 1. Clone the repository
git clone --recursive https://github.com/Amity808/EigenMatch-CoW-Hook.git
cd EigenMatch-CoW-Hook

# 2. Initialize submodules (if not already done)
git submodule update --init --recursive

# 3. Install Foundry dependencies
forge install foundry-rs/forge-std
forge install

# 4. Compile contracts
forge build

# 5. Run tests
forge test
```

## Overview

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

## Prerequisites

Before setting up the project, ensure you have the following installed:

- **Foundry**: For Solidity development and testing
  ```bash
  curl -L https://foundry.paradigm.xyz | bash
  foundryup
  ```
- **Go**: Version 1.22 or higher (for intent-matcher and watcher services)
  ```bash
  # Check your Go version
  go version
  ```
- **Git**: For cloning the repository and managing submodules

  ```bash
  git --version
  ```

- **Make**: For running build scripts (usually pre-installed on macOS/Linux)

## Setup & Installation

### 1. Clone the Repository

Clone the repository with all submodules:

```bash
git clone --recursive https://github.com/Amity808/EigenMatch-CoW-Hook.git
cd EigenMatch-CoW-Hook
```

If you've already cloned the repository without submodules, initialize them:

```bash
git submodule update --init --recursive
```

### 2. Install Foundry Dependencies

The project uses Foundry for Solidity development. First, ensure all git submodules are properly initialized:

```bash
# Initialize all submodules recursively (this is critical!)
git submodule update --init --recursive
```

Then install Foundry dependencies:

```bash
# Install forge-std (required for tests)
forge install foundry-rs/forge-std

# Install other dependencies
forge install
```

**Note:** If you encounter an error like `fatal: no submodule mapping found in .gitmodules for path 'lib/v4-core'`, it means `lib/v4-core` and `lib/v4-periphery` were incorrectly tracked as separate submodules. Fix this by:

```bash
# Remove incorrect entries from git index
git rm --cached lib/v4-core lib/v4-periphery 2>/dev/null || true

# Remove incorrect directories if they exist
rm -rf lib/v4-core lib/v4-periphery

# Then re-initialize submodules
git submodule update --init --recursive
```

This will install all required dependencies specified in `foundry.toml` and `remappings.txt`, including:

- `forge-std` - Foundry standard library
- `uniswap-hooks` - Uniswap v4 hooks library (contains nested `v4-core` and `v4-periphery`)
- `hookmate` - Hook development utilities

**Important:** The `v4-core` and `v4-periphery` dependencies are nested inside `lib/uniswap-hooks/lib/`, not as separate top-level dependencies.

### 3. Install Go Dependencies

Install dependencies for the Go services:

```bash
# Install intent-matcher dependencies
cd services/intent-matcher
go mod download
cd ../..

# Install watcher dependencies
cd services/watcher
go mod download
cd ../..
```

## Compilation

### Compile Solidity Contracts

Compile the EigenMatch Hook and all dependencies:

```bash
forge build
```

This will:

- Compile all Solidity contracts in `src/`
- Generate artifacts in `out/`
- Verify remappings are correctly configured

To compile with verbose output:

```bash
forge build -vvv
```

### Compile Go Services

#### Intent Matcher Service

```bash
cd services/intent-matcher
go build -o bin/intent-matcher ./cmd/matcher
```

Or using Make (if Makefile exists):

```bash
cd services/intent-matcher
make build
```

#### Watcher Service

```bash
cd services/watcher
go build -o bin/watcher ./cmd/watcher
```

## Testing

### Run Solidity Tests

Run all Foundry tests:

```bash
forge test
```

Run tests with verbose output:

```bash
forge test -vvv
```

Run specific test file:

```bash
forge test --match-path test/EigenMatchHook.t.sol
```

### Run Go Tests

```bash
# Test intent-matcher
cd services/intent-matcher
go test ./...

# Test watcher
cd services/watcher
go test ./...
```

## Project Structure

```
EigenMatch-CoW-Hook/
├── src/                    # Solidity smart contracts
│   └── EigenMatchHook.sol  # Main Uniswap v4 hook contract
├── test/                   # Foundry test files
│   └── EigenMatchHook.t.sol
├── lib/                    # External dependencies (submodules)
│   ├── uniswap-hooks/      # Uniswap v4 hooks library
│   ├── hookmate/           # Hook development utilities
│   └── forge-std/          # Foundry standard library
├── services/               # Go services
│   ├── intent-matcher/     # Intent matching engine
│   │   ├── cmd/matcher/    # Main application entry
│   │   └── internal/       # Internal matching logic
│   └── watcher/            # Blockchain event watcher
│       ├── cmd/watcher/    # Main application entry
│       └── internal/       # Execution and verification logic
├── avs/                    # EigenLayer AVS components
│   └── devkit/             # AVS development kit
├── docs/                   # Documentation
├── foundry.toml            # Foundry configuration
├── remappings.txt          # Solidity import remappings
└── README.md               # This file
```

## Architecture

Architecture Highlights
Order Flow:

1. Traders submit signed intents to EigenLayer AVS:
   - Alice: Buy 10 ETH for USDC (limit: $2,005/ETH)
   - Bob: Sell 5 ETH for USDC (limit: $1,995/ETH)
   - Carol: Buy 3 ETH for USDC (limit: $2,003/ETH)
2. AVS operators forward intents to EigenCompute TEE (every 5 seconds)
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
