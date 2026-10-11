// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {GenesisSplitter, ILaunchRegistry} from "src/GenesisSplitter.sol";
import {
    SequenceRegistry,
    SequenceBucket,
    SequenceToken,
    FalseReturnToken,
    NoReturnToken
} from "./helpers/GenesisTestFixtures.sol";

/// forge-config: default.fuzz.runs = 1000
contract GenesisSplitterPropertiesTest is Test {
    SequenceRegistry internal registry;
    GenesisSplitter internal splitter;
    address internal treasury;
    uint64 internal constant LAUNCH = type(uint64).max;

    event Paid(address indexed token, address indexed bucket, bytes32 name, uint256 amount);
    event Split(uint64 indexed launchNumber, address indexed token, uint256 toBuckets, uint256 toTreasury);
    event Swept(address indexed token, uint256 amount);

    function setUp() public {
        registry = new SequenceRegistry();
        treasury = makeAddr("property treasury");
        splitter = new GenesisSplitter(address(registry), treasury);
    }

    function _record(address token, uint256 a, uint256 b) internal returns (address bucketA, address bucketB) {
        bucketA = address(new SequenceBucket(token, a));
        bucketB = address(new SequenceBucket(token, b));
        ILaunchRegistry.Artifact[] memory entries = new ILaunchRegistry.Artifact[](3);
        entries[0] = ILaunchRegistry.Artifact("other", "A", bucketA);
        entries[1] = ILaunchRegistry.Artifact("token", "T", token);
        entries[2] = ILaunchRegistry.Artifact("other", "B", bucketB);
        registry.record(LAUNCH, "custom_token", entries);
    }

    function _assertAtomic(SequenceToken token, address a, address b, uint256 held) internal view {
        assertFalse(splitter.isSplit(address(token)), "failed split consumed the token");
        assertEq(token.balanceOf(address(splitter)), held);
        assertEq(token.balanceOf(a), 0, "earlier payment was not rolled back");
        assertEq(token.balanceOf(b), 0);
        assertEq(token.balanceOf(treasury), 0);
    }

    function _assertPayments(SequenceToken token, address a, address b, uint256 amountA, uint256 amountB, uint256 rest)
        internal
        view
    {
        assertTrue(splitter.isSplit(address(token)));
        assertEq(token.balanceOf(a), amountA);
        assertEq(token.balanceOf(b), amountB);
        assertEq(token.balanceOf(treasury), rest);
        assertEq(token.balanceOf(address(splitter)), 0);
    }

    function testFuzz_fullUint256RangeConservesExactPayments(uint256 held, uint256 a, uint256 b) public {
        held = bound(held, 1, type(uint256).max);
        a = bound(a, 0, held);
        b = bound(b, 0, held - a);
        SequenceToken token = new SequenceToken(address(splitter), held);
        (address bucketA, address bucketB) = _record(address(token), a, b);
        vm.prank(makeAddr("permissionless caller"));
        splitter.split(LAUNCH);
        _assertPayments(token, bucketA, bucketB, a, b, held - a - b);
        assertEq(token.totalSupply(), held);
    }

    function testFuzz_oneWeiOverAllocationRollsBackEveryPayment(uint256 held, uint256 first) public {
        held = bound(held, 1, type(uint256).max - 1);
        first = bound(first, 0, held);
        SequenceToken token = new SequenceToken(address(splitter), held);
        (address a, address b) = _record(address(token), first, held - first + 1);
        vm.expectRevert(abi.encodeWithSelector(GenesisSplitter.OverAllocated.selector, held + 1, held));
        splitter.split(LAUNCH);
        _assertAtomic(token, a, b, held);
        // A failed split never permits someone to sweep the owed allocations away.
        vm.expectRevert(abi.encodeWithSelector(GenesisSplitter.NotSplit.selector, address(token)));
        splitter.sweep(address(token));
        _assertAtomic(token, a, b, held);
    }

    function test_oneWeiWithNoAllocationsGoesToTreasury() public {
        SequenceToken token = new SequenceToken(address(splitter), 1);
        (address a, address b) = _record(address(token), 0, 0);
        splitter.split(LAUNCH);
        _assertPayments(token, a, b, 0, 0, 1);
    }

    function test_oneWeiCanBeFullyAllocated() public {
        SequenceToken token = new SequenceToken(address(splitter), 1);
        (address a, address b) = _record(address(token), 1, 0);
        // No treasury transfer is needed when all funds are declared.
        token.rejectRecipient(treasury);
        splitter.split(LAUNCH);
        _assertPayments(token, a, b, 1, 0, 0);
    }

    function test_maximumSupplyCanBeFullyAllocatedAcrossBuckets() public {
        SequenceToken token = new SequenceToken(address(splitter), type(uint256).max);
        (address a, address b) = _record(address(token), type(uint256).max - 1, 1);
        splitter.split(LAUNCH);
        _assertPayments(token, a, b, type(uint256).max - 1, 1, 0);
    }

    function test_maximumSupplyCanAllGoToTreasury() public {
        SequenceToken token = new SequenceToken(address(splitter), type(uint256).max);
        (address a, address b) = _record(address(token), 0, 0);
        splitter.split(LAUNCH);
        _assertPayments(token, a, b, 0, 0, type(uint256).max);
    }

    function test_allocationSumOverflowRevertsAtomically() public {
        SequenceToken token = new SequenceToken(address(splitter), type(uint256).max);
        (address a, address b) = _record(address(token), type(uint256).max, 1);
        vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", 0x11));
        splitter.split(LAUNCH);
        _assertAtomic(token, a, b, type(uint256).max);
    }

    function test_emptyBalanceCanBeFundedAndRetried() public {
        SequenceToken token = new SequenceToken(address(this), 1);
        (address a, address b) = _record(address(token), 1, 0);
        vm.expectRevert(abi.encodeWithSelector(GenesisSplitter.NothingHeld.selector, address(token)));
        splitter.split(LAUNCH);
        _assertAtomic(token, a, b, 0);
        token.transfer(address(splitter), 1);
        splitter.split(LAUNCH);
        _assertPayments(token, a, b, 1, 0, 0);
    }

    function test_underfundedLaunchCanBeToppedUpAndRetried() public {
        SequenceToken token = new SequenceToken(address(this), 3);
        (address a, address b) = _record(address(token), 1, 2);
        token.transfer(address(splitter), 2);
        vm.expectRevert(abi.encodeWithSelector(GenesisSplitter.OverAllocated.selector, 3, 2));
        splitter.split(LAUNCH);
        _assertAtomic(token, a, b, 2);
        token.transfer(address(splitter), 1);
        splitter.split(LAUNCH);
        _assertPayments(token, a, b, 1, 2, 0);
    }

    function test_falseReturnOnSecondBucketRollsBackAndCanRetry() public {
        FalseReturnToken token = new FalseReturnToken(address(splitter), 1000);
        (address a, address b) = _record(address(token), 250, 100);
        token.returnFalseTo(b);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(token)));
        splitter.split(LAUNCH);
        _assertAtomic(token, a, b, 1000);
        token.returnFalseTo(makeAddr("unpaid recipient"));
        splitter.split(LAUNCH);
        _assertPayments(token, a, b, 250, 100, 650);
    }

    function test_treasuryRevertRollsBackAllBucketPaymentsAndCanRetry() public {
        SequenceToken token = new SequenceToken(address(splitter), 1000);
        (address a, address b) = _record(address(token), 250, 100);
        token.rejectRecipient(treasury);
        vm.expectRevert(abi.encodeWithSelector(SequenceToken.TransferRejected.selector, treasury));
        splitter.split(LAUNCH);
        _assertAtomic(token, a, b, 1000);
        token.rejectRecipient(makeAddr("unpaid recipient"));
        splitter.split(LAUNCH);
        _assertPayments(token, a, b, 250, 100, 650);
    }

    function test_noReturnTokenSupportsSplitAndLaterSweep() public {
        NoReturnToken token = new NoReturnToken(address(splitter), 1000);
        (address a, address b) = _record(address(token), 250, 100);
        splitter.split(LAUNCH);
        _assertPayments(token, a, b, 250, 100, 650);
        // Deposit without a typed bool-returning ERC20 call in the test harness.
        vm.prank(treasury);
        (bool ok,) = address(token).call(abi.encodeCall(IERC20.transfer, (address(splitter), 5)));
        assertTrue(ok);
        splitter.sweep(address(token));
        _assertPayments(token, a, b, 250, 100, 650);
    }

    function test_failedSweepKeepsCompletedStateAndBalanceForRetry() public {
        FalseReturnToken token = new FalseReturnToken(address(splitter), 1000);
        (address a, address b) = _record(address(token), 250, 100);
        splitter.split(LAUNCH);
        vm.prank(treasury);
        token.transfer(address(splitter), 7);
        token.returnFalseTo(treasury);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(token)));
        splitter.sweep(address(token));
        assertTrue(splitter.isSplit(address(token)));
        assertEq(token.balanceOf(address(splitter)), 7);
        assertEq(token.balanceOf(treasury), 643);
        assertEq(token.balanceOf(a), 250);
        assertEq(token.balanceOf(b), 100);
        token.returnFalseTo(makeAddr("unpaid recipient"));
        splitter.sweep(address(token));
        _assertPayments(token, a, b, 250, 100, 650);
    }

    function test_oncePerTokenAppliesAcrossLaunchNumbersWithLaterDeposits() public {
        SequenceToken token = new SequenceToken(address(this), 1007);
        (address a, address b) = _record(address(token), 250, 100);
        ILaunchRegistry.Artifact[] memory entries = registry.artifactsOf(LAUNCH);
        registry.record(0, "custom_token", entries);
        token.transfer(address(splitter), 1000);
        splitter.split(0);
        token.transfer(address(splitter), 7);
        vm.expectRevert(abi.encodeWithSelector(GenesisSplitter.AlreadySplit.selector, address(token)));
        splitter.split(LAUNCH);
        assertEq(token.balanceOf(address(splitter)), 7);
        splitter.sweep(address(token));
        _assertPayments(token, a, b, 250, 100, 657);
    }

    function test_emptyArtifactsAndZeroTokenAreRefused() public {
        registry.record(LAUNCH, "custom_token", new ILaunchRegistry.Artifact[](0));
        vm.expectRevert(abi.encodeWithSelector(GenesisSplitter.NoToken.selector, LAUNCH));
        splitter.split(LAUNCH);
        ILaunchRegistry.Artifact[] memory entries = new ILaunchRegistry.Artifact[](1);
        entries[0] = ILaunchRegistry.Artifact("token", "T", address(0));
        registry.record(LAUNCH, "custom_token", entries);
        vm.expectRevert(abi.encodeWithSelector(GenesisSplitter.NoToken.selector, LAUNCH));
        splitter.split(LAUNCH);
    }

    function test_unrecordedLaunchIsRefused() public {
        vm.expectRevert(abi.encodeWithSelector(GenesisSplitter.NotCustomTokenLaunch.selector, LAUNCH));
        splitter.split(LAUNCH);
    }

    function test_registryReadFailureDoesNotConsumeFundsOrLockGuard() public {
        SequenceToken token = new SequenceToken(address(splitter), 1000);
        (address a, address b) = _record(address(token), 250, 100);
        vm.mockCallRevert(address(registry), abi.encodeCall(registry.artifactsOf, (LAUNCH)), "registry unavailable");
        vm.expectRevert(bytes("registry unavailable"));
        splitter.split(LAUNCH);
        _assertAtomic(token, a, b, 1000);
        vm.clearMockedCalls();
        splitter.split(LAUNCH);
        _assertPayments(token, a, b, 250, 100, 650);
    }

    function test_balanceReadFailureDoesNotConsumeFundsOrLockGuard() public {
        SequenceToken token = new SequenceToken(address(splitter), 1000);
        (address a, address b) = _record(address(token), 250, 100);
        vm.mockCallRevert(address(token), abi.encodeCall(token.balanceOf, (address(splitter))), "balance unavailable");
        vm.expectRevert(bytes("balance unavailable"));
        splitter.split(LAUNCH);
        vm.clearMockedCalls();
        _assertAtomic(token, a, b, 1000);
        splitter.split(LAUNCH);
        _assertPayments(token, a, b, 250, 100, 650);
    }

    function test_paymentEventsAndRepeatedEmptySweep() public {
        SequenceToken token = new SequenceToken(address(splitter), 1000);
        (address a, address b) = _record(address(token), 250, 100);
        vm.expectEmit(true, true, false, true, address(splitter));
        emit Paid(address(token), a, "A", 250);
        vm.expectEmit(true, true, false, true, address(splitter));
        emit Paid(address(token), b, "B", 100);
        vm.expectEmit(true, true, false, true, address(splitter));
        emit Split(LAUNCH, address(token), 350, 650);
        splitter.split(LAUNCH);
        for (uint256 i; i < 2; ++i) {
            vm.expectEmit(true, false, false, true, address(splitter));
            emit Swept(address(token), 0);
            splitter.sweep(address(token));
        }
        _assertPayments(token, a, b, 250, 100, 650);
    }
}
