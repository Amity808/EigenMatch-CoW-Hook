# EigenMatch AVS Plan

This document captures how we will adapt EigenLayer’s DevKit template to build the EigenMatch intent collection AVS, using the reference materials shipped in `context/eigencloud-docs/static/devkit.md`.

## Objectives
1. **Intent gossip + validation** – Operators ingest signed intents from routers, verify EIP‑712 signatures, and forward batches every 5 s epoch to the EigenCompute matcher.
2. **Slashable guarantees** – Operators must either forward intents on time or face slashing if they censor, delay, or submit malformed bundles.
3. **Watcher alignment** – The AVS publishes bundle metadata (epoch, docker digest, attestation) so off-chain watchers and the on-chain hook can enforce allowlists.

## Bootstrap Steps

1. **Clone the DevKit template**
   ```bash
   git submodule update --init --recursive avs/devkit
   cd avs/devkit
   ./install-devkit.sh  # per static/devkit.md instructions
   ```
   The template now lives inside this repository as a git submodule pointing to [`Layr-Labs/devkit-cli`](https://github.com/Layr-Labs/devkit-cli). It includes Go CLI commands, operator keystores, devnet scripts, and CI workflows for lint/tests.

2. **Create an AVS context**
   ```bash
   make -C avs context CONTEXT=eigenmatch
   ```
   The context files (under `config/contexts`) define registry addresses, quorum configs, and telemetry endpoints.
   > **Heads up:** Every `devkit avs …` command must run from the generated AVS project (`avs/eigenmatch-avs`). Running inside the CLI submodule (`avs/devkit`) lacks the `.devkit/scripts/deployL1Contracts` helper and causes the “missing deployL1Contracts” failure. The root `Makefile` already wraps the CLI at the correct path and now hard-fails if the script is absent so we catch misconfigurations early.

3. **Wire EigenMatch‑specific logic**
   - **Intent RPC**: add a `SubmitIntent` command (mirroring `compute/intent-matcher/api/intent_matcher.proto`) inside `pkg/commands/avs.go`.
   - **Batch forwarder**: extend the template’s transporter to call the EigenCompute HTTPS endpoint, attaching attestation metadata that the hook expects (docker digest, epoch, replay salt).
   - **Slash hooks**: update `config/templates.yaml` to include rules for late/malformed batches; reuse DevKit’s `keystore_embeds` for local dev slashing tests.

4. **Devnet smoke test**
   - `make -C avs devnet-start` to spin up operator nodes, funding utility contracts, and local Anvil.
   - `make -C avs devnet-stop` when finished.
   - Feed synthetic intents (from `scripts/intent_feeder.go`) and verify they reach EigenCompute within the 5 s window.
   - Confirm generated bundles propagate to watchers and ultimately to the hook on the devnet PoolManager.

## Key Reference Points
| Topic | DevKit Notes |
| --- | --- |
| Command layout | `pkg/commands/*` outlined in `static/devkit.md` (see “Go Development Guidelines” + CLI structure). |
| Context/registry | `config/` folders (contexts, keystores, templates) for migrating between versions. |
| Devnet scripts | `docker/anvil` + `pkg/commands/devnet.go` provide an end-to-end local cluster. |

We’ll evolve this doc as we customize the AVS (operator requirements, slash conditions, watcher APIs) and once EigenAI components are needed for advanced intent scoring. Diffs to the DevKit repo will live in `avs/patches/` when we start tracking them.

