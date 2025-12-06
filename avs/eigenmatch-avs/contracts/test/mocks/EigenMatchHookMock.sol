// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

import {IEigenMatchHook, PoolId} from "@project/interfaces/IEigenMatchHook.sol";

contract EigenMatchHookMock is IEigenMatchHook {
    PoolId public lastPoolId;
    bytes32 public lastBundleId;
    uint256 public lastTraderCount;

    event BundleProcessed(PoolId indexed poolId, bytes32 indexed bundleId);

    function processSettlementBundle(
        PoolId poolId,
        SettlementBundle calldata bundle,
        TraderSettlementInput[] calldata traderSettlements
    ) external override {
        lastPoolId = poolId;
        lastBundleId = bundle.bundleId;
        lastTraderCount = traderSettlements.length;
        emit BundleProcessed(poolId, bundle.bundleId);
    }
}

