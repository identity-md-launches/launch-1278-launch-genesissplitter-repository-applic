// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @dev The read side of the plane's `LaunchRegistry` (packages/contracts/src/LaunchRegistry.sol). Only the
/// factory that owns the registry can write it, so a launch's artifacts are what that launch deployed.
interface ILaunchRegistry {
    struct Artifact {
        bytes32 role; // "token", "distributor", "other", "hook"
        bytes32 name;
        address addr;
    }

    struct Launch {
        bytes32 kind;
        uint64 launchNumber;
        uint64 recordedAt;
        bytes32 sourceCommit;
        bytes32 manifestHash;
        bytes32 attestationHash;
        bytes32 verifierKey;
        string sourceRepoUrl;
    }

    function launchOf(uint64 launchNumber) external view returns (Launch memory);
    function artifactsOf(uint64 launchNumber) external view returns (Artifact[] memory);
}

/// @title GenesisSplitter
/// @notice Receives a token launch's remainder and pays it to that launch's own contracts, in the amounts
/// written into those contracts. Takes no instructions from anyone.
///
/// Why it exists: a custom-token launch sends everything the pool and the swarm leave to ONE address
/// (`remainderTo`), fixed in the request before the launch's own contracts have addresses. So this contract is
/// deployed first and finds out where the tokens go from the launch's on-chain record.
///
/// `split(launchNumber)`, callable by anyone, once per token:
///   1. reads the launch's artifacts from the factory's `LaunchRegistry`; the launch must be a custom-token
///      launch and its `token` artifact must be held here;
///   2. pays every `other` artifact of THAT launch that declares `genesisAllocation()` — a constant the swarm
///      writes into the bucket — and serves that token (`token()`);
///   3. sends whatever is left to the Treasury.
/// Nobody configures anything, so there is no key to trust, no deadline and nothing to cancel. The amounts are
/// public in the launch's verified source. Anyone may run a launch with this contract as `remainderTo`; it then
/// splits only that launch's own token, so it cannot touch another's.
/// Use only for custom-token remainders, after rehearsing the launch and its declarations. Token transfer
/// rules must permit exact payments from this address to every bucket and the Treasury. Unsplit tokens
/// cannot be swept; missing or malformed allocation getters declare nothing.
///
/// The constructor reads no other contract: the launch that deploys this rehearses constructors on a bare
/// chain, where neither the registry nor the Treasury has code.
contract GenesisSplitter is ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 private constant CUSTOM_TOKEN = "custom_token";
    bytes32 private constant ROLE_TOKEN = "token";
    bytes32 private constant ROLE_OTHER = "other";

    ILaunchRegistry public immutable registry;
    address public immutable treasury;
    mapping(address token => bool) public isSplit;

    event Paid(address indexed token, address indexed bucket, bytes32 name, uint256 amount);
    event Split(uint64 indexed launchNumber, address indexed token, uint256 toBuckets, uint256 toTreasury);
    event Swept(address indexed token, uint256 amount);

    error ZeroAddress();
    error NotCustomTokenLaunch(uint64 launchNumber);
    error NoToken(uint64 launchNumber);
    error AlreadySplit(address token);
    error NothingHeld(address token);
    error WrongToken(address bucket);
    error OverAllocated(uint256 allocated, uint256 held);
    error NotSplit(address token);

    /// @param registry_ The chain's `ProjectFactory.registry()`.
    /// @param treasury_ The protocol Treasury: receives what no bucket declares and later deposits of split tokens.
    constructor(address registry_, address treasury_) {
        if (registry_ == address(0) || treasury_ == address(0)) revert ZeroAddress();
        registry = ILaunchRegistry(registry_);
        treasury = treasury_;
    }

    /// @notice Pay `launchNumber`'s remainder out to its own contracts. Anyone, once per token.
    function split(uint64 launchNumber) external nonReentrant {
        if (registry.launchOf(launchNumber).kind != CUSTOM_TOKEN) revert NotCustomTokenLaunch(launchNumber);
        ILaunchRegistry.Artifact[] memory artifacts = registry.artifactsOf(launchNumber);

        address token;
        for (uint256 i; i < artifacts.length; ++i) {
            if (artifacts[i].role == ROLE_TOKEN) {
                token = artifacts[i].addr;
                break;
            }
        }
        if (token == address(0)) revert NoToken(launchNumber);
        if (isSplit[token]) revert AlreadySplit(token);
        uint256 held = IERC20(token).balanceOf(address(this));
        if (held == 0) revert NothingHeld(token);
        isSplit[token] = true;

        uint256 paid;
        for (uint256 i; i < artifacts.length; ++i) {
            if (artifacts[i].role != ROLE_OTHER) continue;
            address bucket = artifacts[i].addr;
            uint256 amount = _declared(bucket);
            if (amount == 0) continue; // not a bucket (e.g. a staking vault)
            if (_servedToken(bucket) != token) revert WrongToken(bucket);
            paid += amount;
            if (paid > held) revert OverAllocated(paid, held);
            IERC20(token).safeTransfer(bucket, amount);
            emit Paid(token, bucket, artifacts[i].name, amount);
        }
        uint256 rest = held - paid;
        if (rest != 0) IERC20(token).safeTransfer(treasury, rest);
        emit Split(launchNumber, token, paid, rest);
    }

    /// @notice After a token has been split, anything of it that arrives later goes to the Treasury.
    function sweep(address token) external nonReentrant {
        if (!isSplit[token]) revert NotSplit(token);
        uint256 amount = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransfer(treasury, amount);
        emit Swept(token, amount);
    }

    function _declared(address bucket) private view returns (uint256) {
        (bool ok, bytes memory ret) = bucket.staticcall(abi.encodeWithSignature("genesisAllocation()"));
        return ok && ret.length == 32 ? abi.decode(ret, (uint256)) : 0;
    }

    function _servedToken(address bucket) private view returns (address) {
        (bool ok, bytes memory ret) = bucket.staticcall(abi.encodeWithSignature("token()"));
        return ok && ret.length == 32 ? abi.decode(ret, (address)) : address(0);
    }
}
