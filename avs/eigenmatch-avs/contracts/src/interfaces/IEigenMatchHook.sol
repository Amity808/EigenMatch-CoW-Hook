// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

type PoolId is bytes32;

interface IEigenMatchHook {
    struct MatchGroup {
        bytes32[] intentIds;
        uint256 clearingPrice;
        uint256 matchedAmount;
        uint16 feesSavedBps;
    }

    struct SettlementBundle {
        uint64 epoch;
        bytes32 bundleId;
        MatchGroup[] matchGroups;
        bytes32 teeMeasurement;
        bytes32 dockerDigest;
        bytes attestationSignature;
        bytes32 replaySalt;
    }

    struct TraderSettlementInput {
        address trader;
        int256 deltaSpecified;
        int256 deltaUnspecified;
        uint256 feeSaved;
        uint64 expiry;
    }

    function processSettlementBundle(
        PoolId poolId,
        SettlementBundle calldata bundle,
        TraderSettlementInput[] calldata traderSettlements
    ) external;
}

