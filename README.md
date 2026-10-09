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
