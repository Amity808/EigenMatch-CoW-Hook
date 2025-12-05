// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "../src/EigenMatchHook.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

contract EigenMatchHookHarness is EigenMatchHook {
    constructor(address executor, address owner)
        EigenMatchHook(IPoolManager(address(0)), executor, owner)
    {}

    function invokeBeforeSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        bytes calldata hookData
    ) external returns (BeforeSwapDelta delta) {
        (, BeforeSwapDelta beforeDelta,) = _beforeSwap(sender, key, params, hookData);
        return beforeDelta;
    }
}

contract EigenMatchHookTest is Test {
    EigenMatchHookHarness private hook;
    PoolKey private poolKey;
    PoolId private poolId;
    address private trader;

    function setUp() public {
        address hookAddress = address(uint160(Hooks.BEFORE_SWAP_FLAG));
        deployCodeTo(
            "test/EigenMatchHook.t.sol:EigenMatchHookHarness",
            abi.encode(address(this), address(this)),
            hookAddress
        );
        hook = EigenMatchHookHarness(hookAddress);

        trader = address(0xBEEF);
        poolKey = PoolKey({
            currency0: Currency.wrap(address(0xAAA0)),
            currency1: Currency.wrap(address(0xBBB0)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        poolId = poolKey.toId();

        bytes32[] memory digests = new bytes32[](1);
        digests[0] = keccak256("digest-1");
        hook.enablePool(
            poolId,
            EigenMatchHook.PoolConfig({
                enabled: true,
                maxSettlementDelay: 120,
                allowedDockerDigests: digests
            })
        );
    }

    function testBeforeSwapConsumesSettlement() public {
        EigenMatchHook.PoolConfig memory configSnapshot = hook.getPoolConfig(poolId);
        bytes32 digest = configSnapshot.allowedDockerDigests[0];
        bytes32 bundleId = keccak256("bundle-1");

        EigenMatchHook.TraderSettlementInput[] memory instructions =
            new EigenMatchHook.TraderSettlementInput[](1);
        instructions[0] = EigenMatchHook.TraderSettlementInput({
            trader: trader,
            deltaSpecified: int256(1 ether),
            deltaUnspecified: int256(0),
            feeSaved: 100,
            expiry: uint64(block.timestamp + 60)
        });

        EigenMatchHook.SettlementBundle memory bundle = EigenMatchHook.SettlementBundle({
            epoch: uint64(block.timestamp),
            bundleId: bundleId,
            matchGroups: new EigenMatchHook.MatchGroup[](0),
            teeMeasurement: bytes32(0),
            dockerDigest: digest,
            attestationSignature: "",
            replaySalt: keccak256("salt-1")
        });

        SwapParams memory params = SwapParams({zeroForOne: false, amountSpecified: 0, sqrtPriceLimitX96: 0});
        hook.processSettlementBundle(poolId, bundle, instructions);
        hook.invokeBeforeSwap(trader, poolKey, params, "");

        EigenMatchHook.FeeLedgerEntry memory entry = hook.getFeeLedger(trader);
        assertEq(entry.matchedVolume, 1 ether);
        assertEq(entry.feeSaved, 100);

        EigenMatchHook.TraderSettlement memory pending =
            hook.getPendingSettlement(poolId, trader);
        assertEq(pending.bundleId, bytes32(0));
    }

    function testProcessBundleRejectsInvalidDigest() public {
        EigenMatchHook.TraderSettlementInput[] memory instructions =
            new EigenMatchHook.TraderSettlementInput[](1);
        instructions[0] = EigenMatchHook.TraderSettlementInput({
            trader: trader,
            deltaSpecified: int256(1),
            deltaUnspecified: int256(0),
            feeSaved: 0,
            expiry: uint64(block.timestamp + 60)
        });

        EigenMatchHook.SettlementBundle memory bundle = EigenMatchHook.SettlementBundle({
            epoch: uint64(block.timestamp),
            bundleId: keccak256("bundle-bad"),
            matchGroups: new EigenMatchHook.MatchGroup[](0),
            teeMeasurement: bytes32(0),
            dockerDigest: keccak256("bad-digest"),
            attestationSignature: "",
            replaySalt: keccak256("salt-2")
        });

        vm.expectRevert(EigenMatchHook.InvalidAttestation.selector);
        hook.processSettlementBundle(poolId, bundle, instructions);
    }

    function testBeforeSwapRevertsWhenExpired() public {
        bytes32 digest = hook.getPoolConfig(poolId).allowedDockerDigests[0];
        EigenMatchHook.TraderSettlementInput[] memory instructions =
            new EigenMatchHook.TraderSettlementInput[](1);
        instructions[0] = EigenMatchHook.TraderSettlementInput({
            trader: trader,
            deltaSpecified: int256(1),
            deltaUnspecified: int256(0),
            feeSaved: 0,
            expiry: uint64(block.timestamp + 1)
        });

        EigenMatchHook.SettlementBundle memory bundle = EigenMatchHook.SettlementBundle({
            epoch: uint64(block.timestamp),
            bundleId: keccak256("bundle-expire"),
            matchGroups: new EigenMatchHook.MatchGroup[](0),
            teeMeasurement: bytes32(0),
            dockerDigest: digest,
            attestationSignature: "",
            replaySalt: keccak256("salt-3")
        });

        hook.processSettlementBundle(poolId, bundle, instructions);

        vm.warp(block.timestamp + 2);
        SwapParams memory params = SwapParams({zeroForOne: false, amountSpecified: 0, sqrtPriceLimitX96: 0});
        vm.expectRevert(EigenMatchHook.SettlementExpired.selector);
        hook.invokeBeforeSwap(trader, poolKey, params, "");
    }

    // =============================================================
    // ADMIN FUNCTION TESTS
    // =============================================================

    function testSetSettlementExecutor() public {
        address newExecutor = address(0xCAFE);
        hook.setSettlementExecutor(newExecutor);
        assertEq(hook.settlementExecutor(), newExecutor);
    }

    function testSetSettlementExecutorRevertsOnZeroAddress() public {
        vm.expectRevert(EigenMatchHook.InvalidConfig.selector);
        hook.setSettlementExecutor(address(0));
    }

    function testSetPoolPaused() public {
        hook.setPoolPaused(poolId, true);
        assertTrue(hook.paused(poolId));
        
        hook.setPoolPaused(poolId, false);
        assertFalse(hook.paused(poolId));
    }

    function testEnablePoolWithInvalidConfig() public {
        bytes32[] memory digests = new bytes32[](1);
        digests[0] = keccak256("digest-2");
        
        vm.expectRevert(EigenMatchHook.InvalidConfig.selector);
        hook.enablePool(
            poolKey.toId(),
            EigenMatchHook.PoolConfig({
                enabled: true,
                maxSettlementDelay: 0, // Invalid: must be > 0
                allowedDockerDigests: digests
            })
        );
    }

    function testEnablePoolUpdatesConfig() public {
        bytes32[] memory digests = new bytes32[](2);
        digests[0] = keccak256("digest-new-1");
        digests[1] = keccak256("digest-new-2");
        
        hook.enablePool(
            poolId,
            EigenMatchHook.PoolConfig({
                enabled: false,
                maxSettlementDelay: 240,
                allowedDockerDigests: digests
            })
        );
        
        EigenMatchHook.PoolConfig memory config = hook.getPoolConfig(poolId);
        assertFalse(config.enabled);
        assertEq(config.maxSettlementDelay, 240);
        assertEq(config.allowedDockerDigests.length, 2);
        assertEq(config.allowedDockerDigests[0], digests[0]);
        assertEq(config.allowedDockerDigests[1], digests[1]);
    }

    // =============================================================
    // BEFORE SWAP EDGE CASES
    // =============================================================

    function testBeforeSwapWhenPoolPaused() public {
        hook.setPoolPaused(poolId, true);
        
        SwapParams memory params = SwapParams({zeroForOne: false, amountSpecified: 0, sqrtPriceLimitX96: 0});
        vm.expectRevert(EigenMatchHook.PoolIsPaused.selector);
        hook.invokeBeforeSwap(trader, poolKey, params, "");
    }

    function testBeforeSwapWhenPoolNotEnabled() public {
        // Create a new pool that's not enabled
        PoolKey memory newPoolKey = PoolKey({
            currency0: Currency.wrap(address(0xCCC0)),
            currency1: Currency.wrap(address(0xDDD0)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        PoolId newPoolId = newPoolKey.toId();
        
        SwapParams memory params = SwapParams({zeroForOne: false, amountSpecified: 0, sqrtPriceLimitX96: 0});
        // Should return zero delta without reverting
        BeforeSwapDelta delta = hook.invokeBeforeSwap(trader, newPoolKey, params, "");
        // Verify it's zero delta (no settlement applied)
        assertEq(uint256(bytes32(abi.encode(delta))), 0);
    }

    function testBeforeSwapWhenNoSettlementQueued() public {
        SwapParams memory params = SwapParams({zeroForOne: false, amountSpecified: 0, sqrtPriceLimitX96: 0});
        // Should return zero delta without reverting
        BeforeSwapDelta delta = hook.invokeBeforeSwap(trader, poolKey, params, "");
        // Verify it's zero delta
        assertEq(uint256(bytes32(abi.encode(delta))), 0);
    }

    // =============================================================
    // PROCESS SETTLEMENT BUNDLE ERROR CASES
    // =============================================================

    function testProcessBundleRevertsWhenNotExecutor() public {
        bytes32 digest = hook.getPoolConfig(poolId).allowedDockerDigests[0];
        EigenMatchHook.TraderSettlementInput[] memory instructions =
            new EigenMatchHook.TraderSettlementInput[](1);
        instructions[0] = EigenMatchHook.TraderSettlementInput({
            trader: trader,
            deltaSpecified: int256(1),
            deltaUnspecified: int256(0),
            feeSaved: 0,
            expiry: uint64(block.timestamp + 60)
        });

        EigenMatchHook.SettlementBundle memory bundle = EigenMatchHook.SettlementBundle({
            epoch: uint64(block.timestamp),
            bundleId: keccak256("bundle-unauthorized"),
            matchGroups: new EigenMatchHook.MatchGroup[](0),
            teeMeasurement: bytes32(0),
            dockerDigest: digest,
            attestationSignature: "",
            replaySalt: keccak256("salt-4")
        });

        vm.prank(address(0xBAD));
        vm.expectRevert(EigenMatchHook.NotSettlementExecutor.selector);
        hook.processSettlementBundle(poolId, bundle, instructions);
    }

    function testProcessBundleRevertsWhenPoolNotEnabled() public {
        // Create a new pool that's not enabled
        PoolKey memory newPoolKey = PoolKey({
            currency0: Currency.wrap(address(0xEEE0)),
            currency1: Currency.wrap(address(0xFFF0)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        PoolId newPoolId = newPoolKey.toId();

        bytes32 digest = hook.getPoolConfig(poolId).allowedDockerDigests[0];
        EigenMatchHook.TraderSettlementInput[] memory instructions =
            new EigenMatchHook.TraderSettlementInput[](1);
        instructions[0] = EigenMatchHook.TraderSettlementInput({
            trader: trader,
            deltaSpecified: int256(1),
            deltaUnspecified: int256(0),
            feeSaved: 0,
            expiry: uint64(block.timestamp + 60)
        });

        EigenMatchHook.SettlementBundle memory bundle = EigenMatchHook.SettlementBundle({
            epoch: uint64(block.timestamp),
            bundleId: keccak256("bundle-not-enabled"),
            matchGroups: new EigenMatchHook.MatchGroup[](0),
            teeMeasurement: bytes32(0),
            dockerDigest: digest,
            attestationSignature: "",
            replaySalt: keccak256("salt-5")
        });

        vm.expectRevert(EigenMatchHook.PoolNotEnabled.selector);
        hook.processSettlementBundle(newPoolId, bundle, instructions);
    }

    function testProcessBundleRevertsWhenAlreadyProcessed() public {
        bytes32 digest = hook.getPoolConfig(poolId).allowedDockerDigests[0];
        bytes32 bundleId = keccak256("bundle-duplicate");
        
        EigenMatchHook.TraderSettlementInput[] memory instructions =
            new EigenMatchHook.TraderSettlementInput[](1);
        instructions[0] = EigenMatchHook.TraderSettlementInput({
            trader: trader,
            deltaSpecified: int256(1),
            deltaUnspecified: int256(0),
            feeSaved: 0,
            expiry: uint64(block.timestamp + 60)
        });

        EigenMatchHook.SettlementBundle memory bundle = EigenMatchHook.SettlementBundle({
            epoch: uint64(block.timestamp),
            bundleId: bundleId,
            matchGroups: new EigenMatchHook.MatchGroup[](0),
            teeMeasurement: bytes32(0),
            dockerDigest: digest,
            attestationSignature: "",
            replaySalt: keccak256("salt-6")
        });

        hook.processSettlementBundle(poolId, bundle, instructions);
        
        // Try to process again
        vm.expectRevert(EigenMatchHook.BundleAlreadyProcessed.selector);
        hook.processSettlementBundle(poolId, bundle, instructions);
    }

    function testProcessBundleRevertsOnReplaySaltCollision() public {
        bytes32 digest = hook.getPoolConfig(poolId).allowedDockerDigests[0];
        bytes32 replaySalt = keccak256("salt-replay");
        
        EigenMatchHook.TraderSettlementInput[] memory instructions =
            new EigenMatchHook.TraderSettlementInput[](1);
        instructions[0] = EigenMatchHook.TraderSettlementInput({
            trader: trader,
            deltaSpecified: int256(1),
            deltaUnspecified: int256(0),
            feeSaved: 0,
            expiry: uint64(block.timestamp + 60)
        });

        EigenMatchHook.SettlementBundle memory bundle1 = EigenMatchHook.SettlementBundle({
            epoch: uint64(block.timestamp),
            bundleId: keccak256("bundle-1"),
            matchGroups: new EigenMatchHook.MatchGroup[](0),
            teeMeasurement: bytes32(0),
            dockerDigest: digest,
            attestationSignature: "",
            replaySalt: replaySalt
        });

        EigenMatchHook.SettlementBundle memory bundle2 = EigenMatchHook.SettlementBundle({
            epoch: uint64(block.timestamp),
            bundleId: keccak256("bundle-2"),
            matchGroups: new EigenMatchHook.MatchGroup[](0),
            teeMeasurement: bytes32(0),
            dockerDigest: digest,
            attestationSignature: "",
            replaySalt: replaySalt // Same replay salt
        });

        hook.processSettlementBundle(poolId, bundle1, instructions);
        
        // Try to process bundle with same replay salt
        vm.expectRevert(EigenMatchHook.BundleAlreadyProcessed.selector);
        hook.processSettlementBundle(poolId, bundle2, instructions);
    }

    function testProcessBundleRevertsOnZeroDigest() public {
        EigenMatchHook.TraderSettlementInput[] memory instructions =
            new EigenMatchHook.TraderSettlementInput[](1);
        instructions[0] = EigenMatchHook.TraderSettlementInput({
            trader: trader,
            deltaSpecified: int256(1),
            deltaUnspecified: int256(0),
            feeSaved: 0,
            expiry: uint64(block.timestamp + 60)
        });

        EigenMatchHook.SettlementBundle memory bundle = EigenMatchHook.SettlementBundle({
            epoch: uint64(block.timestamp),
            bundleId: keccak256("bundle-zero-digest"),
            matchGroups: new EigenMatchHook.MatchGroup[](0),
            teeMeasurement: bytes32(0),
            dockerDigest: bytes32(0), // Zero digest should be rejected
            attestationSignature: "",
            replaySalt: keccak256("salt-7")
        });

        vm.expectRevert(EigenMatchHook.InvalidAttestation.selector);
        hook.processSettlementBundle(poolId, bundle, instructions);
    }

    function testProcessBundleRevertsOnSettlementDelayExceeded() public {
        bytes32 digest = hook.getPoolConfig(poolId).allowedDockerDigests[0];
        
        // Set a fixed timestamp to avoid underflow
        uint256 baseTime = 1000000;
        vm.warp(baseTime);
        
        EigenMatchHook.TraderSettlementInput[] memory instructions =
            new EigenMatchHook.TraderSettlementInput[](1);
        instructions[0] = EigenMatchHook.TraderSettlementInput({
            trader: trader,
            deltaSpecified: int256(1),
            deltaUnspecified: int256(0),
            feeSaved: 0,
            expiry: uint64(block.timestamp + 60)
        });

        // Bundle epoch is too old (maxSettlementDelay is 120, so epoch + 121 should fail)
        EigenMatchHook.SettlementBundle memory bundle = EigenMatchHook.SettlementBundle({
            epoch: uint64(baseTime - 121), // Too old
            bundleId: keccak256("bundle-delayed"),
            matchGroups: new EigenMatchHook.MatchGroup[](0),
            teeMeasurement: bytes32(0),
            dockerDigest: digest,
            attestationSignature: "",
            replaySalt: keccak256("salt-8")
        });

        vm.expectRevert(EigenMatchHook.SettlementExpired.selector);
        hook.processSettlementBundle(poolId, bundle, instructions);
    }

    function testProcessBundleAllowsSettlementAtMaxDelay() public {
        bytes32 digest = hook.getPoolConfig(poolId).allowedDockerDigests[0];
        
        // Set a fixed timestamp to avoid underflow
        uint256 baseTime = 1000000;
        vm.warp(baseTime);
        
        EigenMatchHook.TraderSettlementInput[] memory instructions =
            new EigenMatchHook.TraderSettlementInput[](1);
        instructions[0] = EigenMatchHook.TraderSettlementInput({
            trader: trader,
            deltaSpecified: int256(1),
            deltaUnspecified: int256(0),
            feeSaved: 0,
            expiry: uint64(block.timestamp + 60)
        });

        // Bundle epoch is exactly at max delay (should pass)
        EigenMatchHook.SettlementBundle memory bundle = EigenMatchHook.SettlementBundle({
            epoch: uint64(baseTime - 120), // Exactly at max delay
            bundleId: keccak256("bundle-max-delay"),
            matchGroups: new EigenMatchHook.MatchGroup[](0),
            teeMeasurement: bytes32(0),
            dockerDigest: digest,
            attestationSignature: "",
            replaySalt: keccak256("salt-9")
        });

        // Should not revert
        hook.processSettlementBundle(poolId, bundle, instructions);
    }

    function testProcessBundleRevertsOnEmptyInstructions() public {
        bytes32 digest = hook.getPoolConfig(poolId).allowedDockerDigests[0];
        
        EigenMatchHook.TraderSettlementInput[] memory instructions =
            new EigenMatchHook.TraderSettlementInput[](0); // Empty array

        EigenMatchHook.SettlementBundle memory bundle = EigenMatchHook.SettlementBundle({
            epoch: uint64(block.timestamp),
            bundleId: keccak256("bundle-empty"),
            matchGroups: new EigenMatchHook.MatchGroup[](0),
            teeMeasurement: bytes32(0),
            dockerDigest: digest,
            attestationSignature: "",
            replaySalt: keccak256("salt-10")
        });

        vm.expectRevert(EigenMatchHook.InvalidBundle.selector);
        hook.processSettlementBundle(poolId, bundle, instructions);
    }

    function testProcessBundleRevertsOnZeroTrader() public {
        bytes32 digest = hook.getPoolConfig(poolId).allowedDockerDigests[0];
        
        EigenMatchHook.TraderSettlementInput[] memory instructions =
            new EigenMatchHook.TraderSettlementInput[](1);
        instructions[0] = EigenMatchHook.TraderSettlementInput({
            trader: address(0), // Zero address
            deltaSpecified: int256(1),
            deltaUnspecified: int256(0),
            feeSaved: 0,
            expiry: uint64(block.timestamp + 60)
        });

        EigenMatchHook.SettlementBundle memory bundle = EigenMatchHook.SettlementBundle({
            epoch: uint64(block.timestamp),
            bundleId: keccak256("bundle-zero-trader"),
            matchGroups: new EigenMatchHook.MatchGroup[](0),
            teeMeasurement: bytes32(0),
            dockerDigest: digest,
            attestationSignature: "",
            replaySalt: keccak256("salt-11")
        });

        vm.expectRevert(EigenMatchHook.InvalidBundle.selector);
        hook.processSettlementBundle(poolId, bundle, instructions);
    }

    function testProcessBundleRevertsOnExpiredSettlement() public {
        bytes32 digest = hook.getPoolConfig(poolId).allowedDockerDigests[0];
        
        EigenMatchHook.TraderSettlementInput[] memory instructions =
            new EigenMatchHook.TraderSettlementInput[](1);
        instructions[0] = EigenMatchHook.TraderSettlementInput({
            trader: trader,
            deltaSpecified: int256(1),
            deltaUnspecified: int256(0),
            feeSaved: 0,
            expiry: uint64(block.timestamp - 1) // Already expired
        });

        EigenMatchHook.SettlementBundle memory bundle = EigenMatchHook.SettlementBundle({
            epoch: uint64(block.timestamp),
            bundleId: keccak256("bundle-expired-input"),
            matchGroups: new EigenMatchHook.MatchGroup[](0),
            teeMeasurement: bytes32(0),
            dockerDigest: digest,
            attestationSignature: "",
            replaySalt: keccak256("salt-12")
        });

        vm.expectRevert(EigenMatchHook.SettlementExpired.selector);
        hook.processSettlementBundle(poolId, bundle, instructions);
    }

    // =============================================================
    // INT128 OVERFLOW/UNDERFLOW TESTS
    // =============================================================

    function testProcessBundleRevertsOnInt128Overflow() public {
        bytes32 digest = hook.getPoolConfig(poolId).allowedDockerDigests[0];
        
        EigenMatchHook.TraderSettlementInput[] memory instructions =
            new EigenMatchHook.TraderSettlementInput[](1);
        instructions[0] = EigenMatchHook.TraderSettlementInput({
            trader: trader,
            deltaSpecified: int256(uint256(int256(type(int128).max)) + 1), // Overflow
            deltaUnspecified: int256(0),
            feeSaved: 0,
            expiry: uint64(block.timestamp + 60)
        });

        EigenMatchHook.SettlementBundle memory bundle = EigenMatchHook.SettlementBundle({
            epoch: uint64(block.timestamp),
            bundleId: keccak256("bundle-overflow"),
            matchGroups: new EigenMatchHook.MatchGroup[](0),
            teeMeasurement: bytes32(0),
            dockerDigest: digest,
            attestationSignature: "",
            replaySalt: keccak256("salt-13")
        });

        vm.expectRevert(EigenMatchHook.InvalidBundle.selector);
        hook.processSettlementBundle(poolId, bundle, instructions);
    }

    function testProcessBundleRevertsOnInt128Underflow() public {
        bytes32 digest = hook.getPoolConfig(poolId).allowedDockerDigests[0];
        
        EigenMatchHook.TraderSettlementInput[] memory instructions =
            new EigenMatchHook.TraderSettlementInput[](1);
        instructions[0] = EigenMatchHook.TraderSettlementInput({
            trader: trader,
            deltaSpecified: int256(int256(type(int128).min) - 1), // Underflow
            deltaUnspecified: int256(0),
            feeSaved: 0,
            expiry: uint64(block.timestamp + 60)
        });

        EigenMatchHook.SettlementBundle memory bundle = EigenMatchHook.SettlementBundle({
            epoch: uint64(block.timestamp),
            bundleId: keccak256("bundle-underflow"),
            matchGroups: new EigenMatchHook.MatchGroup[](0),
            teeMeasurement: bytes32(0),
            dockerDigest: digest,
            attestationSignature: "",
            replaySalt: keccak256("salt-14")
        });

        vm.expectRevert(EigenMatchHook.InvalidBundle.selector);
        hook.processSettlementBundle(poolId, bundle, instructions);
    }

    function testProcessBundleWithNegativeDeltas() public {
        bytes32 digest = hook.getPoolConfig(poolId).allowedDockerDigests[0];
        bytes32 bundleId = keccak256("bundle-negative");
        
        EigenMatchHook.TraderSettlementInput[] memory instructions =
            new EigenMatchHook.TraderSettlementInput[](1);
        instructions[0] = EigenMatchHook.TraderSettlementInput({
            trader: trader,
            deltaSpecified: -int256(1 ether), // Negative delta
            deltaUnspecified: -int256(500), // Negative delta
            feeSaved: 50,
            expiry: uint64(block.timestamp + 60)
        });

        EigenMatchHook.SettlementBundle memory bundle = EigenMatchHook.SettlementBundle({
            epoch: uint64(block.timestamp),
            bundleId: bundleId,
            matchGroups: new EigenMatchHook.MatchGroup[](0),
            teeMeasurement: bytes32(0),
            dockerDigest: digest,
            attestationSignature: "",
            replaySalt: keccak256("salt-15")
        });

        hook.processSettlementBundle(poolId, bundle, instructions);
        
        SwapParams memory params = SwapParams({zeroForOne: false, amountSpecified: 0, sqrtPriceLimitX96: 0});
        hook.invokeBeforeSwap(trader, poolKey, params, "");
        
        EigenMatchHook.FeeLedgerEntry memory entry = hook.getFeeLedger(trader);
        assertEq(entry.matchedVolume, 1 ether); // abs(-1 ether) = 1 ether
        assertEq(entry.feeSaved, 50);
    }

    // =============================================================
    // MULTIPLE SETTLEMENTS TESTS
    // =============================================================

    function testProcessBundleWithMultipleTraders() public {
        bytes32 digest = hook.getPoolConfig(poolId).allowedDockerDigests[0];
        bytes32 bundleId = keccak256("bundle-multi");
        
        address trader1 = address(0x1111);
        address trader2 = address(0x2222);
        
        EigenMatchHook.TraderSettlementInput[] memory instructions =
            new EigenMatchHook.TraderSettlementInput[](2);
        instructions[0] = EigenMatchHook.TraderSettlementInput({
            trader: trader1,
            deltaSpecified: int256(2 ether),
            deltaUnspecified: int256(0),
            feeSaved: 200,
            expiry: uint64(block.timestamp + 60)
        });
        instructions[1] = EigenMatchHook.TraderSettlementInput({
            trader: trader2,
            deltaSpecified: int256(3 ether),
            deltaUnspecified: int256(0),
            feeSaved: 300,
            expiry: uint64(block.timestamp + 60)
        });

        EigenMatchHook.SettlementBundle memory bundle = EigenMatchHook.SettlementBundle({
            epoch: uint64(block.timestamp),
            bundleId: bundleId,
            matchGroups: new EigenMatchHook.MatchGroup[](0),
            teeMeasurement: bytes32(0),
            dockerDigest: digest,
            attestationSignature: "",
            replaySalt: keccak256("salt-16")
        });

        hook.processSettlementBundle(poolId, bundle, instructions);
        
        SwapParams memory params = SwapParams({zeroForOne: false, amountSpecified: 0, sqrtPriceLimitX96: 0});
        hook.invokeBeforeSwap(trader1, poolKey, params, "");
        hook.invokeBeforeSwap(trader2, poolKey, params, "");
        
        EigenMatchHook.FeeLedgerEntry memory entry1 = hook.getFeeLedger(trader1);
        assertEq(entry1.matchedVolume, 2 ether);
        assertEq(entry1.feeSaved, 200);
        
        EigenMatchHook.FeeLedgerEntry memory entry2 = hook.getFeeLedger(trader2);
        assertEq(entry2.matchedVolume, 3 ether);
        assertEq(entry2.feeSaved, 300);
    }

    function testMultipleSettlementsForSameTrader() public {
        bytes32 digest = hook.getPoolConfig(poolId).allowedDockerDigests[0];
        
        // First settlement
        bytes32 bundleId1 = keccak256("bundle-1");
        EigenMatchHook.TraderSettlementInput[] memory instructions1 =
            new EigenMatchHook.TraderSettlementInput[](1);
        instructions1[0] = EigenMatchHook.TraderSettlementInput({
            trader: trader,
            deltaSpecified: int256(1 ether),
            deltaUnspecified: int256(0),
            feeSaved: 100,
            expiry: uint64(block.timestamp + 60)
        });

        EigenMatchHook.SettlementBundle memory bundle1 = EigenMatchHook.SettlementBundle({
            epoch: uint64(block.timestamp),
            bundleId: bundleId1,
            matchGroups: new EigenMatchHook.MatchGroup[](0),
            teeMeasurement: bytes32(0),
            dockerDigest: digest,
            attestationSignature: "",
            replaySalt: keccak256("salt-17")
        });

        hook.processSettlementBundle(poolId, bundle1, instructions1);
        
        // Consume first settlement
        SwapParams memory params = SwapParams({zeroForOne: false, amountSpecified: 0, sqrtPriceLimitX96: 0});
        hook.invokeBeforeSwap(trader, poolKey, params, "");
        
        // Second settlement
        bytes32 bundleId2 = keccak256("bundle-2");
        EigenMatchHook.TraderSettlementInput[] memory instructions2 =
            new EigenMatchHook.TraderSettlementInput[](1);
        instructions2[0] = EigenMatchHook.TraderSettlementInput({
            trader: trader,
            deltaSpecified: int256(2 ether),
            deltaUnspecified: int256(0),
            feeSaved: 200,
            expiry: uint64(block.timestamp + 60)
        });

        EigenMatchHook.SettlementBundle memory bundle2 = EigenMatchHook.SettlementBundle({
            epoch: uint64(block.timestamp),
            bundleId: bundleId2,
            matchGroups: new EigenMatchHook.MatchGroup[](0),
            teeMeasurement: bytes32(0),
            dockerDigest: digest,
            attestationSignature: "",
            replaySalt: keccak256("salt-18")
        });

        hook.processSettlementBundle(poolId, bundle2, instructions2);
        hook.invokeBeforeSwap(trader, poolKey, params, "");
        
        EigenMatchHook.FeeLedgerEntry memory entry = hook.getFeeLedger(trader);
        assertEq(entry.matchedVolume, 3 ether); // 1 + 2
        assertEq(entry.feeSaved, 300); // 100 + 200
    }

    // =============================================================
    // VIEW FUNCTION TESTS
    // =============================================================

    function testIsBundleProcessed() public {
        bytes32 digest = hook.getPoolConfig(poolId).allowedDockerDigests[0];
        bytes32 bundleId = keccak256("bundle-view-test");
        
        assertFalse(hook.isBundleProcessed(bundleId));
        
        EigenMatchHook.TraderSettlementInput[] memory instructions =
            new EigenMatchHook.TraderSettlementInput[](1);
        instructions[0] = EigenMatchHook.TraderSettlementInput({
            trader: trader,
            deltaSpecified: int256(1),
            deltaUnspecified: int256(0),
            feeSaved: 0,
            expiry: uint64(block.timestamp + 60)
        });

        EigenMatchHook.SettlementBundle memory bundle = EigenMatchHook.SettlementBundle({
            epoch: uint64(block.timestamp),
            bundleId: bundleId,
            matchGroups: new EigenMatchHook.MatchGroup[](0),
            teeMeasurement: bytes32(0),
            dockerDigest: digest,
            attestationSignature: "",
            replaySalt: keccak256("salt-19")
        });

        hook.processSettlementBundle(poolId, bundle, instructions);
        
        assertTrue(hook.isBundleProcessed(bundleId));
    }

    function testGetPendingSettlement() public {
        bytes32 digest = hook.getPoolConfig(poolId).allowedDockerDigests[0];
        bytes32 bundleId = keccak256("bundle-pending");
        
        EigenMatchHook.TraderSettlementInput[] memory instructions =
            new EigenMatchHook.TraderSettlementInput[](1);
        instructions[0] = EigenMatchHook.TraderSettlementInput({
            trader: trader,
            deltaSpecified: int256(5 ether),
            deltaUnspecified: int256(1000),
            feeSaved: 500,
            expiry: uint64(block.timestamp + 60)
        });

        EigenMatchHook.SettlementBundle memory bundle = EigenMatchHook.SettlementBundle({
            epoch: uint64(block.timestamp),
            bundleId: bundleId,
            matchGroups: new EigenMatchHook.MatchGroup[](0),
            teeMeasurement: bytes32(0),
            dockerDigest: digest,
            attestationSignature: "",
            replaySalt: keccak256("salt-20")
        });

        hook.processSettlementBundle(poolId, bundle, instructions);
        
        EigenMatchHook.TraderSettlement memory pending = hook.getPendingSettlement(poolId, trader);
        assertEq(pending.bundleId, bundleId);
        assertEq(pending.expiry, block.timestamp + 60);
        assertEq(pending.feeSaved, 500);
    }

    // =============================================================
    // ALLOWLIST TESTS
    // =============================================================

    function testAbsInt128WithZero() public {
        bytes32 digest = hook.getPoolConfig(poolId).allowedDockerDigests[0];
        bytes32 bundleId = keccak256("bundle-zero-abs");
        
        // Test with zero delta (should still work, abs(0) = 0)
        EigenMatchHook.TraderSettlementInput[] memory instructions =
            new EigenMatchHook.TraderSettlementInput[](1);
        instructions[0] = EigenMatchHook.TraderSettlementInput({
            trader: trader,
            deltaSpecified: int256(0), // Zero delta
            deltaUnspecified: int256(0),
            feeSaved: 0,
            expiry: uint64(block.timestamp + 60)
        });

        EigenMatchHook.SettlementBundle memory bundle = EigenMatchHook.SettlementBundle({
            epoch: uint64(block.timestamp),
            bundleId: bundleId,
            matchGroups: new EigenMatchHook.MatchGroup[](0),
            teeMeasurement: bytes32(0),
            dockerDigest: digest,
            attestationSignature: "",
            replaySalt: keccak256("salt-zero-abs")
        });

        hook.processSettlementBundle(poolId, bundle, instructions);
        
        SwapParams memory params = SwapParams({zeroForOne: false, amountSpecified: 0, sqrtPriceLimitX96: 0});
        hook.invokeBeforeSwap(trader, poolKey, params, "");
        
        EigenMatchHook.FeeLedgerEntry memory entry = hook.getFeeLedger(trader);
        assertEq(entry.matchedVolume, 0); // abs(0) = 0
    }

    function testIsAllowedDigestWithMultipleDigests() public {
        bytes32[] memory digests = new bytes32[](3);
        digests[0] = keccak256("digest-a");
        digests[1] = keccak256("digest-b");
        digests[2] = keccak256("digest-c");
        
        hook.enablePool(
            poolId,
            EigenMatchHook.PoolConfig({
                enabled: true,
                maxSettlementDelay: 120,
                allowedDockerDigests: digests
            })
        );
        
        // Test with each allowed digest
        EigenMatchHook.TraderSettlementInput[] memory instructions =
            new EigenMatchHook.TraderSettlementInput[](1);
        instructions[0] = EigenMatchHook.TraderSettlementInput({
            trader: trader,
            deltaSpecified: int256(1),
            deltaUnspecified: int256(0),
            feeSaved: 0,
            expiry: uint64(block.timestamp + 60)
        });

        for (uint256 i = 0; i < digests.length; i++) {
            EigenMatchHook.SettlementBundle memory bundle = EigenMatchHook.SettlementBundle({
                epoch: uint64(block.timestamp),
                bundleId: keccak256(abi.encodePacked("bundle", i)),
                matchGroups: new EigenMatchHook.MatchGroup[](0),
                teeMeasurement: bytes32(0),
                dockerDigest: digests[i],
                attestationSignature: "",
                replaySalt: keccak256(abi.encodePacked("salt", i))
            });
            
            // Should not revert
            hook.processSettlementBundle(poolId, bundle, instructions);
        }
    }
}

