// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";

import {IEigenMatchHook, PoolId} from "@project/interfaces/IEigenMatchHook.sol";
import {EigenMatchDigestRegistry} from "@project/l1-contracts/EigenMatchDigestRegistry.sol";
import {EigenMatchSettlementExecutor} from "@project/l2-contracts/EigenMatchSettlementExecutor.sol";
import {EigenMatchHookMock} from "test/mocks/EigenMatchHookMock.sol";

contract EigenMatchSettlementExecutorTest is Test {
    EigenMatchDigestRegistry private registry;
    EigenMatchSettlementExecutor private executor;
    EigenMatchHookMock private hook;

    address private watcher;
    uint256 private watcherKey;
    address private watcherTwo;
    uint256 private watcherTwoKey;

    bytes32 private constant MEASUREMENT = keccak256("measurement");
    bytes32 private constant DIGEST = keccak256("digest");

    function setUp() public {
        registry = new EigenMatchDigestRegistry(address(this));
        registry.setMeasurementAllowed(MEASUREMENT, true);
        registry.publishDigest(DIGEST, MEASUREMENT, "ipfs://digest");

        hook = new EigenMatchHookMock();
        (watcher, watcherKey) = makeAddrAndKey("watcher");
        (watcherTwo, watcherTwoKey) = makeAddrAndKey("watcher-two");

        address[] memory watchers = new address[](2);
        watchers[0] = watcher;
        watchers[1] = watcherTwo;

        executor = new EigenMatchSettlementExecutor(hook, registry, address(this), watchers, 1);
    }

    function testSubmitSettlementForwardsToHook() public {
        EigenMatchSettlementExecutor.BundleSubmission memory submission = _buildSubmission();
        submission.watcherSignatures = _signDefault(submission.bundle.bundleId, submission.bundle.replaySalt);

        executor.submitSettlement(submission);

        assertEq(hook.lastBundleId(), submission.bundle.bundleId);
        assertEq(hook.lastTraderCount(), submission.traderSettlements.length);
    }

    function testSubmitSettlementRevertsWhenDigestRevoked() public {
        EigenMatchSettlementExecutor.BundleSubmission memory submission = _buildSubmission();
        registry.setDigestRevoked(DIGEST, true);
        submission.watcherSignatures = _signDefault(submission.bundle.bundleId, submission.bundle.replaySalt);

        vm.expectRevert(
            abi.encodeWithSelector(
                EigenMatchSettlementExecutor.DigestNotAuthorized.selector, DIGEST, MEASUREMENT
            )
        );
        executor.submitSettlement(submission);
    }

    function testSubmitSettlementRejectsInsufficientSigners() public {
        EigenMatchSettlementExecutor.BundleSubmission memory submission = _buildSubmission();
        submission.watcherSignatures = new bytes[](0);

        vm.expectRevert(
            abi.encodeWithSelector(EigenMatchSettlementExecutor.InsufficientWatcherSigners.selector, 1, 0)
        );
        executor.submitSettlement(submission);
    }

    function testSubmitSettlementRejectsDuplicateWatcherSignatures() public {
        EigenMatchSettlementExecutor local = new EigenMatchSettlementExecutor(
            hook, registry, address(this), _twoWatchers(), 2
        );
        EigenMatchSettlementExecutor.BundleSubmission memory submission = _buildSubmission();

        bytes32 digest = local.watcherMessageHash(submission.bundle.bundleId, submission.bundle.replaySalt);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(watcherKey, digest);

        submission.watcherSignatures = new bytes[](2);
        submission.watcherSignatures[0] = abi.encodePacked(r, s, v);
        submission.watcherSignatures[1] = abi.encodePacked(r, s, v);

        vm.expectRevert(
            abi.encodeWithSelector(EigenMatchSettlementExecutor.DuplicateWatcherSignature.selector, watcher)
        );
        local.submitSettlement(submission);
    }

    function testSubmitSettlementRejectsUnknownWatcherSignature() public {
        EigenMatchSettlementExecutor.BundleSubmission memory submission = _buildSubmission();
        bytes32 digest = executor.watcherMessageHash(submission.bundle.bundleId, submission.bundle.replaySalt);
        (address stranger, uint256 strangerKey) = makeAddrAndKey("stranger");
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(strangerKey, digest);
        submission.watcherSignatures = new bytes[](1);
        submission.watcherSignatures[0] = abi.encodePacked(r, s, v);

        vm.expectRevert(
            abi.encodeWithSelector(EigenMatchSettlementExecutor.InvalidWatcherSignature.selector, stranger)
        );
        executor.submitSettlement(submission);
    }

    function testSubmitSettlementRejectsDuplicateBundles() public {
        EigenMatchSettlementExecutor.BundleSubmission memory submission = _buildSubmission();
        submission.watcherSignatures = _signDefault(submission.bundle.bundleId, submission.bundle.replaySalt);
        executor.submitSettlement(submission);

        vm.expectRevert(
            abi.encodeWithSelector(EigenMatchSettlementExecutor.BundleAlreadyProcessed.selector, submission.bundle.bundleId)
        );
        executor.submitSettlement(submission);
    }

    function _buildSubmission() private view returns (EigenMatchSettlementExecutor.BundleSubmission memory submission) {
        IEigenMatchHook.MatchGroup[] memory groups = new IEigenMatchHook.MatchGroup[](1);
        groups[0].intentIds = new bytes32[](2);
        groups[0].intentIds[0] = keccak256("intent-a");
        groups[0].intentIds[1] = keccak256("intent-b");
        groups[0].clearingPrice = 2000e18;
        groups[0].matchedAmount = 5e18;
        groups[0].feesSavedBps = 80;

        IEigenMatchHook.TraderSettlementInput[] memory settlements = new IEigenMatchHook.TraderSettlementInput[](1);
        settlements[0] = IEigenMatchHook.TraderSettlementInput({
            trader: address(0xBEEF),
            deltaSpecified: int256(1e18),
            deltaUnspecified: -int256(1e18),
            feeSaved: 10e15,
            expiry: uint64(block.timestamp + 1 hours)
        });

        submission.poolId = PoolId.wrap(bytes32(uint256(1234)));
        submission.bundle = IEigenMatchHook.SettlementBundle({
            epoch: uint64(block.timestamp),
            bundleId: keccak256("bundle"),
            matchGroups: groups,
            teeMeasurement: MEASUREMENT,
            dockerDigest: DIGEST,
            attestationSignature: "",
            replaySalt: keccak256("salt")
        });
        submission.traderSettlements = settlements;
    }

    function _signDefault(bytes32 bundleId, bytes32 replaySalt) private view returns (bytes[] memory sigs) {
        bytes32 digest = executor.watcherMessageHash(bundleId, replaySalt);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(watcherKey, digest);
        sigs = new bytes[](1);
        sigs[0] = abi.encodePacked(r, s, v);
    }

    function _twoWatchers() private view returns (address[] memory watchers) {
        watchers = new address[](2);
        watchers[0] = watcher;
        watchers[1] = watcherTwo;
    }
}
