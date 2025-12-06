// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

import {IEigenMatchHook, PoolId} from "@project/interfaces/IEigenMatchHook.sol";
import {EigenMatchDigestRegistry} from "@project/l1-contracts/EigenMatchDigestRegistry.sol";

/// @title EigenMatchSettlementExecutor
/// @notice Verifies watcher approvals + digest allowlists before forwarding bundles
///         to the on-chain hook. Mirrors the "Settlement Executor" role in README/system design.
contract EigenMatchSettlementExecutor is Ownable {
    using ECDSA for bytes32;

    error InvalidConfig();
    error DigestNotAuthorized(bytes32 digest, bytes32 measurement);
    error BundleAlreadyProcessed(bytes32 bundleId);
    error InsufficientWatcherSigners(uint256 required, uint256 provided);
    error InvalidWatcherSignature(address signer);
    error DuplicateWatcherSignature(address signer);

    event SettlementForwarded(
        PoolId indexed poolId, bytes32 indexed bundleId, address indexed caller, uint256 traderCount
    );
    event WatcherUpdated(address indexed watcher, bool allowed);
    event MinWatcherSignersUpdated(uint256 newValue);

    struct BundleSubmission {
        PoolId poolId;
        IEigenMatchHook.SettlementBundle bundle;
        IEigenMatchHook.TraderSettlementInput[] traderSettlements;
        bytes[] watcherSignatures;
    }

    IEigenMatchHook public immutable hook;
    EigenMatchDigestRegistry public immutable digestRegistry;
    uint256 public minWatcherSigners;

    mapping(address => bool) public isWatcher;
    mapping(bytes32 => bool) public executedBundles;

    bytes32 private constant WATCHER_HASH_TYPE =
        keccak256("EigenMatchBundle(bytes32 bundleId, bytes32 replaySalt, uint256 chainId, address executor)");

    constructor(
        IEigenMatchHook _hook,
        EigenMatchDigestRegistry _registry,
        address initialOwner,
        address[] memory initialWatchers,
        uint256 minSigners
    ) {
        if (address(_hook) == address(0) || address(_registry) == address(0) || initialOwner == address(0)) {
            revert InvalidConfig();
        }

        hook = _hook;
        digestRegistry = _registry;
        minWatcherSigners = minSigners == 0 ? 1 : minSigners;

        for (uint256 i = 0; i < initialWatchers.length; i++) {
            if (initialWatchers[i] == address(0)) continue;
            isWatcher[initialWatchers[i]] = true;
            emit WatcherUpdated(initialWatchers[i], true);
        }

        _transferOwnership(initialOwner);
    }

    function setWatcher(
        address watcher,
        bool allowed
    ) external onlyOwner {
        if (watcher == address(0)) revert InvalidConfig();
        isWatcher[watcher] = allowed;
        emit WatcherUpdated(watcher, allowed);
    }

    function setMinWatcherSigners(
        uint256 newValue
    ) external onlyOwner {
        if (newValue == 0) revert InvalidConfig();
        minWatcherSigners = newValue;
        emit MinWatcherSignersUpdated(newValue);
    }

    function watcherMessageHash(
        bytes32 bundleId,
        bytes32 replaySalt
    ) public view returns (bytes32) {
        bytes32 structHash =
            keccak256(abi.encode(WATCHER_HASH_TYPE, bundleId, replaySalt, block.chainid, address(this)));
        return keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", structHash));
    }

    function submitSettlement(
        BundleSubmission calldata submission
    ) external {
        if (!digestRegistry.isDigestAuthorized(submission.bundle.dockerDigest, submission.bundle.teeMeasurement)) {
            revert DigestNotAuthorized(submission.bundle.dockerDigest, submission.bundle.teeMeasurement);
        }
        if (executedBundles[submission.bundle.bundleId]) {
            revert BundleAlreadyProcessed(submission.bundle.bundleId);
        }

        _verifyWatcherSignatures(submission.bundle.bundleId, submission.bundle.replaySalt, submission.watcherSignatures);

        executedBundles[submission.bundle.bundleId] = true;
        hook.processSettlementBundle(submission.poolId, submission.bundle, submission.traderSettlements);

        emit SettlementForwarded(
            submission.poolId, submission.bundle.bundleId, msg.sender, submission.traderSettlements.length
        );
    }

    function _verifyWatcherSignatures(
        bytes32 bundleId,
        bytes32 replaySalt,
        bytes[] calldata signatures
    ) internal view {
        uint256 signaturesLength = signatures.length;
        if (signaturesLength < minWatcherSigners) {
            revert InsufficientWatcherSigners(minWatcherSigners, signaturesLength);
        }

        bytes32 digest = watcherMessageHash(bundleId, replaySalt);
        address[] memory seen = new address[](signaturesLength);

        for (uint256 i = 0; i < signaturesLength; i++) {
            address signer = digest.recover(signatures[i]);
            if (!isWatcher[signer]) revert InvalidWatcherSignature(signer);

            for (uint256 j = 0; j < i; j++) {
                if (seen[j] == signer) revert DuplicateWatcherSignature(signer);
            }
            seen[i] = signer;
        }
    }
}
