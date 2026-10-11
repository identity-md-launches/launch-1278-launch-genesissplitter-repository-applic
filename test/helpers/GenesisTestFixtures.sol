// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ILaunchRegistry} from "src/GenesisSplitter.sol";

/// @dev Test fixtures only. No fixture is part of the application deployment.
contract SequenceRegistry is ILaunchRegistry {
    mapping(uint64 => Launch) private launches;
    mapping(uint64 => Artifact[]) private artifacts;

    function record(uint64 number, bytes32 kind, Artifact[] memory entries) external {
        launches[number].kind = kind;
        launches[number].launchNumber = number;
        delete artifacts[number];
        for (uint256 i; i < entries.length; ++i) {
            artifacts[number].push(entries[i]);
        }
    }

    function launchOf(uint64 number) external view returns (Launch memory) {
        return launches[number];
    }

    function artifactsOf(uint64 number) external view returns (Artifact[] memory) {
        return artifacts[number];
    }
}

contract SequenceBucket {
    address public immutable token;
    uint256 public immutable genesisAllocation;

    constructor(address token_, uint256 allocation_) {
        token = token_;
        genesisAllocation = allocation_;
    }
}

contract SequenceToken is ERC20 {
    address public rejectedRecipient;
    error TransferRejected(address recipient);

    constructor(address holder, uint256 supply) ERC20("Sequence token", "SEQ") {
        _mint(holder, supply);
    }

    function rejectRecipient(address recipient) external {
        rejectedRecipient = recipient;
    }

    function _update(address from, address to, uint256 amount) internal override {
        if (to != address(0) && to == rejectedRecipient) revert TransferRejected(to);
        super._update(from, to, amount);
    }
}

/// @dev Can move balances and then return false: SafeERC20 must roll those changes back.
contract FalseReturnToken is SequenceToken {
    address public falseRecipient;

    constructor(address holder, uint256 supply) SequenceToken(holder, supply) {}

    function returnFalseTo(address recipient) external {
        falseRecipient = recipient;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        super.transfer(to, amount);
        return to != falseRecipient;
    }
}

contract NoReturnToken is SequenceToken {
    constructor(address holder, uint256 supply) SequenceToken(holder, supply) {}

    function transfer(address to, uint256 amount) public override returns (bool) {
        super.transfer(to, amount);
        assembly ("memory-safe") {
            return(0, 0)
        }
    }
}
