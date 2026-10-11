// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {GenesisSplitter, ILaunchRegistry} from "src/GenesisSplitter.sol";
import {MockRegistry, Token, Bucket, NotABucket} from "./GenesisSplitter.t.sol";

contract BadTokenBucket {
    bytes32 public constant token = "TOKEN";
    uint256 public constant genesisAllocation = 1;
}

contract MissingTokenBucket {
    uint256 public constant genesisAllocation = 1;
}

contract RevertingBucket {
    function genesisAllocation() external pure returns (uint256) {
        revert("uninitialised");
    }
}

contract TupleBucket {
    function genesisAllocation() external pure returns (uint256, uint256) {
        return (250, 0);
    }
}

contract SenderBurnToken is ERC20 {
    address public immutable factory;

    constructor(address factory_) ERC20("Burn", "BURN") {
        factory = factory_;
        _mint(factory_, 1000);
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (from != address(0) && to != address(0) && from != factory) _burn(from, value / 100);
    }
}

contract ReceiverTaxToken is ERC20 {
    address public immutable factory;

    constructor(address factory_) ERC20("Tax", "TAX") {
        factory = factory_;
        _mint(factory_, 1000);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0) && from != factory) {
            _burn(from, value / 100);
            super._update(from, to, value - value / 100);
        } else {
            super._update(from, to, value);
        }
    }
}

contract LimitedToken is ERC20 {
    address public immutable factory;

    constructor(address factory_) ERC20("Limited", "LIMIT") {
        factory = factory_;
        _mint(factory_, 1000);
    }

    function _update(address from, address to, uint256 value) internal override {
        require(from == address(0) || from == factory || value <= 200, "transfer limit");
        super._update(from, to, value);
    }
}

contract HookToken is ERC20 {
    GenesisSplitter public splitter;
    bytes public callback;
    bool private entered;
    bool public callbackSucceeded;
    bytes public callbackResult;

    constructor(address to) ERC20("Hook", "HOOK") {
        _mint(to, 1000);
    }

    function arm(GenesisSplitter s, bytes memory data) external {
        splitter = s;
        callback = data;
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (from == address(splitter) && !entered) {
            entered = true;
            (callbackSucceeded, callbackResult) = address(splitter).call(callback);
            entered = false;
        }
    }
}

contract GenesisSplitterAuditTest is Test {
    MockRegistry internal registry;
    GenesisSplitter internal splitter;
    address internal treasury;
    Token internal token;
    address internal goodBucket;

    function setUp() public {
        registry = new MockRegistry();
        treasury = makeAddr("treasury");
        splitter = new GenesisSplitter(address(registry), treasury);
        token = new Token("T", address(this), 1000);
        goodBucket = address(new Bucket(address(token), 250));
        token.transfer(address(splitter), 700);
    }

    function _record(uint64 n, bytes32 kind, address t, address bad) internal {
        ILaunchRegistry.Artifact[] memory a = new ILaunchRegistry.Artifact[](bad == address(0) ? 1 : 3);
        a[0] = ILaunchRegistry.Artifact("token", "T", t);
        if (bad != address(0)) {
            a[1] = ILaunchRegistry.Artifact("other", "Good", address(new Bucket(t, 250)));
            a[2] = ILaunchRegistry.Artifact("other", "Candidate", bad);
        }
        registry.record(n, kind, a);
    }

    function _assertUnsplit() internal view {
        assertFalse(splitter.isSplit(address(token)));
        assertEq(token.balanceOf(address(splitter)), 700);
        assertEq(token.balanceOf(treasury), 0);
    }

    function test_wrongTokenPermanentlyRefusesSplitAndSweep() public {
        Token foreign = new Token("FOREIGN", address(this), 1);
        address bad = address(new Bucket(address(foreign), 1));
        _record(1, "custom_token", address(token), bad);
        for (uint256 i; i < 2; ++i) {
            vm.expectRevert(abi.encodeWithSelector(GenesisSplitter.WrongToken.selector, bad));
            splitter.split(1);
        }
        vm.expectRevert(abi.encodeWithSelector(GenesisSplitter.NotSplit.selector, address(token)));
        splitter.sweep(address(token));
        _assertUnsplit();
    }

    function test_dirtyAddressGetterRevertsAndRollsBack() public {
        _record(1, "custom_token", address(token), address(new BadTokenBucket()));
        vm.expectRevert();
        splitter.split(1);
        _assertUnsplit();
    }

    function test_missingTokenGetterRefusesSplit() public {
        address bad = address(new MissingTokenBucket());
        _record(1, "custom_token", address(token), bad);
        vm.expectRevert(abi.encodeWithSelector(GenesisSplitter.WrongToken.selector, bad));
        splitter.split(1);
        _assertUnsplit();
    }

    function test_projectRemainderCannotSplitOrSweep() public {
        _record(1, "evm_project", address(token), goodBucket);
        vm.expectRevert(abi.encodeWithSelector(GenesisSplitter.NotCustomTokenLaunch.selector, uint64(1)));
        splitter.split(1);
        vm.expectRevert(abi.encodeWithSelector(GenesisSplitter.NotSplit.selector, address(token)));
        splitter.sweep(address(token));
        _assertUnsplit();
    }

    function test_unregisteredStrayTokenCannotSweep() public {
        vm.expectRevert(abi.encodeWithSelector(GenesisSplitter.NotSplit.selector, address(token)));
        splitter.sweep(address(token));
        _assertUnsplit();
    }

    function test_senderBurnRevertsAtomically() public {
        SenderBurnToken burn = new SenderBurnToken(address(this));
        burn.transfer(address(splitter), 700);
        _record(1, "custom_token", address(burn), address(new Bucket(address(burn), 100)));
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, address(splitter), 347, 350)
        );
        splitter.split(1);
        assertEq(burn.balanceOf(address(splitter)), 700);
        assertEq(burn.balanceOf(treasury), 0);
        assertFalse(splitter.isSplit(address(burn)));
    }

    function test_receiverTaxUnderpaysDespiteSuccessfulSplit() public {
        ReceiverTaxToken taxed = new ReceiverTaxToken(address(this));
        taxed.transfer(address(splitter), 700);
        address bucket = address(new Bucket(address(taxed), 100));
        _record(1, "custom_token", address(taxed), bucket);
        splitter.split(1);
        assertEq(taxed.balanceOf(bucket), 99);
        assertEq(taxed.balanceOf(treasury), 347);
        assertTrue(splitter.isSplit(address(taxed)));
    }

    function test_transferLimitRefusesBucketPaymentAtomically() public {
        LimitedToken limited = new LimitedToken(address(this));
        limited.transfer(address(splitter), 700);
        _record(1, "custom_token", address(limited), address(new Bucket(address(limited), 100)));
        vm.expectRevert("transfer limit");
        splitter.split(1);
        assertEq(limited.balanceOf(address(splitter)), 700);
        assertFalse(splitter.isSplit(address(limited)));
    }

    function test_revertingAllocationIsSkipped() public {
        address bad = address(new RevertingBucket());
        _record(1, "custom_token", address(token), bad);
        splitter.split(1);
        assertEq(token.balanceOf(bad), 0);
        assertEq(token.balanceOf(treasury), 450);
        assertTrue(splitter.isSplit(address(token)));
    }

    function test_tupleAllocationIsSkipped() public {
        address bad = address(new TupleBucket());
        _record(1, "custom_token", address(token), bad);
        splitter.split(1);
        assertEq(token.balanceOf(bad), 0);
        assertEq(token.balanceOf(treasury), 450);
    }

    function test_noOtherArtifactsPaysEverythingToTreasury() public {
        _record(1, "custom_token", address(token), address(0));
        splitter.split(1);
        assertEq(token.balanceOf(treasury), 700);
        assertEq(token.balanceOf(address(splitter)), 0);
    }

    function test_sweepCallbackCannotInterruptSplit() public {
        HookToken hooked = new HookToken(address(this));
        hooked.transfer(address(splitter), 700);
        _record(1, "custom_token", address(hooked), address(new Bucket(address(hooked), 100)));
        hooked.arm(splitter, abi.encodeCall(splitter.sweep, (address(hooked))));
        splitter.split(1);
        assertFalse(hooked.callbackSucceeded());
        assertEq(hooked.callbackResult(), abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector));
        assertEq(hooked.balanceOf(treasury), 350);
        assertEq(hooked.balanceOf(address(splitter)), 0);
    }

    function test_splitCallbackCannotReenterSplit() public {
        HookToken hooked = new HookToken(address(this));
        hooked.transfer(address(splitter), 700);
        _record(1, "custom_token", address(hooked), address(new Bucket(address(hooked), 100)));
        hooked.arm(splitter, abi.encodeCall(splitter.split, (uint64(1))));
        splitter.split(1);
        assertFalse(hooked.callbackSucceeded());
        assertEq(hooked.callbackResult(), abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector));
        assertEq(hooked.balanceOf(treasury), 350);
    }

    function test_sweepCallbackCannotReenterSweep() public {
        HookToken hooked = new HookToken(address(this));
        hooked.transfer(address(splitter), 700);
        _record(1, "custom_token", address(hooked), address(new Bucket(address(hooked), 100)));
        splitter.split(1);
        hooked.transfer(address(splitter), 50);
        hooked.arm(splitter, abi.encodeCall(splitter.sweep, (address(hooked))));
        splitter.sweep(address(hooked));
        assertFalse(hooked.callbackSucceeded());
        assertEq(hooked.callbackResult(), abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector));
        assertEq(hooked.balanceOf(treasury), 400);
        assertEq(hooked.balanceOf(address(splitter)), 0);
    }
}
