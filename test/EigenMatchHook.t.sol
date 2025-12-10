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
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

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
    address private otherTrader;
    bytes32 private allowedDigest;
    SwapParams private swapParams;

    function setUp() public {
        address hookAddress = address(uint160(Hooks.BEFORE_SWAP_FLAG));
        deployCodeTo(
            "test/EigenMatchHook.t.sol:EigenMatchHookHarness",
            abi.encode(address(this), address(this)),
            hookAddress
        );
        hook = EigenMatchHookHarness(hookAddress);
        vm.warp(1_000_000);

        trader = address(0xBEEF);
        otherTrader = address(0xCAFE);
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
        allowedDigest = digests[0];
        hook.enablePool(
            poolId,
            EigenMatchHook.PoolConfig({
                enabled: true,
                maxSettlementDelay: 120,
                allowedDockerDigests: digests
            })
        );

        swapParams = SwapParams({zeroForOne: false, amountSpecified: 0, sqrtPriceLimitX96: 0});
    }

    function testHookPermissionsOnlyBeforeSwap() public view {
        Hooks.Permissions memory perms = hook.getHookPermissions();
        assertTrue(perms.beforeSwap);
        assertFalse(perms.beforeInitialize);
        assertFalse(perms.afterInitialize);
        assertFalse(perms.beforeAddLiquidity);
        assertFalse(perms.afterAddLiquidity);
        assertFalse(perms.beforeRemoveLiquidity);
        assertFalse(perms.afterRemoveLiquidity);
        assertFalse(perms.afterSwap);
        assertFalse(perms.beforeDonate);
        assertFalse(perms.afterDonate);
        assertFalse(perms.beforeSwapReturnDelta);
        assertFalse(perms.afterSwapReturnDelta);
        assertFalse(perms.afterAddLiquidityReturnDelta);
        assertFalse(perms.afterRemoveLiquidityReturnDelta);
    }

    function testConstructorRevertsZeroOwner() public {
        vm.expectRevert();
        new EigenMatchHookHarness(address(this), address(0));
    }

    function testConstructorRevertsZeroExecutor() public {
        vm.expectRevert();
        new EigenMatchHookHarness(address(0), address(this));
    }

    function testBeforeSwapConsumesSettlement() public {
        bytes32 bundleId = keccak256("bundle-1");

        hook.processSettlementBundle(
            poolId,
            _bundle(bundleId, allowedDigest, keccak256("salt-1"), uint64(block.timestamp)),
            _instr(trader, int256(1 ether), 0, 100, uint64(block.timestamp + 60))
        );
        vm.expectEmit(true, true, true, true);
        emit EigenMatchHook.SettlementConsumed(poolId, trader, bundleId, 1 ether, 100);
        hook.invokeBeforeSwap(trader, poolKey, swapParams, "");

        EigenMatchHook.FeeLedgerEntry memory entry = hook.getFeeLedger(trader);
        assertEq(entry.matchedVolume, 1 ether);
        assertEq(entry.feeSaved, 100);

        EigenMatchHook.TraderSettlement memory pending =
            hook.getPendingSettlement(poolId, trader);
        assertEq(pending.bundleId, bytes32(0));
    }

    function testProcessBundleRejectsInvalidDigest() public {
        vm.expectRevert(EigenMatchHook.InvalidAttestation.selector);
        hook.processSettlementBundle(
            poolId,
            _bundle(keccak256("bundle-bad"), keccak256("bad-digest"), keccak256("salt-2"), uint64(block.timestamp)),
            _instr(trader, int256(1), 0, 0, uint64(block.timestamp + 60))
        );
    }

    function testBeforeSwapRevertsWhenExpired() public {
        bytes32 bundleId = keccak256("bundle-expire");
        hook.processSettlementBundle(
            poolId,
            _bundle(bundleId, allowedDigest, keccak256("salt-3"), uint64(block.timestamp)),
            _instr(trader, int256(1), 0, 0, uint64(block.timestamp + 1))
        );

        vm.warp(block.timestamp + 2);
        vm.expectRevert(EigenMatchHook.SettlementExpired.selector);
        hook.invokeBeforeSwap(trader, poolKey, swapParams, "");
    }

    function testProcessBundleRequiresExecutor() public {
        vm.startPrank(address(0x1234));
        vm.expectRevert(EigenMatchHook.NotSettlementExecutor.selector);
        hook.processSettlementBundle(
            poolId,
            _bundle(keccak256("bundle-auth"), allowedDigest, keccak256("salt-auth"), uint64(block.timestamp)),
            _instr(trader, int256(1), 0, 0, uint64(block.timestamp + 10))
        );
        vm.stopPrank();
    }

    function testProcessBundleRevertsOnReplay() public {
        bytes32 bundleId = keccak256("bundle-replay");
        EigenMatchHook.SettlementBundle memory bundle =
            _bundle(bundleId, allowedDigest, keccak256("salt-replay"), uint64(block.timestamp));
        EigenMatchHook.TraderSettlementInput[] memory instructions =
            _instr(trader, int256(1), 0, 0, uint64(block.timestamp + 100));

        hook.processSettlementBundle(poolId, bundle, instructions);

        vm.expectRevert(EigenMatchHook.BundleAlreadyProcessed.selector);
        hook.processSettlementBundle(poolId, bundle, instructions);
    }

    function testProcessBundleRejectsExpiredEpoch() public {
        EigenMatchHook.SettlementBundle memory bundle = _bundle(
            keccak256("bundle-old"), allowedDigest, keccak256("salt-old"), uint64(block.timestamp - 500)
        );
        EigenMatchHook.TraderSettlementInput[] memory instructions =
            _instr(trader, int256(1), 0, 0, uint64(block.timestamp + 10));

        vm.expectRevert(EigenMatchHook.SettlementExpired.selector);
        hook.processSettlementBundle(poolId, bundle, instructions);
    }

    function testProcessBundleRequiresInstructions() public {
        EigenMatchHook.SettlementBundle memory bundle =
            _bundle(keccak256("bundle-empty"), allowedDigest, keccak256("salt-empty"), uint64(block.timestamp));
        EigenMatchHook.TraderSettlementInput[] memory instructions = new EigenMatchHook.TraderSettlementInput[](0);

        vm.expectRevert(EigenMatchHook.InvalidBundle.selector);
        hook.processSettlementBundle(poolId, bundle, instructions);
    }

    function testProcessBundleRejectsZeroTrader() public {
        EigenMatchHook.TraderSettlementInput[] memory instructions =
            _instr(address(0), int256(1), 0, 0, uint64(block.timestamp + 10));
        vm.expectRevert(EigenMatchHook.InvalidBundle.selector);
        hook.processSettlementBundle(
            poolId,
            _bundle(keccak256("bundle-zero-trader"), allowedDigest, keccak256("salt-zero"), uint64(block.timestamp)),
            instructions
        );
    }

    function testProcessBundleRejectsExpiredInstruction() public {
        EigenMatchHook.TraderSettlementInput[] memory instructions =
            _instr(trader, int256(1), 0, 0, uint64(block.timestamp));
        vm.expectRevert(EigenMatchHook.SettlementExpired.selector);
        hook.processSettlementBundle(
            poolId,
            _bundle(keccak256("bundle-expired-inst"), allowedDigest, keccak256("salt-exp"), uint64(block.timestamp)),
            instructions
        );
    }

    function testProcessBundleHandlesMultipleInstructions() public {
        EigenMatchHook.TraderSettlementInput[] memory instructions =
            new EigenMatchHook.TraderSettlementInput[](2);
        instructions[0] = EigenMatchHook.TraderSettlementInput({
            trader: trader,
            deltaSpecified: int256(1),
            deltaUnspecified: int256(0),
            feeSaved: 10,
            expiry: uint64(block.timestamp + 100)
        });
        instructions[1] = EigenMatchHook.TraderSettlementInput({
            trader: otherTrader,
            deltaSpecified: int256(-2),
            deltaUnspecified: int256(0),
            feeSaved: 20,
            expiry: uint64(block.timestamp + 100)
        });

        bytes32 bundleId = keccak256("bundle-multi-inst");
        uint64 epoch = uint64(block.timestamp);
        vm.expectEmit(true, true, true, true);
        emit EigenMatchHook.BundleProcessed(poolId, bundleId, epoch, 3, 30);
        hook.processSettlementBundle(
            poolId,
            _bundle(bundleId, allowedDigest, keccak256("salt-multi-inst"), epoch),
            instructions
        );

        EigenMatchHook.TraderSettlement memory pendingA = hook.getPendingSettlement(poolId, trader);
        EigenMatchHook.TraderSettlement memory pendingB = hook.getPendingSettlement(poolId, otherTrader);

        assertEq(pendingA.bundleId, keccak256("bundle-multi-inst"));
        assertEq(pendingB.bundleId, keccak256("bundle-multi-inst"));
        assertEq(BeforeSwapDeltaLibrary.getSpecifiedDelta(pendingA.delta), int128(1));
        assertEq(BeforeSwapDeltaLibrary.getSpecifiedDelta(pendingB.delta), int128(-2));
    }

    function testEnablePoolRejectsZeroDelay() public {
        EigenMatchHook.PoolConfig memory invalidConfig = EigenMatchHook.PoolConfig({
            enabled: true,
            maxSettlementDelay: 0,
            allowedDockerDigests: new bytes32[](0)
        });

        vm.expectRevert(EigenMatchHook.InvalidConfig.selector);
        hook.enablePool(poolId, invalidConfig);
    }

    function testEnablePoolCopiesAllowedDigests() public {
        bytes32[] memory digests = new bytes32[](2);
        digests[0] = keccak256("d1");
        digests[1] = keccak256("d2");
        hook.enablePool(
            poolId,
            EigenMatchHook.PoolConfig({enabled: true, maxSettlementDelay: 300, allowedDockerDigests: digests})
        );

        EigenMatchHook.PoolConfig memory cfg = hook.getPoolConfig(poolId);
        cfg.allowedDockerDigests[0] = bytes32(0);

        EigenMatchHook.PoolConfig memory reloaded = hook.getPoolConfig(poolId);
        assertEq(reloaded.allowedDockerDigests[0], keccak256("d1"));
        assertEq(reloaded.allowedDockerDigests[1], keccak256("d2"));

        hook.processSettlementBundle(
            poolId,
            _bundle(keccak256("bundle-second-digest"), keccak256("d2"), keccak256("salt-second-digest"), uint64(block.timestamp)),
            _instr(trader, int256(1), 0, 0, uint64(block.timestamp + 60))
        );
    }

    function testSetSettlementExecutorOnlyOwner() public {
        vm.prank(trader);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, trader));
        hook.setSettlementExecutor(trader);
    }

    function testSetSettlementExecutorRejectsZero() public {
        vm.expectRevert(EigenMatchHook.InvalidConfig.selector);
        hook.setSettlementExecutor(address(0));
    }

    function testSetSettlementExecutorUpdatesAddress() public {
        hook.setSettlementExecutor(otherTrader);

        vm.prank(address(this));
        vm.expectRevert(EigenMatchHook.NotSettlementExecutor.selector);
        hook.processSettlementBundle(
            poolId,
            _bundle(keccak256("bundle-old-exec"), allowedDigest, keccak256("salt-old-exec"), uint64(block.timestamp)),
            _instr(trader, int256(1), 0, 0, uint64(block.timestamp + 10))
        );

        vm.prank(otherTrader);
        hook.processSettlementBundle(
            poolId,
            _bundle(keccak256("bundle-new-exec"), allowedDigest, keccak256("salt-new-exec"), uint64(block.timestamp)),
            _instr(trader, int256(1), 0, 0, uint64(block.timestamp + 10))
        );
    }

    function testPoolPauseBlocksBeforeSwap() public {
        hook.setPoolPaused(poolId, true);
        vm.expectRevert(EigenMatchHook.PoolIsPaused.selector);
        hook.invokeBeforeSwap(trader, poolKey, swapParams, "");
    }

    function testSetPoolPausedEmitsEvent() public {
        vm.expectEmit(true, true, false, true);
        emit EigenMatchHook.PoolPaused(poolId, true);
        hook.setPoolPaused(poolId, true);
    }

    function testSetPoolPausedOnlyOwner() public {
        vm.prank(trader);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, trader));
        hook.setPoolPaused(poolId, true);
    }

    function testBeforeSwapReturnsZeroDeltaWhenNoSettlement() public {
        BeforeSwapDelta delta = hook.invokeBeforeSwap(trader, poolKey, swapParams, "");
        assertEq(BeforeSwapDeltaLibrary.getSpecifiedDelta(delta), int128(0));
        assertEq(BeforeSwapDeltaLibrary.getUnspecifiedDelta(delta), int128(0));
    }

    function testBeforeSwapReturnsZeroWhenPoolDisabled() public {
        bytes32[] memory digests = new bytes32[](1);
        digests[0] = allowedDigest;

        hook.processSettlementBundle(
            poolId,
            _bundle(keccak256("bundle-disabled"), allowedDigest, keccak256("salt-disabled"), uint64(block.timestamp)),
            _instr(trader, int256(1), 0, 0, uint64(block.timestamp + 60))
        );

        hook.enablePool(
            poolId,
            EigenMatchHook.PoolConfig({enabled: false, maxSettlementDelay: 120, allowedDockerDigests: digests})
        );

        BeforeSwapDelta delta = hook.invokeBeforeSwap(trader, poolKey, swapParams, "");
        assertEq(BeforeSwapDeltaLibrary.getSpecifiedDelta(delta), int128(0));
    }

    function testQueueSettlementOverwritesExistingEntry() public {
        bytes32 firstBundle = keccak256("bundle-first");
        bytes32 secondBundle = keccak256("bundle-second");

        hook.processSettlementBundle(
            poolId,
            _bundle(firstBundle, allowedDigest, keccak256("salt-first"), uint64(block.timestamp)),
            _instr(trader, int256(1), 0, 0, uint64(block.timestamp + 60))
        );

        hook.processSettlementBundle(
            poolId,
            _bundle(secondBundle, allowedDigest, keccak256("salt-second"), uint64(block.timestamp + 1)),
            _instr(trader, int256(2), 0, 0, uint64(block.timestamp + 120))
        );

        EigenMatchHook.TraderSettlement memory pending = hook.getPendingSettlement(poolId, trader);
        assertEq(pending.bundleId, secondBundle);
        assertEq(BeforeSwapDeltaLibrary.getSpecifiedDelta(pending.delta), int128(2));
    }

    function testProcessedBundlesTracking() public {
        bytes32 bundleId = keccak256("bundle-track");
        hook.processSettlementBundle(
            poolId,
            _bundle(bundleId, allowedDigest, keccak256("salt-track"), uint64(block.timestamp)),
            _instr(trader, int256(1), 0, 0, uint64(block.timestamp + 100))
        );

        assertTrue(hook.isBundleProcessed(bundleId));
        bytes32 replayKey = keccak256(abi.encodePacked(poolId, keccak256("salt-track")));
        // replay key stored in the same mapping
        assertTrue(hook.processedBundles(replayKey));
    }

    function testFeeLedgerAccumulatesAcrossBundles() public {
        hook.processSettlementBundle(
            poolId,
            _bundle(keccak256("bundle-ledger-1"), allowedDigest, keccak256("salt-ledger-1"), uint64(block.timestamp)),
            _instr(trader, int256(1 ether), 0, 50, uint64(block.timestamp + 60))
        );
        hook.invokeBeforeSwap(trader, poolKey, swapParams, "");

        hook.processSettlementBundle(
            poolId,
            _bundle(keccak256("bundle-ledger-2"), allowedDigest, keccak256("salt-ledger-2"), uint64(block.timestamp + 1)),
            _instr(trader, int256(2 ether), 0, 75, uint64(block.timestamp + 120))
        );
        hook.invokeBeforeSwap(trader, poolKey, swapParams, "");

        EigenMatchHook.FeeLedgerEntry memory entry = hook.getFeeLedger(trader);
        assertEq(entry.matchedVolume, 3 ether);
        assertEq(entry.feeSaved, 125);
        assertEq(entry.lastUpdated, uint64(block.timestamp));
    }

    function testPendingSettlementPerTrader() public {
        hook.processSettlementBundle(
            poolId,
            _bundle(keccak256("bundle-multi"), allowedDigest, keccak256("salt-multi"), uint64(block.timestamp)),
            _instr(trader, int256(1), 0, 10, uint64(block.timestamp + 60))
        );

        hook.processSettlementBundle(
            poolId,
            _bundle(keccak256("bundle-multi-2"), allowedDigest, keccak256("salt-multi-2"), uint64(block.timestamp + 1)),
            _instr(otherTrader, int256(3), 0, 20, uint64(block.timestamp + 60))
        );

        EigenMatchHook.TraderSettlement memory pendingTrader = hook.getPendingSettlement(poolId, trader);
        EigenMatchHook.TraderSettlement memory pendingOther = hook.getPendingSettlement(poolId, otherTrader);

        assertEq(pendingTrader.bundleId, keccak256("bundle-multi"));
        assertEq(pendingOther.bundleId, keccak256("bundle-multi-2"));
    }

    function testProcessBundleMarksReplaySaltPerPool() public {
        PoolKey memory secondKey = PoolKey({
            currency0: Currency.wrap(address(0xAAA1)),
            currency1: Currency.wrap(address(0xBBB1)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        PoolId secondPool = secondKey.toId();
        bytes32[] memory digests = new bytes32[](1);
        digests[0] = allowedDigest;
        hook.enablePool(
            secondPool,
            EigenMatchHook.PoolConfig({enabled: true, maxSettlementDelay: 120, allowedDockerDigests: digests})
        );

        bytes32 replaySalt = keccak256("shared-salt");
        hook.processSettlementBundle(
            poolId,
            _bundle(keccak256("bundle-replay-a"), allowedDigest, replaySalt, uint64(block.timestamp)),
            _instr(trader, int256(1), 0, 0, uint64(block.timestamp + 10))
        );

        vm.expectRevert(EigenMatchHook.BundleAlreadyProcessed.selector);
        hook.processSettlementBundle(
            poolId,
            _bundle(keccak256("bundle-replay-b"), allowedDigest, replaySalt, uint64(block.timestamp)),
            _instr(trader, int256(1), 0, 0, uint64(block.timestamp + 10))
        );

        hook.processSettlementBundle(
            secondPool,
            _bundle(keccak256("bundle-replay-second"), allowedDigest, replaySalt, uint64(block.timestamp)),
            _instr(otherTrader, int256(1), 0, 0, uint64(block.timestamp + 10))
        );
    }

    function testProcessBundleRejectsInt128Overflow() public {
        int256 overflowValue = int256(type(int128).max) + 1;
        vm.expectRevert(EigenMatchHook.InvalidBundle.selector);
        hook.processSettlementBundle(
            poolId,
            _bundle(keccak256("bundle-overflow"), allowedDigest, keccak256("salt-overflow"), uint64(block.timestamp)),
            _instr(trader, overflowValue, 0, 0, uint64(block.timestamp + 10))
        );
    }

    function testSettlementMatchedVolumeUsesAbsValue() public {
        bytes32 bundleId = keccak256("bundle-negative");
        hook.processSettlementBundle(
            poolId,
            _bundle(bundleId, allowedDigest, keccak256("salt-negative"), uint64(block.timestamp)),
            _instr(trader, int256(-5 ether), 0, 0, uint64(block.timestamp + 60))
        );

        vm.expectEmit(true, true, true, true);
        emit EigenMatchHook.SettlementConsumed(poolId, trader, bundleId, 5 ether, 0);
        hook.invokeBeforeSwap(trader, poolKey, swapParams, "");

        EigenMatchHook.FeeLedgerEntry memory entry = hook.getFeeLedger(trader);
        assertEq(entry.matchedVolume, 5 ether);
    }

    function testProcessBundleRejectsPoolNotEnabled() public {
        bytes32[] memory digests = new bytes32[](1);
        digests[0] = allowedDigest;
        hook.enablePool(
            poolId,
            EigenMatchHook.PoolConfig({enabled: false, maxSettlementDelay: 120, allowedDockerDigests: digests})
        );
        vm.expectRevert(EigenMatchHook.PoolNotEnabled.selector);
        hook.processSettlementBundle(
            poolId,
            _bundle(keccak256("bundle-disabled-pool"), allowedDigest, keccak256("salt-disabled-pool"), uint64(block.timestamp)),
            _instr(trader, int256(1), 0, 0, uint64(block.timestamp + 10))
        );
    }

    function testPendingSettlementEmptyBeforeQueue() public view {
        EigenMatchHook.TraderSettlement memory pending = hook.getPendingSettlement(poolId, trader);
        assertEq(pending.bundleId, bytes32(0));
        assertEq(BeforeSwapDeltaLibrary.getSpecifiedDelta(pending.delta), int128(0));
    }

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------

    function _bundle(bytes32 bundleId, bytes32 digest, bytes32 replaySalt, uint64 epoch)
        internal
        pure
        returns (EigenMatchHook.SettlementBundle memory)
    {
        return EigenMatchHook.SettlementBundle({
            epoch: epoch,
            bundleId: bundleId,
            matchGroups: new EigenMatchHook.MatchGroup[](0),
            teeMeasurement: bytes32(0),
            dockerDigest: digest,
            attestationSignature: "",
            replaySalt: replaySalt
        });
    }

    function _instr(
        address target,
        int256 deltaSpecified,
        int256 deltaUnspecified,
        uint256 feeSaved,
        uint64 expiry
    ) internal pure returns (EigenMatchHook.TraderSettlementInput[] memory instructions) {
        instructions = new EigenMatchHook.TraderSettlementInput[](1);
        instructions[0] = EigenMatchHook.TraderSettlementInput({
            trader: target,
            deltaSpecified: deltaSpecified,
            deltaUnspecified: deltaUnspecified,
            feeSaved: feeSaved,
            expiry: expiry
        });
    }
}

