// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title EigenMatchDigestRegistry
/// @notice Publishes and manages the EigenCompute docker digests and TEE measurements
///         that the hook/executor will trust. Acts as the "match proof store" described
///         in the root README and `docs/system-design.md`.
contract EigenMatchDigestRegistry is Ownable {
    struct DigestMetadata {
        bytes32 teeMeasurement;
        string metadataURI;
        uint64 publishedAt;
        bool revoked;
    }

    mapping(bytes32 => DigestMetadata) private _digests;
    mapping(bytes32 => bool) private _measurementAllowlist;

    event DigestPublished(bytes32 indexed dockerDigest, bytes32 indexed teeMeasurement, string metadataURI);
    event DigestRevocationUpdated(bytes32 indexed dockerDigest, bool revoked);
    event MeasurementAllowlistUpdated(bytes32 indexed teeMeasurement, bool allowed);

    error InvalidAddress();
    error InvalidDigest();
    error DigestNotFound(bytes32 digest);

    constructor(address initialOwner) {
        if (initialOwner == address(0)) revert InvalidAddress();
        _transferOwnership(initialOwner);
    }

    function publishDigest(bytes32 dockerDigest, bytes32 teeMeasurement, string calldata metadataURI) external onlyOwner {
        if (dockerDigest == bytes32(0)) revert InvalidDigest();

        _digests[dockerDigest] = DigestMetadata({
            teeMeasurement: teeMeasurement,
            metadataURI: metadataURI,
            publishedAt: uint64(block.timestamp),
            revoked: false
        });

        emit DigestPublished(dockerDigest, teeMeasurement, metadataURI);
    }

    function setDigestRevoked(bytes32 dockerDigest, bool revoked) external onlyOwner {
        if (_digests[dockerDigest].publishedAt == 0) revert DigestNotFound(dockerDigest);
        _digests[dockerDigest].revoked = revoked;
        emit DigestRevocationUpdated(dockerDigest, revoked);
    }

    function setMeasurementAllowed(bytes32 teeMeasurement, bool allowed) external onlyOwner {
        _measurementAllowlist[teeMeasurement] = allowed;
        emit MeasurementAllowlistUpdated(teeMeasurement, allowed);
    }

    function isDigestAuthorized(bytes32 dockerDigest, bytes32 teeMeasurement) public view returns (bool) {
        DigestMetadata memory metadata = _digests[dockerDigest];
        if (metadata.publishedAt == 0 || metadata.revoked) {
            return false;
        }

        bytes32 measurementToCheck = metadata.teeMeasurement == bytes32(0) ? teeMeasurement : metadata.teeMeasurement;
        if (measurementToCheck == bytes32(0)) {
            return false;
        }

        return _measurementAllowlist[measurementToCheck];
    }

    function measurementAllowed(bytes32 teeMeasurement) external view returns (bool) {
        return _measurementAllowlist[teeMeasurement];
    }

    function getDigest(bytes32 dockerDigest) external view returns (DigestMetadata memory) {
        if (_digests[dockerDigest].publishedAt == 0) revert DigestNotFound(dockerDigest);
        return _digests[dockerDigest];
    }
}
