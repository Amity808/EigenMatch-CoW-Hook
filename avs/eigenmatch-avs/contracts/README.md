## EigenMatch AVS Contracts

This directory contains the EigenMatch-specific Solidity that ships with the DevKit scaffold. The contracts mirror the architecture in the repo root `README.md` and `docs/system-design.md`:

- `src/l1-contracts/EigenMatchDigestRegistry.sol` – on Sepolia/L1 it records every EigenCompute docker digest + TEE measurement that we are willing to trust. The registry owner (the AVS governance address) publishes digests, toggles measurements, and revokes bad builds. This is the “match proof store” mentioned in the product docs.
- `src/l2-contracts/EigenMatchSettlementExecutor.sol` – the on-chain executor that watchers call after validating EigenCompute attestations. It verifies:
  - the bundle’s docker digest / measurement pair is active in `EigenMatchDigestRegistry`,
  - enough allowlisted watchers (>= `minWatcherSigners`) signed the bundleId + replaySalt,
  - the bundle has not already been forwarded.
  Once those checks pass it calls `EigenMatchHook.processSettlementBundle` so internal matches get applied before any Uniswap swap executes.
- `src/interfaces/IEigenMatchHook.sol` – lightweight interface + structs so contracts can talk to the hook without importing the entire Uniswap dependency tree.

### Deployment scripts

`script/DeployMyL1Contracts.s.sol` deploys the digest registry and writes `EigenMatchDigestRegistry` into `script/<env>/output/deploy_custom_contracts_l1_output.json`.

`script/DeployMyL2Contracts.s.sol` expects:

```
export EIGENMATCH_HOOK_ADDRESS=0x...   # address of the deployed EigenMatchHook
```

It reads the registry address from the L1 output file, seeds the executor with the AVS address as the owner + watcher, and writes `EigenMatchSettlementExecutor` into the L2 output file.

Run these via DevKit:

```
cd avs/eigenmatch-avs/.devkit/contracts
make deploy-custom-contracts-l1 ENVIRONMENT=devnet CONTEXT="$(cat ../../config/contexts/devnet.yaml)"
make deploy-custom-contracts-l2 ENVIRONMENT=devnet CONTEXT="$(cat ../../config/contexts/devnet.yaml)" EIGENMATCH_HOOK_ADDRESS=0xHook
```

### Tests

`forge test` under `.devkit/contracts` now verifies:

- publishing / revoking digests in `EigenMatchDigestRegistry`,
- settlement forwarding, signature thresholds, and digest enforcement in `EigenMatchSettlementExecutor` using the mock hook in `test/mocks/`.

These tests encode the invariants from the README KPIs (bundle allowlists, watcher quorum) so CI and devnet runs stay aligned with the documented behavior.

