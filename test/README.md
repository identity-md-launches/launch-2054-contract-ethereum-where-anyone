# WebsiteBuyer tests

Run from the repository root with the vendored dependencies:

```sh
forge build
FOUNDRY_FUZZ_SEED=0xe06e1e69b569feaaad0ec0b21e39fcc2e3671591fa8e515b832ff0a024fb5449 forge test
```

No fork, network, FFI, environment mutation, or files under `test/scratch/` are required by the tests. Local build artifacts can be directed to scratch with `--out test/scratch/out --cache-path test/scratch/cache`.

The original deployment, purchase, and Uniswap integration tests remain in place. The additional suites cover:

| File | Properties exercised |
| --- | --- |
| `WebsiteBuyerEdges.t.sol` | Exact purchase event, smart-wallet caller identity, one-wei and signed-int128 boundaries, independent output/price/slippage constraints, configuration races, dependency code checks, wrapper and settlement faults, preservation of preexisting balances, and invalid failure statuses. |
| `IntakeAccountAdversarial.t.sol` | Exact allowance and payment, underpulls, overpulls, refunds, zero-first approvals, cleanup failure, permission separation, execution revert propagation, and a zero request ID rolling back the entire purchase. |
| `JsonTextProperties.t.sol` | JSON parser round trips for generated Unicode scalars, all ASCII bytes, malformed UTF-8, continuation corruption, and byte-length boundaries. |
| `WebsiteBuyerInvariant.t.sol` | Stateful accounting, request lifecycle, configuration, and payer isolation through the handler below. |
| `UniswapV4Integration.t.sol` | Additional changing-price conservation and wrapped-native rollback tests against the actual vendored PoolManager. |

The invariant campaign runs 256 sequences of depth 64, with unexpected handler reverts treated as failures. Only the selected handler functions are targeted, so unrestricted mock setters cannot mutate the scenario behind the accounting model. Four users start with successful purchases; both terminal states and pending requests are seeded to prevent vacuous lifecycle checks. A deterministic test exercises migrations, all seven rejected-purchase modes, and withdrawal recovery explicitly.

Random actions include successful and rejected purchases; native/wrapped routing; token, Intake, action, template, price and pause changes; callbacks and forgeries; donations; and user-account withdrawals. Two tokens and two Intakes preserve old balances and request authority across migrations. Ghost accounting derives amounts from operation inputs, rather than copying balances from the implementation:

- Hub tokens equal accumulated swap output minus paid prices plus hub donations, separately for each token.
- Pool output, treasury receipts, user payments, wrapped backing, and forced ETH match their independent totals.
- Account balances equal deposits minus authorized withdrawals; purchases leave no extra payer balance or Intake allowance.
- Every successful purchase has exactly one immutable user, asset, amount and body commitment. Only an authenticated pending request can become done or failed; terminal data remains unchanged.
- Configuration versions and fields change only through modeled owner calls. Each user's deterministic payer stays distinct and under that user's authority.

The model uses ordinary 18-decimal tokens and the existing protocol-shaped Intake mock. Deliberately faulty dependencies are isolated in failure tests. JSON parsing checks syntax and field preservation; it does not prove live Intake admission, hosting, liquidity, or writer behavior. Existing real-PoolManager tests provide local settlement integration without an RPC dependency.
