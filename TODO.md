# EigenMatch CoW Hook - Development to Production TODO

## Phase 1: Project Setup & Infrastructure ✅

### 1.1 Foundry Environment Setup
- [x] Review README and documentation requirements
- [ ] Initialize Foundry project structure
- [ ] Install Uniswap v4-core and v4-periphery dependencies
- [ ] Configure foundry.toml (Solidity 0.8.26, Cancun EVM)
- [ ] Set up remappings.txt for clean imports
- [ ] Clone or reference v4-template for fixtures/utilities

### 1.2 Development Environment
- [ ] Set up local Anvil node for testing
- [ ] Create .env.example with required environment variables
- [ ] Set up Git workflow (branches, PR templates)
- [ ] Configure linting and formatting (solhint, prettier)

### 1.3 Documentation Foundation
- [x] PRD document completed
- [x] System design document completed
- [x] EigenCompute intent engine blueprint completed
- [ ] API specification document
- [ ] Testing strategy document

## Phase 2: Core Hook Development

### 2.1 Hook Contract Structure
- [ ] Create EigenMatchHook.sol extending BaseHook
- [ ] Define hook permissions (beforeSwap, afterSwap, etc.)
- [ ] Implement getHookPermissions() with correct flags
- [ ] Set up pool-specific storage mappings (PoolId keyed)
- [ ] Add settlement bundle validation logic

### 2.2 Hook Functions Implementation
- [ ] Implement `beforeSwap` hook
  - [ ] Validate settlement bundles
  - [ ] Calculate internal match deltas
  - [ ] Prepare residual swap params
- [ ] Implement `afterSwap` hook
  - [ ] Update fee ledger
  - [ ] Emit match events
- [ ] Implement `afterAddLiquidity` hook
  - [ ] Track LP contributions
  - [ ] Update matching eligibility
- [ ] Implement `afterRemoveLiquidity` hook
  - [ ] Handle LP withdrawals
- [ ] Implement `beforeDonate` / `afterDonate` hooks
  - [ ] Fee rebate logic
  - [ ] LP incentive distribution

### 2.3 Settlement & Matching Logic
- [ ] Create SettlementBundle struct with validation
- [ ] Implement mid-price calculation logic
- [ ] Add internal transfer mechanism (ERC20 transfers)
- [ ] Implement fallback to AMM for residuals
- [ ] Add replay protection (epoch + nonce checking)

### 2.4 Helper Contracts
- [ ] SettlementExecutor contract
  - [ ] Bundle verification
  - [ ] Fund transfer logic
  - [ ] Emergency pause functionality
- [ ] Treasury contract
  - [ ] Fee collection
  - [ ] Rebate distribution
- [ ] FeeLedger contract (ERC6909 or ERC20)
  - [ ] User balance tracking
  - [ ] Fee savings accounting

### 2.5 Hook Deployment Infrastructure
- [ ] Create HookMiner script for address mining
- [ ] Write deployment script with CREATE2
- [ ] Add pool initialization script
- [ ] Create upgrade/migration scripts
- [ ] Document deployment process

## Phase 3: EigenCompute Service Development

### 3.1 EigenCompute Environment Setup
- [ ] Install EigenX CLI
- [ ] Create EigenCompute authentication keys
- [ ] Set up billing subscription (Sepolia testnet first)
- [ ] Configure container registry (GHCR/DockerHub)
- [ ] Set up environment variable encryption

### 3.2 Intent Matching Service
- [ ] Create Dockerfile for matching service
- [ ] Implement intent ingestion API (gRPC/HTTP)
  - [ ] EIP-712 signature validation
  - [ ] Intent deduplication
  - [ ] Rate limiting
- [ ] Build deterministic matching algorithm
  - [ ] Order book normalization
  - [ ] Price-time priority matching
  - [ ] Clearing price calculation
  - [ ] Match group formation
- [ ] Implement settlement bundle generation
  - [ ] Bundle struct creation
  - [ ] Attestation signature
  - [ ] Replay salt generation

### 3.3 Determinism & Testing
- [ ] Ensure deterministic execution (no randomness)
- [ ] Use fixed-point math libraries
- [ ] Add deterministic test suite
- [ ] Create mock AVS intent feed for testing
- [ ] Validate attestation generation

### 3.4 Service APIs & Integration
- [ ] Expose gRPC endpoint for AVS operators
- [ ] Expose HTTPS endpoint for watchers
- [ ] Implement health check endpoints
- [ ] Add structured logging (JSON format)
- [ ] Set up metrics collection (Prometheus format)

## Phase 4: Bridging & Watcher Network

### 4.1 Watcher Service
- [ ] Create watcher service to monitor EigenCompute
- [ ] Implement attestation verification
  - [ ] Query EigenCompute verification dashboard
  - [ ] Validate Docker digest
  - [ ] Check TEE measurement
- [ ] Add replay protection checking
- [ ] Implement transaction sequencing
- [ ] Add multi-watcher consensus logic

### 4.2 Bridge Contracts
- [ ] Create MatchProofStore contract
  - [ ] Store Docker digest references
  - [ ] Track epoch metadata
- [ ] Implement settlement bundle validator
- [ ] Add allowlist management for trusted TEEs

### 4.3 Relay Infrastructure
- [ ] Set up watcher network deployment
- [ ] Implement rate limiting per block
- [ ] Add failover mechanisms
- [ ] Create monitoring dashboards

## Phase 5: Testing & Validation

### 5.1 Unit Tests
- [ ] Hook function unit tests (Foundry)
  - [ ] beforeSwap scenarios
  - [ ] afterSwap scenarios
  - [ ] Liquidity hook scenarios
  - [ ] Edge cases and error paths
- [ ] Settlement executor unit tests
- [ ] Treasury and fee ledger tests
- [ ] Helper contract tests

### 5.2 Integration Tests
- [ ] End-to-end intent flow test
  - [ ] Submit intent → AVS → TEE → Hook execution
- [ ] Multi-pool hook behavior tests
- [ ] Fallback to AMM tests
- [ ] Replay protection tests
- [ ] Attestation verification tests

### 5.3 Deterministic Tests
- [ ] Matching algorithm determinism tests
  - [ ] Same inputs → same outputs
  - [ ] Order independence
- [ ] Fixed-point math accuracy tests
- [ ] Cross-platform consistency checks

### 5.4 Security Testing
- [ ] Fuzz testing for hook functions
- [ ] Invariant testing
- [ ] Gas optimization analysis
- [ ] Access control tests
- [ ] Reentrancy protection tests

### 5.5 Integration with v4 Template
- [ ] Use v4-template fixtures for testing
- [ ] Test against actual PoolManager
- [ ] Validate hook permission bits
- [ ] Test with multiple pools simultaneously

## Phase 6: Deployment & Operations

### 6.1 Testnet Deployment (Sepolia)
- [ ] Deploy EigenCompute service to Sepolia
  - [ ] Verify attestation dashboard
  - [ ] Test service endpoints
- [ ] Deploy hook contracts to Sepolia
  - [ ] Mine hook address with correct flags
  - [ ] Deploy via CREATE2
  - [ ] Initialize test pools
- [ ] Deploy watcher network
- [ ] Deploy settlement executor
- [ ] End-to-end testnet validation

### 6.2 Monitoring & Observability
- [ ] Set up Prometheus metrics collection
- [ ] Create Grafana dashboards
  - [ ] Match ratio tracking
  - [ ] Fee savings metrics
  - [ ] Settlement latency
  - [ ] Hook gas usage
- [ ] Set up log aggregation
- [ ] Configure alerts (PagerDuty/Slack)
- [ ] Integrate EigenCompute verification links

### 6.3 Operations Runbooks
- [ ] TEE key rotation procedures
- [ ] Hook upgrade process
- [ ] EigenCompute redeployment guide
- [ ] Emergency pause procedures
- [ ] Pool parameter adjustment guide
- [ ] Incident response playbook

### 6.4 Security Audits
- [ ] Internal security review
- [ ] Schedule external Solidity audit
- [ ] EigenCompute enclave assessment
- [ ] Economic security review
- [ ] Fix all identified issues

## Phase 7: Production Readiness

### 7.1 Mainnet Preparation
- [ ] Reserve EigenCompute production quota
- [ ] Finalize mainnet deployment scripts
- [ ] Set up multi-sig for critical operations
- [ ] Prepare liquidity bootstrapping plan
- [ ] Coordinate with Uniswap routing teams

### 7.2 Staged Rollout
- [ ] Deploy to mainnet with caps
  - [ ] Max intent volume limits
  - [ ] Max settlement size limits
- [ ] Enable canary testing
- [ ] Gradual traffic ramp-up
- [ ] Monitor KPI performance

### 7.3 Launch Checklist
- [ ] All tests passing (unit, integration, security)
- [ ] Audits completed and issues resolved
- [ ] Monitoring and alerts configured
- [ ] Runbooks documented and tested
- [ ] Team trained on operations
- [ ] Liquidity provisioned
- [ ] Governance approvals obtained
- [ ] Legal/compliance review completed

### 7.4 Post-Launch
- [ ] Monitor KPIs (≥20% match ratio, ≥80% fee savings)
- [ ] Collect user feedback
- [ ] Optimize matching algorithm based on real data
- [ ] Scale infrastructure as needed
- [ ] Plan feature enhancements

## Open Questions to Resolve
- [ ] Which EIP-712 domain separator for intent signatures?
- [ ] AVS operator slashable conditions specification?
- [ ] EigenCompute production capacity commitments?
- [ ] Uniswap Interface/UniswapX routing integration plan?

