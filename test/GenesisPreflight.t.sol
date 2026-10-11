// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {GenesisSplitter, ILaunchRegistry} from "src/GenesisSplitter.sol";
import {GenesisPreflight} from "../script/GenesisPreflight.s.sol";
import {MockRegistry, Token, Bucket, NotABucket} from "./GenesisSplitter.t.sol";
import {
    BadTokenBucket,
    MissingTokenBucket,
    RevertingBucket,
    TupleBucket,
    SenderBurnToken,
    ReceiverTaxToken,
    LimitedToken
} from "./GenesisSplitter.audit.t.sol";

contract PreflightHarness {
    function check(GenesisSplitter splitter, uint64 n, address[] memory buckets) external {
        GenesisPreflight.check(splitter, n, buckets);
    }
}

contract GenesisPreflightTest is Test {
    MockRegistry internal registry;
    GenesisSplitter internal splitter;
    PreflightHarness internal harness;
    Token internal token;
    address internal treasury;

    function setUp() public {
        registry = new MockRegistry();
        treasury = makeAddr("treasury");
        splitter = new GenesisSplitter(address(registry), treasury);
        harness = new PreflightHarness();
        token = new Token("T", address(this), 1000);
        token.transfer(address(splitter), 700);
    }

    function _record(bytes32 kind, address t, address bucket) internal {
        ILaunchRegistry.Artifact[] memory a = new ILaunchRegistry.Artifact[](3);
        a[0] = ILaunchRegistry.Artifact("token", "T", t);
        a[1] = ILaunchRegistry.Artifact("other", "Bucket", bucket);
        a[2] = ILaunchRegistry.Artifact("other", "Vault", address(new NotABucket(t)));
        registry.record(1, kind, a);
    }

    function _inventory(address bucket) internal pure returns (address[] memory expected) {
        expected = new address[](1);
        expected[0] = bucket;
    }

    function _badGetter(address bucket, string memory reason) internal {
        _record("custom_token", address(token), bucket);
        vm.expectRevert(bytes(reason));
        harness.check(splitter, 1, _inventory(bucket));
        assertFalse(splitter.isSplit(address(token)));
        assertEq(token.balanceOf(address(splitter)), 700);
    }

    function test_validBucketsAndNonBucketsPass() public {
        address bucket = address(new Bucket(address(token), 250));
        _record("custom_token", address(token), bucket);
        harness.check(splitter, 1, _inventory(bucket));
        assertEq(token.balanceOf(bucket), 250);
        assertEq(token.balanceOf(treasury), 450);
    }

    function test_wrongTokenFailsBeforeMovingFunds() public {
        Token other = new Token("OTHER", address(this), 1);
        _badGetter(address(new Bucket(address(other), 250)), "wrong or malformed token");
    }

    function test_dirtyAddressFailsBeforeMovingFunds() public {
        _badGetter(address(new BadTokenBucket()), "wrong or malformed token");
    }

    function test_missingTokenFailsBeforeMovingFunds() public {
        _badGetter(address(new MissingTokenBucket()), "invalid token getter");
    }

    function test_revertingExpectedBucketFailsInsteadOfBeingSkipped() public {
        _badGetter(address(new RevertingBucket()), "invalid genesisAllocation getter");
    }

    function test_tupleExpectedBucketFailsInsteadOfBeingSkipped() public {
        _badGetter(address(new TupleBucket()), "invalid genesisAllocation getter");
    }

    function test_nonCustomRemainderIsRefused() public {
        address bucket = address(new Bucket(address(token), 250));
        _record("evm_project", address(token), bucket);
        vm.expectRevert("custom_token only");
        harness.check(splitter, 1, _inventory(bucket));
    }

    function test_unregisteredTokenIsRefused() public {
        vm.expectRevert("custom_token only");
        harness.check(splitter, 1, new address[](0));
    }

    function test_receiverTaxIsDetectedAndSimulationRollsBack() public {
        ReceiverTaxToken taxed = new ReceiverTaxToken(address(this));
        taxed.transfer(address(splitter), 700);
        address bucket = address(new Bucket(address(taxed), 250));
        _record("custom_token", address(taxed), bucket);
        vm.expectRevert("bucket under/overpaid");
        harness.check(splitter, 1, _inventory(bucket));
        assertEq(taxed.balanceOf(address(splitter)), 700);
        assertFalse(splitter.isSplit(address(taxed)));
    }

    function test_senderBurnIsDetectedByRealSplitSimulation() public {
        SenderBurnToken burned = new SenderBurnToken(address(this));
        burned.transfer(address(splitter), 700);
        address bucket = address(new Bucket(address(burned), 250));
        _record("custom_token", address(burned), bucket);
        vm.expectRevert();
        harness.check(splitter, 1, _inventory(bucket));
        assertEq(burned.balanceOf(address(splitter)), 700);
        assertFalse(splitter.isSplit(address(burned)));
    }

    function test_transferLimitFailsPreflight() public {
        LimitedToken limited = new LimitedToken(address(this));
        limited.transfer(address(splitter), 700);
        address bucket = address(new Bucket(address(limited), 250));
        _record("custom_token", address(limited), bucket);
        vm.expectRevert("transfer limit");
        harness.check(splitter, 1, _inventory(bucket));
        assertEq(limited.balanceOf(address(splitter)), 700);
    }

    function test_noBucketsPassAndAllFundsReachTreasury() public {
        ILaunchRegistry.Artifact[] memory a = new ILaunchRegistry.Artifact[](1);
        a[0] = ILaunchRegistry.Artifact("token", "T", address(token));
        registry.record(1, "custom_token", a);
        harness.check(splitter, 1, new address[](0));
        assertEq(token.balanceOf(treasury), 700);
    }

    function test_overallocationFailsBeforeTransfers() public {
        address bucket = address(new Bucket(address(token), 701));
        _badGetter(bucket, "overallocated");
    }

    function test_manifestInventoryCannotSilentlyOmitPayingBucket() public {
        address bucket = address(new Bucket(address(token), 250));
        _record("custom_token", address(token), bucket);
        vm.expectRevert("unreviewed allocation");
        harness.check(splitter, 1, new address[](0));
    }

    function test_expectedBucketMustBelongToLaunch() public {
        address bucket = address(new Bucket(address(token), 0));
        _record("custom_token", address(token), bucket);
        address unrelated = address(new Bucket(address(token), 250));
        vm.expectRevert("expected bucket missing from registry");
        harness.check(splitter, 1, _inventory(unrelated));
    }

    function test_duplicateExpectedBucketIsRefused() public {
        address bucket = address(new Bucket(address(token), 250));
        _record("custom_token", address(token), bucket);
        address[] memory expected = new address[](2);
        expected[0] = bucket;
        expected[1] = bucket;
        vm.expectRevert("duplicate expected bucket");
        harness.check(splitter, 1, expected);
    }

    function testFuzz_exactAllocationConservesRemainder(uint256 allocation) public {
        allocation = bound(allocation, 0, 700);
        address bucket = address(new Bucket(address(token), allocation));
        _record("custom_token", address(token), bucket);
        harness.check(splitter, 1, _inventory(bucket));
        assertEq(token.balanceOf(bucket), allocation);
        assertEq(token.balanceOf(treasury), 700 - allocation);
        assertEq(token.balanceOf(address(splitter)), 0);
    }
}
