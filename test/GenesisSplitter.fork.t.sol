// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {GenesisSplitter, ILaunchRegistry} from "src/GenesisSplitter.sol";

contract ForkToken is ERC20 {
    constructor(address to) ERC20("TOKEN", "TOKEN") {
        _mint(to, 1_000_000_000e18);
    }
}

contract ForkBucket {
    address public immutable token;
    uint256 public immutable genesisAllocation;

    constructor(address token_, uint256 allocation_) {
        (token, genesisAllocation) = (token_, allocation_);
    }
}

/// @dev The registry's write side, exactly as the plane's factory calls it.
interface IRegistryWriter {
    function record(ILaunchRegistry.Launch calldata launch, ILaunchRegistry.Artifact[] calldata artifacts, uint256[] calldata agentIds)
        external;
}

/// @notice Against the REAL mainnet LaunchRegistry (deployments/mainnet.json in the plane): the splitter's
/// interface must decode what that contract returns. The factory is impersonated to write one record the way
/// `launchCustom` does; nothing else is mocked.
///   forge test --match-path test/GenesisSplitter.fork.t.sol --fork-url $MAINNET_RPC_URL
contract GenesisSplitterForkTest is Test {
    address constant PROJECT_FACTORY = 0xfF03410d0Fe5fa8f7F59F743de35E333D9857120;
    address constant REGISTRY = 0x7c9D5ee697BfF5Ac4F10E2E54d3f40c44e48fE23;
    uint64 constant LAUNCH = 4_000_000_001; // far beyond any real launch number

    function setUp() public {
        if (block.chainid != 1 || REGISTRY.code.length == 0) vm.skip(true);
    }

    function test_readsTheRealRegistry() public {
        address treasury = address(new ForkBucket(address(1), 0)); // any contract
        GenesisSplitter splitter = new GenesisSplitter(REGISTRY, treasury);
        ForkToken token = new ForkToken(PROJECT_FACTORY);
        address bucketA = address(new ForkBucket(address(token), 250_000_000e18));
        address bucketD = address(new ForkBucket(address(token), 100_000_000e18));

        ILaunchRegistry.Artifact[] memory a = new ILaunchRegistry.Artifact[](4);
        a[0] = ILaunchRegistry.Artifact("token", "TOKEN", address(token));
        a[1] = ILaunchRegistry.Artifact("distributor", "MerkleDistributor", address(0xD157));
        a[2] = ILaunchRegistry.Artifact("other", "BucketA", bucketA);
        a[3] = ILaunchRegistry.Artifact("other", "BucketD", bucketD);
        ILaunchRegistry.Launch memory l;
        (l.kind, l.launchNumber, l.sourceRepoUrl) = ("custom_token", LAUNCH, "https://github.com/example/token");
        vm.startPrank(PROJECT_FACTORY);
        IRegistryWriter(REGISTRY).record(l, a, new uint256[](0));
        token.transfer(address(splitter), 700_000_000e18);
        vm.stopPrank();

        splitter.split(LAUNCH);
        assertEq(token.balanceOf(bucketA), 250_000_000e18);
        assertEq(token.balanceOf(bucketD), 100_000_000e18);
        assertEq(token.balanceOf(treasury), 350_000_000e18);
    }
}
