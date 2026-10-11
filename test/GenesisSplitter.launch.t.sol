// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {GenesisSplitter} from "src/GenesisSplitter.sol";

contract GenesisSplitterLaunchTest is Test {
    address constant REGISTRY = 0x7c9D5ee697BfF5Ac4F10E2E54d3f40c44e48fE23;
    address constant TREASURY = 0x6Ac8fF96Fb8DCF5d79A8eF1E59D9AC23f2BD27Bc;

    function test_factoryDeploysWithStaticMainnetArgumentsOnEmptyChain() public {
        vm.etch(REGISTRY, "");
        vm.etch(TREASURY, "");
        vm.prank(makeAddr("deployment factory"));
        GenesisSplitter splitter = new GenesisSplitter(REGISTRY, TREASURY);
        assertEq(address(splitter.registry()), REGISTRY);
        assertEq(splitter.treasury(), TREASURY);
        bytes memory runtime = address(splitter).code;
        assertGt(runtime.length, 0);
        assertLe(runtime.length, 24_576);
        assertLe(type(GenesisSplitter).creationCode.length + 64, 49_152);
        for (uint256 i; i < runtime.length; ++i) {
            uint8 op = uint8(runtime[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff, "forbidden runtime opcode");
        }
    }

    function test_zeroTreasuryIsRefusedWithoutCallingRegistry() public {
        vm.etch(REGISTRY, "");
        vm.expectRevert(GenesisSplitter.ZeroAddress.selector);
        new GenesisSplitter(REGISTRY, address(0));
    }
}
