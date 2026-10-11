// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {GenesisSplitter, ILaunchRegistry} from "src/GenesisSplitter.sol";
import {SequenceRegistry, SequenceToken, SequenceBucket} from "./helpers/GenesisTestFixtures.sol";

/// @dev Only these handler actions are targeted; the registry, fixtures, and ghost state cannot be
/// mutated directly by Forge. Token fixtures transfer exact amounts or revert, without mint/burn/rebase.
contract GenesisSequenceHandler is Test {
    uint256 public constant TOKEN_COUNT = 5;
    uint256 public constant ACTOR_COUNT = 3;
    uint256 public constant INITIAL_ACTOR_BALANCE = 1e24;

    struct State {
        SequenceToken token;
        address bucketA;
        address bucketB;
        address ignored;
        uint256 allocationA;
        uint256 allocationB;
        uint256 funded;
        uint256 treasuryPaid;
        uint256 splitCount;
        bool finished;
    }

    GenesisSplitter public immutable splitter;
    address public immutable treasury;
    State[TOKEN_COUNT] private states;
    address[ACTOR_COUNT] public actors;
    mapping(uint256 => mapping(address => uint256)) public contributed;
    uint256 public successfulSplits;
    uint256 public successfulSweeps;
    uint256 public refusedCalls;

    constructor() {
        SequenceRegistry registry = new SequenceRegistry();
        treasury = makeAddr("invariant treasury");
        splitter = new GenesisSplitter(address(registry), treasury);
        for (uint256 a; a < ACTOR_COUNT; ++a) {
            actors[a] = makeAddr(string.concat("sequence actor ", vm.toString(a)));
        }
        for (uint256 i; i < TOKEN_COUNT; ++i) {
            State storage s = states[i];
            s.token = new SequenceToken(address(this), INITIAL_ACTOR_BALANCE * ACTOR_COUNT);
            if (i == 1) (s.allocationA, s.allocationB) = (250, 100);
            if (i == 2) (s.allocationA, s.allocationB) = (700, 300);
            if (i == 3) (s.allocationA, s.allocationB) = (1, 0);
            s.bucketA = address(new SequenceBucket(address(s.token), s.allocationA));
            s.bucketB = address(new SequenceBucket(address(s.token), s.allocationB));
            // A declaration on a different artifact role must not be paid or validated as a bucket.
            s.ignored = address(new SequenceBucket(treasury, type(uint256).max));
            if (i < TOKEN_COUNT - 1) {
                ILaunchRegistry.Artifact[] memory entries = new ILaunchRegistry.Artifact[](5);
                entries[0] = ILaunchRegistry.Artifact("other", "A", s.bucketA);
                entries[1] = ILaunchRegistry.Artifact("hook", "IgnoredHook", s.ignored);
                entries[2] = ILaunchRegistry.Artifact("token", "T", address(s.token));
                entries[3] = ILaunchRegistry.Artifact("other", "B", s.bucketB);
                entries[4] = ILaunchRegistry.Artifact("distributor", "IgnoredDistributor", s.ignored);
                registry.record(uint64(i + 1), "custom_token", entries);
                // Alias exercises per-token rather than per-launch replay protection.
                registry.record(uint64(i + 101), "custom_token", entries);
            }
            for (uint256 a; a < ACTOR_COUNT; ++a) {
                s.token.transfer(actors[a], INITIAL_ACTOR_BALANCE);
            }
        }
        // Guarantee that initial states include unfunded, underfunded, exact, and dust remainders.
        _donate(1, actors[0], 200);
        _donate(2, actors[0], 1000);
        _donate(3, actors[0], 1);
    }

    function state(uint256 i) external view returns (State memory) {
        return states[i];
    }

    function held(uint256 i) public view returns (uint256) {
        State storage s = states[i];
        return s.funded - s.treasuryPaid - (s.finished ? s.allocationA + s.allocationB : 0);
    }

    function _donate(uint256 i, address actor, uint256 amount) internal {
        vm.prank(actor);
        states[i].token.transfer(address(splitter), amount);
        states[i].funded += amount;
        contributed[i][actor] += amount;
    }

    function donate(uint256 tokenSeed, uint256 actorSeed, uint256 amount) external {
        uint256 i = tokenSeed % TOKEN_COUNT;
        address actor = actors[actorSeed % ACTOR_COUNT];
        amount = bound(amount, 0, states[i].token.balanceOf(actor));
        _donate(i, actor, amount);
    }

    function donateDust(uint256 tokenSeed, uint256 actorSeed) external {
        uint256 i = tokenSeed % TOKEN_COUNT;
        address actor = actors[actorSeed % ACTOR_COUNT];
        if (states[i].token.balanceOf(actor) != 0) _donate(i, actor, 1);
    }

    function topUpToAllocation(uint256 tokenSeed, uint256 actorSeed) external {
        uint256 i = tokenSeed % TOKEN_COUNT;
        State storage s = states[i];
        address actor = actors[actorSeed % ACTOR_COUNT];
        uint256 target = s.allocationA + s.allocationB;
        if (target == 0) target = 1;
        uint256 current = held(i);
        if (current < target) {
            uint256 amount = target - current;
            uint256 available = s.token.balanceOf(actor);
            _donate(i, actor, amount < available ? amount : available);
        }
    }

    function rejectPayment(uint256 tokenSeed, uint256 recipientSeed, bool reject) external {
        State storage s = states[tokenSeed % TOKEN_COUNT];
        uint256 recipient = recipientSeed % 3;
        address destination = recipient == 0 ? s.bucketA : recipient == 1 ? s.bucketB : treasury;
        s.token.rejectRecipient(reject ? destination : address(this));
    }

    function splitLaunch(uint256 tokenSeed, uint256 actorSeed, bool aliasLaunch) external {
        uint256 i = tokenSeed % TOKEN_COUNT;
        State storage s = states[i];
        uint256 beforeHeld = held(i);
        uint256 allocation = s.allocationA + s.allocationB;
        address blocked = s.token.rejectedRecipient();
        bool canPay = !(blocked == s.bucketA && s.allocationA != 0) && !(blocked == s.bucketB && s.allocationB != 0)
            && !(blocked == treasury && beforeHeld > allocation);
        bool expectedSuccess =
            i < TOKEN_COUNT - 1 && !s.finished && beforeHeld != 0 && beforeHeld >= allocation && canPay;
        uint64 number = uint64(i + (aliasLaunch ? 101 : 1));
        vm.prank(actors[actorSeed % ACTOR_COUNT]);
        (bool success,) = address(splitter).call(abi.encodeCall(splitter.split, (number)));
        assertEq(success, expectedSuccess, "split success differs from funding/payment preconditions");
        if (success) {
            s.finished = true;
            ++s.splitCount;
            s.treasuryPaid += beforeHeld - allocation;
            ++successfulSplits;
        } else {
            ++refusedCalls;
        }
        // Also checked immediately on refused calls, to catch any partial payment or consumed state.
        assertAccounting();
    }

    function sweepToken(uint256 tokenSeed, uint256 actorSeed) external {
        uint256 i = tokenSeed % TOKEN_COUNT;
        State storage s = states[i];
        uint256 beforeHeld = held(i);
        // This fixture rejects the destination even for a zero-value transfer.
        bool expectedSuccess = s.finished && s.token.rejectedRecipient() != treasury;
        vm.prank(actors[actorSeed % ACTOR_COUNT]);
        (bool success,) = address(splitter).call(abi.encodeCall(splitter.sweep, (address(s.token))));
        assertEq(success, expectedSuccess, "sweep bypassed completion or failed unexpectedly");
        if (success) {
            s.treasuryPaid += beforeHeld;
            ++successfulSweeps;
        } else {
            ++refusedCalls;
        }
        assertAccounting();
    }

    function unknownLaunch(uint64 number, uint256 actorSeed) external {
        // Keep this in a disjoint identifier range without rejecting random inputs.
        number = uint64(bound(number, 1000, type(uint64).max));
        vm.prank(actors[actorSeed % ACTOR_COUNT]);
        (bool success, bytes memory result) = address(splitter).call(abi.encodeCall(splitter.split, (number)));
        assertFalse(success, "unregistered launch split succeeded");
        assertEq(result, abi.encodeWithSelector(GenesisSplitter.NotCustomTokenLaunch.selector, number));
        ++refusedCalls;
        assertAccounting();
    }

    function assertAccounting() public view {
        for (uint256 i; i < TOKEN_COUNT; ++i) {
            State storage s = states[i];
            assertEq(s.token.balanceOf(address(splitter)), held(i), "custody differs from funded less paid");
            assertEq(s.token.balanceOf(treasury), s.treasuryPaid, "treasury got an undeclared amount");
            assertEq(s.token.balanceOf(s.bucketA), s.finished ? s.allocationA : 0, "A not paid exactly once");
            assertEq(s.token.balanceOf(s.bucketB), s.finished ? s.allocationB : 0, "B not paid exactly once");
            assertEq(s.token.balanceOf(s.ignored), 0, "non-other artifact was paid");
            assertEq(splitter.isSplit(address(s.token)), s.finished, "completion changed on failed call");
            assertLe(s.splitCount, 1, "token split more than once");
            if (i == TOKEN_COUNT - 1) assertFalse(s.finished, "unregistered token was split");
        }
    }

    function assertConservation() public view {
        for (uint256 i; i < TOKEN_COUNT; ++i) {
            State storage s = states[i];
            uint256 total = s.token.balanceOf(address(splitter)) + s.token.balanceOf(treasury)
                + s.token.balanceOf(s.bucketA) + s.token.balanceOf(s.bucketB);
            for (uint256 a; a < ACTOR_COUNT; ++a) {
                address actor = actors[a];
                uint256 balance = s.token.balanceOf(actor);
                assertEq(balance, INITIAL_ACTOR_BALANCE - contributed[i][actor], "caller extracted tokens");
                total += balance;
            }
            assertEq(s.token.balanceOf(address(this)), 0, "unexpected tokens in handler");
            assertEq(total, INITIAL_ACTOR_BALANCE * ACTOR_COUNT, "supply escaped accounted recipients");
            assertEq(s.token.totalSupply(), total, "supply changed during split/sweep");
        }
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 128
/// forge-config: default.invariant.fail-on-revert = true
contract GenesisSplitterInvariantTest is Test {
    GenesisSequenceHandler internal handler;

    function setUp() public {
        handler = new GenesisSequenceHandler();
        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = handler.donate.selector;
        selectors[1] = handler.donateDust.selector;
        selectors[2] = handler.topUpToAllocation.selector;
        selectors[3] = handler.rejectPayment.selector;
        selectors[4] = handler.splitLaunch.selector;
        selectors[5] = handler.sweepToken.selector;
        selectors[6] = handler.unknownLaunch.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector(address(handler), selectors));
        // Bound Forge's outer callers too, so fork runs do not fetch a new remote account per step.
        for (uint256 i; i < handler.ACTOR_COUNT(); ++i) {
            targetSender(handler.actors(i));
        }
    }

    /// @dev Brief: every declared allocation is paid once, remainder and later deposits go to treasury.
    function invariant_exactPaymentsAndMonotonicCompletion() public view {
        handler.assertAccounting();
    }

    /// @dev Exact identity: fixed minted supply equals balances of all actors and permitted recipients.
    function invariant_conservationAndNoCallerProfit() public view {
        handler.assertConservation();
    }

    /// @dev Deterministic witness that the harness reaches failure, retry, alias, and post-split states.
    function test_handlerExercisesFailureRetryAndLaterDeposits() public {
        handler.splitLaunch(1, 0, false); // Underfunded second allocation, first payment must roll back.
        handler.sweepToken(1, 1); // Cannot sweep before a completed split.
        handler.topUpToAllocation(1, 2);
        handler.rejectPayment(1, 1, true); // Second bucket refuses payment.
        handler.splitLaunch(1, 2, true);
        handler.rejectPayment(1, 1, false);
        handler.splitLaunch(1, 1, false);
        handler.donateDust(1, 0);
        handler.splitLaunch(1, 2, true); // Alias cannot pay twice even after a deposit.
        handler.rejectPayment(1, 2, true);
        handler.sweepToken(1, 0); // Completed status survives a failed sweep.
        handler.rejectPayment(1, 2, false);
        handler.sweepToken(1, 2);
        handler.sweepToken(1, 1); // Empty sweeps may repeat without paying buckets again.
        handler.donateDust(4, 0); // An unrelated token cannot be taken by another launch.
        handler.splitLaunch(4, 0, false);
        handler.sweepToken(4, 1);
        handler.unknownLaunch(type(uint64).max, 0);
        assertEq(handler.successfulSplits(), 1);
        assertEq(handler.successfulSweeps(), 2);
        assertEq(handler.refusedCalls(), 8);
        handler.assertAccounting();
        handler.assertConservation();
    }
}
