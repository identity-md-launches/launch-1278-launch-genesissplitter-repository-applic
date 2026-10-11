# genesis-splitter

`GenesisSplitter` receives a custom-token launch's remainder (`remainderTo`) and pays it to that launch's own
contracts. Each contract declares its amount as `genesisAllocation()`; the splitter reads which contracts belong
to the launch from the launch factory's on-chain `LaunchRegistry`, pays each its declared amount, and sends the
rest to a fixed treasury address. It has no owner and takes no instructions.

Constructor: `(address registry, address treasury)`.

```
forge build
forge test                                  # unit tests
forge test --fork-url <mainnet RPC>         # also runs against the live LaunchRegistry
```

This deployment is an Ethereum mainnet `evm_contracts` launch of **GenesisSplitter only**, with these static
constructor arguments, in order:

1. LaunchRegistry: `0x7c9d5ee697bff5ac4f10e2e54d3f40c44e48fe23`
2. Treasury: `0x6ac8ff96fb8dcf5d79a8ef1e59d9ac23f2bd27bc`

The constructor is nonpayable and does not call either address or require code there. No token, pool or reward
distributor is deployed with the splitter. There is no owner, administration, configuration or upgrade path.
The scripts and test helper contracts are development utilities, outside this deployment's contract set.

Use as `remainderTo` only for a **custom_token** launch. An `evm_project` remainder, an unrelated ERC20, or a
custom-token remainder whose split cannot succeed has no recovery path. `sweep` deliberately requires a
completed split: allowing it beforehand would let anyone send the buckets' allocation to the treasury.
Later deposits of an already split token can be swept permissionlessly to the same treasury.

Before a future custom-token launch uses this address, review its complete `other` artifact inventory and
rehearse the entire candidate launch on a disposable mainnet fork: deploy the exact candidate bytecode with
its actual constructor arguments, seed the remainder and write the registry record using the factory's launch
flow. Token transfer rules must exempt the splitter's payments, including every bucket and treasury recipient,
so each receives exactly the declared amount; sender burns, recipient taxes, transfer limits, wallet limits or
blocking rules that affect these transfers are incompatible. A successful ERC20 transfer alone is insufficient.

`script/GenesisPreflight.s.sol` checks that simulated state and performs `split` locally, verifying exact bucket
and treasury balance changes. Supply the reviewed list of **all intended buckets**, including any whose getter
might fail, rather than discovering buckets from successful getter calls. Each expected bucket must be an
`other` artifact and return one non-reverting uint256 from `genesisAllocation()` and one clean matching address
from `token()`. Reviewed non-buckets may omit the allocation getter or declare zero. Missing, reverting or
malformed getters on an expected bucket fail preflight; a nonzero declaration outside the inventory also fails.
The total allocation must fit the held remainder.

Set `GENESIS_SPLITTER` to the deployed splitter address in that simulation, `GENESIS_LAUNCH_NUMBER` to the
candidate's recorded launch number, `GENESIS_BUCKETS` to comma-separated bucket addresses (an empty string
for a reviewed launch with no buckets), and `GENESIS_SIMULATION_RPC` to the disposable fork's RPC URL. Then run:

```sh
forge script script/GenesisPreflight.s.sol:GenesisPreflightScript --rpc-url "$GENESIS_SIMULATION_RPC"
```

The utility never broadcasts and needs no wallet key. Its state changes exist only in Forge's simulation; do
not use `--broadcast`. A fork that contains only the splitter but not the candidate launch cannot preflight a
future launch. Run this check after the adapter's complete launch simulation and refuse that candidate on any
failure. This repository does not control other launch adapters: the permissionless contract cannot enforce
that their operators performed preflight, and it retains its original refusal/skip behavior for invalid inputs.
Changing candidate bytecode, constructor arguments, declaration inventory or transfer rules requires repeating
the rehearsal. Source review is still needed for mutable or future-dependent rules a single simulation cannot
prove safe.
