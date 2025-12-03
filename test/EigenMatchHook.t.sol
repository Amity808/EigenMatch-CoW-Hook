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
}

