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

    function testBeforeSwapConsumesSettlement() public {
        bytes32 bundleId = keccak256("bundle-1");

        hook.processSettlementBundle(
            poolId,
            _bundle(bundleId, allowedDigest, keccak256("salt-1"), uint64(block.timestamp)),
            _instr(trader, int256(1 ether), 0, 100, uint64(block.timestamp + 60))
        );
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

    function testEnablePoolRejectsZeroDelay() public {
        EigenMatchHook.PoolConfig memory invalidConfig = EigenMatchHook.PoolConfig({
            enabled: true,
            maxSettlementDelay: 0,
            allowedDockerDigests: new bytes32[](0)
        });

        vm.expectRevert(EigenMatchHook.InvalidConfig.selector);
        hook.enablePool(poolId, invalidConfig);
    }

    function testSetSettlementExecutorOnlyOwner() public {
        vm.prank(trader);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, trader));
        hook.setSettlementExecutor(trader);
    }

    function testPoolPauseBlocksBeforeSwap() public {
        hook.setPoolPaused(poolId, true);
        vm.expectRevert(EigenMatchHook.PoolIsPaused.selector);
        hook.invokeBeforeSwap(trader, poolKey, swapParams, "");
    }

    function testBeforeSwapReturnsZeroDeltaWhenNoSettlement() public {
        BeforeSwapDelta delta = hook.invokeBeforeSwap(trader, poolKey, swapParams, "");
        assertEq(BeforeSwapDeltaLibrary.getSpecifiedDelta(delta), int128(0));
        assertEq(BeforeSwapDeltaLibrary.getUnspecifiedDelta(delta), int128(0));
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

