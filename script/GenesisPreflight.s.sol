// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {GenesisSplitter, ILaunchRegistry} from "src/GenesisSplitter.sol";

/// @dev Simulation utility, not an application to deploy. All library calls are internal.
library GenesisPreflight {
    /// @dev Run only in disposable fork state after simulating the candidate launch's deployment,
    /// registry record and remainder transfer. expectedBuckets is the reviewed manifest's bucket inventory;
    /// it must not be inferred from successful getter calls, which would hide reverting declarations.
    function check(GenesisSplitter splitter, uint64 launchNumber, address[] memory expectedBuckets) internal {
        ILaunchRegistry registry = splitter.registry();
        require(registry.launchOf(launchNumber).kind == bytes32("custom_token"), "custom_token only");
        ILaunchRegistry.Artifact[] memory artifacts = registry.artifactsOf(launchNumber);
        address token;
        uint256 tokenCount;
        for (uint256 i; i < artifacts.length; ++i) {
            if (artifacts[i].role == bytes32("token")) {
                token = artifacts[i].addr;
                ++tokenCount;
            }
        }
        require(tokenCount == 1 && token.code.length != 0, "one deployed token required");
        require(!splitter.isSplit(token), "already split");
        require(token != address(splitter) && token != splitter.treasury(), "overlapping token");
        uint256 held = IERC20(token).balanceOf(address(splitter));
        require(held != 0, "missing remainder");

        uint256[] memory amounts = new uint256[](expectedBuckets.length);
        uint256[] memory beforeBalances = new uint256[](expectedBuckets.length);
        bool[] memory seen = new bool[](expectedBuckets.length);
        uint256 allocated;
        for (uint256 i; i < expectedBuckets.length; ++i) {
            address bucket = expectedBuckets[i];
            require(bucket.code.length != 0, "bucket not deployed");
            require(
                bucket != address(splitter) && bucket != splitter.treasury() && bucket != token, "overlapping bucket"
            );
            for (uint256 j; j < i; ++j) {
                require(bucket != expectedBuckets[j], "duplicate expected bucket");
            }
            beforeBalances[i] = IERC20(token).balanceOf(bucket);
        }
        for (uint256 i; i < artifacts.length; ++i) {
            if (artifacts[i].role != bytes32("other")) continue;
            address bucket = artifacts[i].addr;
            uint256 index = expectedBuckets.length;
            for (uint256 j; j < expectedBuckets.length; ++j) {
                if (expectedBuckets[j] == bucket) {
                    index = j;
                    break;
                }
            }
            (bool ok, bytes memory ret) = bucket.staticcall(abi.encodeWithSignature("genesisAllocation()"));
            if (index == expectedBuckets.length) {
                // A reviewed non-bucket may have no getter or explicitly declare zero, never a share.
                require(
                    (!ok && ret.length == 0) || (ok && ret.length == 0)
                        || (ok && ret.length == 32 && abi.decode(ret, (uint256)) == 0),
                    "unreviewed allocation"
                );
                continue;
            }
            require(!seen[index], "duplicate bucket artifact");
            seen[index] = true;
            require(ok && ret.length == 32, "invalid genesisAllocation getter");
            uint256 amount = abi.decode(ret, (uint256));
            (ok, ret) = bucket.staticcall(abi.encodeWithSignature("token()"));
            require(ok && ret.length == 32, "invalid token getter");
            uint256 tokenWord = abi.decode(ret, (uint256));
            require(tokenWord == uint256(uint160(token)), "wrong or malformed token");
            amounts[index] = amount;
            allocated += amount;
        }
        for (uint256 i; i < seen.length; ++i) {
            require(seen[i], "expected bucket missing from registry");
        }
        require(allocated <= held, "overallocated");
        uint256 treasuryBefore = IERC20(token).balanceOf(splitter.treasury());

        // Execute the real entry point and verify receipt, not just transfer return values.
        // No broadcast is used: these effects exist only inside the simulation.
        splitter.split(launchNumber);
        for (uint256 i; i < expectedBuckets.length; ++i) {
            require(
                IERC20(token).balanceOf(expectedBuckets[i]) == beforeBalances[i] + amounts[i], "bucket under/overpaid"
            );
        }
        require(
            IERC20(token).balanceOf(splitter.treasury()) == treasuryBefore + held - allocated, "treasury under/overpaid"
        );
        require(IERC20(token).balanceOf(address(splitter)) == 0, "remainder not exhausted");
        require(splitter.isSplit(token), "split not recorded");
    }
}

/// @notice Read-only RPC rehearsal; never use --broadcast. This script is not in the launch contract set.
contract GenesisPreflightScript is Script {
    function run() external {
        GenesisSplitter splitter = GenesisSplitter(vm.envAddress("GENESIS_SPLITTER"));
        uint256 number = vm.envUint("GENESIS_LAUNCH_NUMBER");
        require(number <= type(uint64).max, "launch number exceeds uint64");
        // Use an empty value for a reviewed launch with no buckets.
        string memory inventory = vm.envString("GENESIS_BUCKETS");
        address[] memory buckets =
            bytes(inventory).length == 0 ? new address[](0) : vm.envAddress("GENESIS_BUCKETS", ",");
        GenesisPreflight.check(splitter, uint64(number), buckets);
    }
}
