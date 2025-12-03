// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager, SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {
    BeforeSwapDelta,
    BeforeSwapDeltaLibrary,
    toBeforeSwapDelta
} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";

/// @title EigenMatchHook
/// @notice Uniswap v4 hook for Coincidence-of-Wants intent netting
/// @dev This hook intercepts swaps and applies internal settlement from EigenCompute TEE matching,
///      only routing unmatched residuals to the AMM. Matched volume settles at mid-price with zero fees.
contract EigenMatchHook is BaseHook, Ownable {
    using PoolIdLibrary for PoolKey;

    // =============================================================
    // STATE VARIABLES
    // =============================================================

    /// @notice Settlement executor authorized to submit settlement bundles
    address public settlementExecutor;

    /// @notice Per-pool configuration for supported pairs and settings
    mapping(PoolId => PoolConfig) private poolConfigs;

    /// @notice Pending settlements per pool and trader
    mapping(PoolId => mapping(address => TraderSettlement)) private pendingSettlements;

    /// @notice Tracks processed settlement bundles to prevent replay attacks
    mapping(bytes32 => bool) public processedBundles;

    /// @notice Fee ledger tracking matched volume and savings per user
    mapping(address => FeeLedgerEntry) public feeLedger;

    /// @notice Emergency pause flag for each pool
    mapping(PoolId => bool) public paused;

    // =============================================================
    // STRUCTS
    // =============================================================

    /// @notice Configuration for a pool enabled with EigenMatch
    struct PoolConfig {
        bool enabled; // Whether this pool uses EigenMatch
        uint64 maxSettlementDelay; // Seconds allowed between bundle creation and processing
        bytes32[] allowedDockerDigests; // Allow-listed EigenCompute docker digests
    }

    /// @notice Settlement bundle from EigenCompute TEE matching engine
    struct SettlementBundle {
        uint64 epoch; // Matching epoch timestamp/identifier
        bytes32 bundleId; // Unique bundle identifier (keccak256 hash)
        MatchGroup[] matchGroups; // Groups of matched intents
        bytes32 teeMeasurement; // TEE hardware measurement
        bytes32 dockerDigest; // Docker image digest
        bytes attestationSignature; // TEE attestation signature
        bytes32 replaySalt; // Epoch + nonce for replay protection
    }

    /// @notice Group of intents that were matched internally
    struct MatchGroup {
        bytes32[] intentIds; // IDs of matched intents
        uint256 clearingPrice; // Mid-market clearing price (Q64.96)
        uint256 matchedAmount; // Total matched amount
        uint16 feesSavedBps; // Fee savings in basis points
    }

    /// @notice Trader settlement instruction queued by the settlement executor
    struct TraderSettlementInput {
        address trader; // Address receiving the settlement
        int256 deltaSpecified; // Specified token delta applied in beforeSwap (int128 range)
        int256 deltaUnspecified; // Unspecified token delta applied in beforeSwap (int128 range)
        uint256 feeSaved; // Fee savings attributed to this trader
        uint64 expiry; // Timestamp after which the settlement expires
    }

    /// @notice Fee ledger entry tracking user savings
    struct FeeLedgerEntry {
        uint256 matchedVolume; // Total volume matched internally (in specified token units)
        uint256 feeSaved; // Total fees saved (in quote token)
        uint64 lastUpdated; // Timestamp of last update
    }

    /// @notice Stored settlement ready to be consumed by the next swap
    struct TraderSettlement {
        BeforeSwapDelta delta; // Delta applied in beforeSwap
        uint64 expiry; // Expiry timestamp
        bytes32 bundleId; // Bundle that created the settlement
        uint256 feeSaved; // Fee savings for reporting
    }

    // =============================================================
    // EVENTS
    // =============================================================

    /// @notice Emitted when a settlement bundle is processed
    event BundleProcessed(
        PoolId indexed poolId, bytes32 indexed bundleId, uint64 epoch, uint256 totalMatched, uint256 totalSaved
    );

    /// @notice Emitted when internal match is settled
    event InternalMatchSettled(
        PoolId indexed poolId, address indexed traderA, address indexed traderB, uint256 amount, uint256 clearingPrice
    );

    /// @notice Emitted when residual order is routed to AMM
    event ResidualRouted(PoolId indexed poolId, address indexed trader, uint256 amount);

    /// @notice Emitted when pool is paused/unpaused
    event PoolPaused(PoolId indexed poolId, bool paused);

    /// @notice Emitted when a settlement instruction is queued
    event SettlementQueued(
        PoolId indexed poolId,
        address indexed trader,
        bytes32 indexed bundleId,
        int128 deltaSpecified,
        int128 deltaUnspecified,
        uint64 expiry
    );

    /// @notice Emitted when a trader consumes a queued settlement
    event SettlementConsumed(
        PoolId indexed poolId, address indexed trader, bytes32 indexed bundleId, uint256 matchedVolume, uint256 feeSaved
    );

    // =============================================================
    // ERRORS
    // =============================================================

    error NotSettlementExecutor();
    error PoolNotEnabled();
    error BundleAlreadyProcessed();
    error InvalidBundle();
    error PoolIsPaused();
    error SettlementExpired();
    error InvalidAttestation();
    error InsufficientLiquidity();
    error InvalidConfig();
    error SettlementNotFound();

    // =============================================================
    // CONSTRUCTOR
    // =============================================================

    constructor(IPoolManager _poolManager, address _settlementExecutor, address _owner)
        BaseHook(_poolManager)
        Ownable(_owner)
    {
        if (_owner == address(0) || _settlementExecutor == address(0)) revert InvalidConfig();
        settlementExecutor = _settlementExecutor;
    }

    // =============================================================
    // HOOK PERMISSIONS
    // =============================================================

    /// @notice Returns the hook permissions for this contract
    /// @dev Permissions are encoded in the hook address during deployment
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true, // Apply internal settlements before swap
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // =============================================================
    // HOOK FUNCTIONS
    // =============================================================

    /// @notice Called before a swap is executed
    /// @dev Applies queued settlement deltas from EigenCompute bundle before executing the AMM swap.
    function _beforeSwap(address sender, PoolKey calldata key, SwapParams calldata, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId poolId = key.toId();

        // Check if pool is paused
        if (paused[poolId]) revert PoolIsPaused();

        // Check if pool is enabled for EigenMatch
        PoolConfig storage config = poolConfigs[poolId];
        if (!config.enabled) {
            return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        TraderSettlement storage settlement = pendingSettlements[poolId][sender];
        if (settlement.bundleId == bytes32(0)) {
            // no queued settlement
            return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        if (block.timestamp > settlement.expiry) {
            delete pendingSettlements[poolId][sender];
            revert SettlementExpired();
        }

        (BeforeSwapDelta delta,) = _finalizeSettlement(poolId, sender, settlement);

        return (BaseHook.beforeSwap.selector, delta, 0);
    }

    // =============================================================
    // SETTLEMENT FUNCTIONS
    // =============================================================

    /// @notice Processes a settlement bundle from EigenCompute TEE
    /// @dev Can only be called by the settlement executor
    /// @param poolId The pool this settlement applies to
    /// @param bundle The settlement bundle with matched intents
    /// @param traderSettlements Individual trader settlement instructions
    function processSettlementBundle(
        PoolId poolId,
        SettlementBundle calldata bundle,
        TraderSettlementInput[] calldata traderSettlements
    ) external {
        if (msg.sender != settlementExecutor) revert NotSettlementExecutor();

        // Validate bundle hasn't been processed
        if (processedBundles[bundle.bundleId]) revert BundleAlreadyProcessed();

        // Validate pool is enabled
        PoolConfig storage config = poolConfigs[poolId];
        if (!config.enabled) revert PoolNotEnabled();

        // Validate replay protection
        bytes32 replayKey = keccak256(abi.encodePacked(poolId, bundle.replaySalt));
        if (processedBundles[replayKey]) revert BundleAlreadyProcessed();

        // Validate docker digest allowlist
        if (!_isAllowedDigest(config.allowedDockerDigests, bundle.dockerDigest)) revert InvalidAttestation();

        // Validate settlement delay if configured (interpret epoch as timestamp)
        if (config.maxSettlementDelay > 0 && block.timestamp > bundle.epoch + config.maxSettlementDelay) {
            revert SettlementExpired();
        }

        if (traderSettlements.length == 0) revert InvalidBundle();

        // Mark bundle as processed
        processedBundles[bundle.bundleId] = true;
        processedBundles[replayKey] = true;

        uint256 totalMatched;
        uint256 totalSaved;

        for (uint256 i = 0; i < traderSettlements.length; i++) {
            TraderSettlementInput calldata input = traderSettlements[i];
            _queueSettlement(poolId, bundle.bundleId, input);

            totalSaved += input.feeSaved;
            totalMatched += _absInt128(_toInt128(input.deltaSpecified));
        }

        emit BundleProcessed(poolId, bundle.bundleId, bundle.epoch, totalMatched, totalSaved);
    }

    // =============================================================
    // ADMIN FUNCTIONS
    // =============================================================

    /// @notice Enables EigenMatch for a pool
    /// @dev Sets pool configuration and allows settlement processing
    function enablePool(PoolId poolId, PoolConfig calldata config) external onlyOwner {
        _setPoolConfig(poolId, config);
    }

    /// @notice Updates the settlement executor address
    function setSettlementExecutor(address _executor) external onlyOwner {
        if (_executor == address(0)) revert InvalidConfig();
        settlementExecutor = _executor;
    }

    /// @notice Pauses/unpauses a pool
    /// @dev Emergency stop for settlement processing
    function setPoolPaused(PoolId poolId, bool _paused) external onlyOwner {
        paused[poolId] = _paused;
        emit PoolPaused(poolId, _paused);
    }

    // =============================================================
    // VIEW FUNCTIONS
    // =============================================================

    /// @notice Returns the pool configuration for a poolId
    function getPoolConfig(PoolId poolId) external view returns (PoolConfig memory config) {
        PoolConfig storage stored = poolConfigs[poolId];
        config.enabled = stored.enabled;
        config.maxSettlementDelay = stored.maxSettlementDelay;
        config.allowedDockerDigests = stored.allowedDockerDigests;
    }

    /// @notice Gets fee ledger entry for a user
    function getFeeLedger(address user) external view returns (FeeLedgerEntry memory) {
        return feeLedger[user];
    }

    /// @notice Checks if a bundle has been processed
    function isBundleProcessed(bytes32 bundleId) external view returns (bool) {
        return processedBundles[bundleId];
    }

    /// @notice Returns a queued settlement for a trader if present
    function getPendingSettlement(PoolId poolId, address trader) external view returns (TraderSettlement memory) {
        return pendingSettlements[poolId][trader];
    }

    // =============================================================
    // INTERNAL HELPERS
    // =============================================================

    function _queueSettlement(PoolId poolId, bytes32 bundleId, TraderSettlementInput calldata input) internal {
        if (input.trader == address(0)) revert InvalidBundle();
        if (input.expiry <= block.timestamp) revert SettlementExpired();

        int128 specified = _toInt128(input.deltaSpecified);
        int128 unspecified = _toInt128(input.deltaUnspecified);

        TraderSettlement storage settlement = pendingSettlements[poolId][input.trader];
        settlement.delta = toBeforeSwapDelta(specified, unspecified);
        settlement.expiry = input.expiry;
        settlement.bundleId = bundleId;
        settlement.feeSaved = input.feeSaved;

        emit SettlementQueued(poolId, input.trader, bundleId, specified, unspecified, input.expiry);
    }

    function _setPoolConfig(PoolId poolId, PoolConfig calldata config) internal {
        if (config.maxSettlementDelay == 0) revert InvalidConfig();

        PoolConfig storage stored = poolConfigs[poolId];
        stored.enabled = config.enabled;
        stored.maxSettlementDelay = config.maxSettlementDelay;

        delete stored.allowedDockerDigests;
        for (uint256 i = 0; i < config.allowedDockerDigests.length; i++) {
            stored.allowedDockerDigests.push(config.allowedDockerDigests[i]);
        }
    }

    function _isAllowedDigest(bytes32[] storage digests, bytes32 digest) internal view returns (bool) {
        if (digest == bytes32(0)) return false;
        for (uint256 i = 0; i < digests.length; i++) {
            if (digests[i] == digest) return true;
        }
        return false;
    }

    function _absInt128(int128 value) internal pure returns (uint256) {
        return value >= 0 ? uint256(int256(value)) : uint256(int256(-value));
    }

    function _toInt128(int256 value) internal pure returns (int128 castValue) {
        if (value > type(int128).max || value < type(int128).min) revert InvalidBundle();
        castValue = int128(value);
    }

    function _finalizeSettlement(
        PoolId poolId,
        address trader,
        TraderSettlement storage settlement
    ) internal returns (BeforeSwapDelta delta, uint256 matchedVolume) {
        TraderSettlement memory data = settlement;
        delete pendingSettlements[poolId][trader];

        delta = data.delta;
        int128 specified = BeforeSwapDeltaLibrary.getSpecifiedDelta(delta);
        matchedVolume = _absInt128(specified);

        FeeLedgerEntry storage entry = feeLedger[trader];
        entry.matchedVolume += matchedVolume;
        entry.feeSaved += data.feeSaved;
        entry.lastUpdated = uint64(block.timestamp);

        emit SettlementConsumed(poolId, trader, data.bundleId, matchedVolume, data.feeSaved);
    }
}

