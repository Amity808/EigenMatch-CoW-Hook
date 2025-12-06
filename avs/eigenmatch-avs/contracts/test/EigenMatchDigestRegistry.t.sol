// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";

import {EigenMatchDigestRegistry} from "@project/l1-contracts/EigenMatchDigestRegistry.sol";

contract EigenMatchDigestRegistryTest is Test {
    EigenMatchDigestRegistry private registry;
    bytes32 private constant MEASUREMENT = keccak256("measurement");
    bytes32 private constant DIGEST = keccak256("docker");

    function setUp() public {
        registry = new EigenMatchDigestRegistry(address(this));
    }

    function testPublishAndAuthorizeDigest() public {
        registry.setMeasurementAllowed(MEASUREMENT, true);
        registry.publishDigest(DIGEST, MEASUREMENT, "ipfs://digest");

        assertTrue(registry.isDigestAuthorized(DIGEST, MEASUREMENT));

        registry.setDigestRevoked(DIGEST, true);
        assertFalse(registry.isDigestAuthorized(DIGEST, MEASUREMENT));
    }

    function testMeasurementToggleAffectsExistingDigests() public {
        registry.setMeasurementAllowed(MEASUREMENT, true);
        registry.publishDigest(DIGEST, MEASUREMENT, "uri");
        assertTrue(registry.isDigestAuthorized(DIGEST, MEASUREMENT));

        registry.setMeasurementAllowed(MEASUREMENT, false);
        assertFalse(registry.isDigestAuthorized(DIGEST, MEASUREMENT));
    }
}
