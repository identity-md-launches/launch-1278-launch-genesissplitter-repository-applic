// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {GenesisSplitter, ILaunchRegistry} from "src/GenesisSplitter.sol";

contract Token is ERC20 {
    constructor(string memory name, address to, uint256 amount) ERC20(name, name) {
        _mint(to, amount);
    }
}

/// @dev A bucket as the swarm will build each one: it names its token and declares its share in code.
contract Bucket {
    address public immutable token;
    uint256 public immutable genesisAllocation;

    constructor(address token_, uint256 allocation_) {
        (token, genesisAllocation) = (token_, allocation_);
    }
}

/// @dev A launch contract that is not a bucket (a staking vault): it declares no allocation.
contract NotABucket {
    address public immutable token;

    constructor(address token_) {
        token = token_;
    }
}

/// @dev The plane's LaunchRegistry, reduced to what the splitter reads. Written only by the test, as the real
/// one is written only by its factory.
contract MockRegistry {
    mapping(uint64 => ILaunchRegistry.Launch) private _launches;
    mapping(uint64 => ILaunchRegistry.Artifact[]) private _artifacts;

    function record(uint64 n, bytes32 kind, ILaunchRegistry.Artifact[] memory artifacts) external {
        _launches[n].kind = kind;
        _launches[n].launchNumber = n;
        for (uint256 i; i < artifacts.length; ++i) {
            _artifacts[n].push(artifacts[i]);
        }
    }

    function launchOf(uint64 n) external view returns (ILaunchRegistry.Launch memory) {
        return _launches[n];
    }

    function artifactsOf(uint64 n) external view returns (ILaunchRegistry.Artifact[] memory) {
        return _artifacts[n];
    }
}

contract TreasuryLike {}

contract GenesisSplitterTest is Test {
    uint64 constant LAUNCH = 812;
    uint256 constant REMAINDER = 700_000_000e18;
    address constant FACTORY = address(0xFAC7);

    MockRegistry registry;
    GenesisSplitter splitter;
    TreasuryLike treasury;
    Token token;
    address bucketA;
    address bucketB;
    address bucketC;
    address bucketD;
    address vault;

    function setUp() public {
        registry = new MockRegistry();
        treasury = new TreasuryLike();
        splitter = new GenesisSplitter(address(registry), address(treasury));
        _launchToken(LAUNCH, address(splitter));
    }

    /// @dev What `launchCustom` does: mint 1B to the factory, keep 10% (swarm) + 20% (pool), send the 70%
    /// remainder to `remainderTo`, and record the artifacts in the same transaction.
    function _launchToken(uint64 n, address remainderTo) private {
        token = new Token("TOKEN", FACTORY, 1_000_000_000e18);
        bucketA = address(new Bucket(address(token), 250_000_000e18));
        bucketB = address(new Bucket(address(token), 100_000_000e18));
        bucketC = address(new Bucket(address(token), 100_000_000e18));
        bucketD = address(new Bucket(address(token), 100_000_000e18));
        vault = address(new NotABucket(address(token)));
        ILaunchRegistry.Artifact[] memory a = new ILaunchRegistry.Artifact[](8);
        a[0] = ILaunchRegistry.Artifact("token", "TOKEN", address(token));
        a[1] = ILaunchRegistry.Artifact("distributor", "MerkleDistributor", address(0xD157));
        a[2] = ILaunchRegistry.Artifact("other", "BucketA", bucketA);
        a[3] = ILaunchRegistry.Artifact("other", "StakingDrip", bucketB);
        a[4] = ILaunchRegistry.Artifact("other", "BucketC", bucketC);
        a[5] = ILaunchRegistry.Artifact("other", "BucketD", bucketD);
        a[6] = ILaunchRegistry.Artifact("other", "Vault", vault);
        a[7] = ILaunchRegistry.Artifact("hook", "PoolInitializationGuard", address(0x600D));
        registry.record(n, "custom_token", a);
        vm.prank(FACTORY);
        token.transfer(remainderTo, REMAINDER);
    }

    function test_theLaunchSplitsItselfToItsOwnBuckets() public {
        vm.prank(address(0xA11CE)); // anyone
        splitter.split(LAUNCH);
        assertEq(token.balanceOf(bucketA), 250_000_000e18);
        assertEq(token.balanceOf(bucketB), 100_000_000e18);
        assertEq(token.balanceOf(bucketC), 100_000_000e18);
        assertEq(token.balanceOf(bucketD), 100_000_000e18);
        assertEq(token.balanceOf(vault), 0, "a contract that declares no share gets none");
        assertEq(token.balanceOf(address(treasury)), 150_000_000e18, "what no bucket declares goes to the Treasury");
        assertEq(token.balanceOf(address(splitter)), 0);
        assertTrue(splitter.isSplit(address(token)));
    }

    function test_onlyOncePerToken() public {
        splitter.split(LAUNCH);
        vm.expectRevert(abi.encodeWithSelector(GenesisSplitter.AlreadySplit.selector, address(token)));
        splitter.split(LAUNCH);
    }

    function test_deployingDisclosesNothingAndTakesNoInstructions() public view {
        assertEq(address(splitter.registry()), address(registry));
        assertEq(splitter.treasury(), address(treasury));
        assertFalse(splitter.isSplit(address(token)));
    }

    /// @dev A stranger runs their own launch with our splitter as `remainderTo`: it splits only their token,
    /// to their buckets, and leaves the first token untouched and still splittable.
    function test_aStrangersLaunchCannotTouchOurs() public {
        Token other = new Token("OTHER", FACTORY, 1_000e18);
        address theirBucket = address(new Bucket(address(other), 600e18));
        ILaunchRegistry.Artifact[] memory a = new ILaunchRegistry.Artifact[](2);
        a[0] = ILaunchRegistry.Artifact("token", "OTHER", address(other));
        a[1] = ILaunchRegistry.Artifact("other", "Theirs", theirBucket);
        registry.record(999, "custom_token", a);
        vm.prank(FACTORY);
        other.transfer(address(splitter), 700e18);

        splitter.split(999);
        assertEq(other.balanceOf(theirBucket), 600e18);
        assertEq(token.balanceOf(address(splitter)), REMAINDER, "first token untouched");
        splitter.split(LAUNCH);
        assertEq(token.balanceOf(bucketA), 250_000_000e18);
    }

    /// @dev A stranger's launch that points its "buckets" at another launch's token still pays only its own token.
    function test_aStrangersBucketNamingAnotherTokenIsRefused() public {
        Token other = new Token("OTHER", FACTORY, 1_000e18);
        address thief = address(new Bucket(address(token), 1e18)); // claims to serve the other token
        ILaunchRegistry.Artifact[] memory a = new ILaunchRegistry.Artifact[](2);
        a[0] = ILaunchRegistry.Artifact("token", "OTHER", address(other));
        a[1] = ILaunchRegistry.Artifact("other", "Thief", thief);
        registry.record(998, "custom_token", a);
        vm.prank(FACTORY);
        other.transfer(address(splitter), 700e18);
        vm.expectRevert(abi.encodeWithSelector(GenesisSplitter.WrongToken.selector, thief));
        splitter.split(998);
    }

    function test_overAllocationIsRefused() public {
        GenesisSplitter s = new GenesisSplitter(address(registry), address(treasury));
        Token t = new Token("T", FACTORY, 1_000e18);
        ILaunchRegistry.Artifact[] memory a = new ILaunchRegistry.Artifact[](3);
        a[0] = ILaunchRegistry.Artifact("token", "T", address(t));
        a[1] = ILaunchRegistry.Artifact("other", "A", address(new Bucket(address(t), 600e18)));
        a[2] = ILaunchRegistry.Artifact("other", "B", address(new Bucket(address(t), 200e18)));
        registry.record(700, "custom_token", a);
        vm.prank(FACTORY);
        t.transfer(address(s), 700e18);
        vm.expectRevert(abi.encodeWithSelector(GenesisSplitter.OverAllocated.selector, 800e18, 700e18));
        s.split(700);
    }

    function test_refusesNonCustomLaunchesAndLaunchesThatSentNothing() public {
        ILaunchRegistry.Artifact[] memory a = new ILaunchRegistry.Artifact[](1);
        a[0] = ILaunchRegistry.Artifact("other", "Splitter", address(splitter));
        registry.record(5, "evm_contracts", a);
        vm.expectRevert(abi.encodeWithSelector(GenesisSplitter.NotCustomTokenLaunch.selector, uint64(5)));
        splitter.split(5);

        Token t = new Token("T", FACTORY, 1e18); // a launch whose remainder went elsewhere
        ILaunchRegistry.Artifact[] memory b = new ILaunchRegistry.Artifact[](1);
        b[0] = ILaunchRegistry.Artifact("token", "T", address(t));
        registry.record(6, "custom_token", b);
        vm.expectRevert(abi.encodeWithSelector(GenesisSplitter.NothingHeld.selector, address(t)));
        splitter.split(6);
    }

    function test_strayTokensAfterTheSplitGoToTheTreasury() public {
        vm.expectRevert(abi.encodeWithSelector(GenesisSplitter.NotSplit.selector, address(token)));
        splitter.sweep(address(token));
        splitter.split(LAUNCH);
        vm.prank(FACTORY);
        token.transfer(address(splitter), 5e18);
        splitter.sweep(address(token));
        assertEq(token.balanceOf(address(treasury)), 150_000_000e18 + 5e18);
    }

    /// @dev The splitter's own launch runs constructors on a bare chain: the constructor must not read the
    /// registry or the Treasury.
    function test_constructorReadsNoOtherContract() public {
        GenesisSplitter s = new GenesisSplitter(address(0xBEEF01), address(0xBEEF02));
        assertEq(address(s.registry()), address(0xBEEF01));
        vm.expectRevert(GenesisSplitter.ZeroAddress.selector);
        new GenesisSplitter(address(0), address(treasury));
    }
}
