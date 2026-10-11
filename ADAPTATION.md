# GenesisSplitter launch adaptation

The application deployment contains only `GenesisSplitter` on Ethereum mainnet. Its unchanged nonpayable
constructor takes `(address registry, address treasury)`, with static arguments
`0x7c9d5ee697bff5ac4f10e2e54d3f40c44e48fe23` and
`0x6ac8ff96fb8dcf5d79a8ef1e59d9ac23f2bd27bc`, respectively. It makes no external calls and accepts addresses
without code. The existing configuration already specifies Solidity 0.8.26, Cancun and `bytecode_hash = "none"`.
No build configuration or dependencies changed; no manifest, launch token, pool or reward distributor was added.

## Changes and their evidence

- `src/GenesisSplitter.sol`: inherit the already vendored OpenZeppelin `ReentrancyGuard` and apply its shared
  `nonReentrant` modifier to the existing `split` and `sweep` entry points. Finding a68dc65b's transfer-hook edge
  reproduced before this change: a hook called `sweep` after the first bucket payment, moved the remaining
  balance to the treasury, and made the next bucket transfer revert with `ERC20InsufficientBalance(splitter,
  0, 100)`. The same regression now completes the original payments and rejects the nested call. Additional
  tests cover nested split and nested sweep. This is the only runtime behavior change: nested entry is refused.
  The external functions, recipients, amounts, once-per-token rule and ordinary sweep behavior are unchanged;
  the guard adds no owner, setter, pause, configuration, upgrade or external function. Its constructor only
  writes local storage.
- `src/GenesisSplitter.sol` documentation and `README.md`: correct the overly broad promise of recovering
  "stray tokens", explicitly restrict remainder use to custom-token launches, and document required transfer
  exemptions and getter shapes. Findings 9689055f and a398c625 required these clarifications. Constructor
  documentation now accurately limits later recovery to tokens already split. README records the application's
  exact deployment arguments and preflight procedure.
- `script/GenesisPreflight.s.sol`: add a simulation-only adapter utility, selecting the behavior-preserving
  pre-launch validation alternatives from findings c091e431, 9689055f, a398c625 and 7f57e8c3. It validates a
  complete, independently reviewed bucket inventory against the simulated registry, requires clean getters
  for those buckets, rejects unsupported launch kinds and over-allocation, executes the existing `split`, and
  checks actual receipt of each declared amount and treasury remainder. It catches both sender burns that
  revert and recipient taxes that otherwise succeed while underpaying. There is no broadcasting or key access.
  Its library functions are internal, and the script is not an application to deploy. Checks must be integrated
  into the consuming adapter's complete future-launch simulation; they do not add an on-chain recovery path.
- `test/GenesisSplitter.audit.t.sol`: retain regression reproductions for the imported custody, malformed
  getters and transfer-rule edges, plus reentrancy regressions and the no-`other` all-to-treasury case.
- `test/GenesisPreflight.t.sol`: test the adapter utility's successful exact payments and non-bucket handling,
  each reproduced invalid bucket/token case, unsupported or unrecorded launches, sender and recipient taxes,
  transfer limits, incomplete/duplicate inventory, and allocation conservation with the configured 512 fuzz runs.
- `test/GenesisSplitter.launch.t.sol`: rehearse factory-context deployment with the supplied addresses after
  removing their code in test state, test zero-treasury rejection, and check init/runtime size and runtime
  forbidden opcodes as the protected floor does. These tests demonstrate the constructor still works on an
  empty chain after adding the guard.

## Imported audit disposition

All five reports were reviewed against the arriving source and tests. Their concrete custody/getter/token
examples reproduced; they are addressed within the brief's constraint against changing split payments.

| Finding | Reproduction and disposition |
| --- | --- |
| c091e431 (wrong-token stranding) | A foreign token getter yields `WrongToken` on repeated attempts; missing token getter also fails, and a dirty address word reverts. Prior bucket payments and `isSplit` roll back; sweep remains refused. Preserve this behavior and reject these candidates with preflight, rather than skip their shares or add recovery powers. |
| 9689055f (unsupported and stray tokens) | An `evm_project` remainder cannot split or sweep; an unregistered ERC20 cannot sweep. Correct documentation and reject unsupported candidates before selecting this remainder recipient. Unsplit recovery would enable bucket front-running and is deliberately not added. |
| a398c625 (transfer rules) | Sender-side burn makes the final treasury payment revert atomically. Recipient-side tax can instead succeed and underpay. Document exact-transfer exemptions and require preflight balance checks. Adjusting payment amounts would violate the brief. |
| 7f57e8c3 (bad allocation getter) | A reverting getter or two-word answer is treated as no declaration; the treasury receives that share and the token is marked split. Preserve that contract behavior and require an explicit reviewed bucket inventory in preflight so failed getters cannot disappear from checks. |
| a68dc65b (missing tests) | Add the above tests, the no-bucket case, conservation fuzzing and transfer-hook regression/fix. The arriving suite already had a stranger's wrong-token regression, so the report's broad suggestion that no mismatch was tested was overstated; it lacked the own-launch stranding/recovery and malformed-getter coverage now supplied. |

There is no requester-specific bucket launch to validate in this contracts-only assignment. The new utility
is supplied for later custom-token launches using the deployed splitter. It cannot certify arbitrary future
launches or tokens, and does not make unsupported deposits recoverable. No change routes an invalid bucket's
share elsewhere or pays a new recipient. Mainnet treasury withdrawals and its controller are outside this
contract's authority and were not changed or assumed.

## Verification

- Original `forge test`: 9 passing unit tests, fork suite skipped without a mainnet fork.
- Before the guard: 10 new reproduction tests passed and the intended hook regression failed with the
  reproduced insufficient-balance error. After the guard, it passes.
- Final `forge build` passes. `forge test` passes 42 tests, with the mainnet fork suite skipped without a fork;
  the conservation fuzz test runs 512 cases. Forge emits advisory lint warnings on the original loop/default
  initialization patterns; there are no compilation errors.
- A temporary scratch-only smoke test exercises the script's environment entry point with both a bucket
  inventory and an empty inventory; both pass when run serially because environment variables are process-wide.
  Submitted tests do not set environment variables and pass in parallel.
- The existing mainnet registry fork test is retained. It impersonates the factory on disposable fork state
  and writes a synthetic candidate to the real registry, proving ABI compatibility and actual registry/split
  interactions, rather than payments for an existing live launch. A separate live read confirmed launch 1274's
  recorded kind is `custom_token`; its real payouts were not asserted.
- Full mainnet fork verification passes **43 tests, zero failures and zero skips** at block 26,166,603:
  `forge test --fork-url http://127.0.0.1:18545 --fork-block-number 26166603 --rpc-timeout 240 --threads 1`.
  The scratch-only relay forwarded and cached real JSON-RPC responses from `https://eth-pokt.nodies.app`,
  serializing requests to respect its public rate limit; it supplied no fabricated chain state. Initial direct
  attempts failed on RPC 403/504/429 responses, and a parallel relay attempt timed out some account reads.
  Running serially with the longer RPC timeout resolved those transport failures. Neither the relay nor its
  cache is a project dependency or part of the submission.
- Review and Foundry tests/fuzzing were used. Slither and Mythril were not run.
