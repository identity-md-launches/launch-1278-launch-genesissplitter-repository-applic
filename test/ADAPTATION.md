# GenesisSplitter test additions

Only test files are added. The arriving source, constructors, external interface, recipients,
configuration, dependencies, and existing tests are unchanged. The original application adaptations
remain documented in the repository's root `ADAPTATION.md`.

`GenesisSplitter.properties.t.sol` adds independent unit and property coverage for empty artifacts,
zero token addresses, unrecorded launches, registry and balance read failures, payment events,
late deposits, and per-token replay protection across two launch numbers. Failure tests check retained
custody, rolled-back prior bucket payments, unchanged completion, refused pre-split sweeps, and retries.
ERC20 fixtures exercise a second transfer that changes balances before returning false, treasury
reverts, no-return transfers, and failed post-split sweeps. Known arithmetic edges are pinned as
unit tests: zero declarations, one wei, exact full allocation, maximum supply, and allocation-sum
overflow. Two properties run 1,000 cases each over the full uint256 input domain, testing exact
conservation and allocation exceeding custody by one wei.

`GenesisSplitter.invariant.t.sol` supplies a bounded handler with three independently funded actors,
four custom-token launches, alias launch records, and a fifth unregistered token. Initial custody
includes unfunded, underfunded, exactly funded, and one-wei states. Seven randomized actions donate,
donate dust, top up, change fixture transfer rejection, split, sweep, and try unknown launches.
All configuration changes affect test fixtures, never the splitter. The registry and token contracts
cannot be called directly by the invariant runner; explicit target selectors restrict it to the handler.
Forge's outer callers are also restricted to the three actors, avoiding unbounded remote account reads
on a fork; each protocol action independently selects its acting caller from those same actors.

The inline campaign settings are 256 runs, depth 128, and fail-on-revert enabled. Expected protocol
reverts are caught inside the handler and compared against independently tracked funding, completion,
and transfer preconditions. Unexpected outcomes or harness assertion failures fail the campaign.
A deterministic handler test reaches underfunding, second-payment refusal, retry, alias replay,
failed sweep, late deposit, repeated empty sweep, and unrelated-token refusal on every ordinary run.

The two always-on invariants are grounded in the requested behavior:

- Exact payments and completion: every declared bucket receives its allocation once after a successful
  split; until then it receives nothing. Treasury receipts equal successful split remainders plus
  subsequent sweeps. Custody equals independently tracked deposits less those payments. Rejected calls
  preserve that accounting, completion never reopens, aliases cannot split twice, and other artifact
  roles never receive a bucket payment.
- Conservation and caller isolation: fixed minted supply equals all actor and permitted-recipient
  balances. Each caller's balance equals its initial budget less its own tracked deposits; calling
  split or sweep cannot extract value. Every token is checked after each sequence step, including the
  unregistered one, so calls involving one launch cannot disturb another's custody.

These properties cover exact-transfer ERC20s and transfer refusals. They do not certify arbitrary
rebasing, taxed, or dishonest tokens, future launch inventories, or a future bucket's mutable getters.
The arriving source and preflight tests already document and reproduce incompatible transfer rules
and malformed getters; those accepted limitations have not been asserted away or altered here.
No additional source defect requiring a change was found in the new tests.

Run locally with `forge build` and `forge test`. The existing fork suite also runs with
`forge test --fork-url <mainnet RPC>` and exercises the real LaunchRegistry on disposable state;
the new fixtures remain local to their tests and require no network or additional dependencies.

## Verification

- `forge build`: passes; only existing advisory source lint warnings remain.
- `forge test`: 63 passing tests, zero failures, and the expected offline fork-suite skip.
- Full mainnet fork at block 26,166,603: 64 passing tests, zero failures, zero skips, with both
  1,000-case properties and the complete 256-by-128 invariant campaign enabled.
  Command: `forge test --fork-url http://127.0.0.1:18547 --fork-block-number 26166603 --rpc-timeout 180 --threads 1`.
  A scratch-only relay cached and throttled genuine responses from `https://eth-pokt.nodies.app`
  after direct public RPC attempts hit HTTP 504/429 transport errors. It fabricated no chain state
  and is not a submitted dependency. Bounding the invariant runner's outer callers to the three
  actors also prevents a fresh remote account lookup for every randomized step.
