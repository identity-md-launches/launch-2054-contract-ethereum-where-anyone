# Security review notes

This is the implementation author's review and test record, not an independent audit. Review `WebsiteBuyer`, `IntakeAccount`, the JSON validator and selected production dependencies together before release.

## Value and authority

- Only a purchase transfers hub ETH. It sends exactly this transaction's `msg.value` to the native pool or wrapper, never accumulated ETH. Price is bounded before its signed swap conversion.
- Swap input delta must equal the entire payment, output delta must be positive, settlement must equal input, and the actual IMD balance increase must equal output. Previous IMD surplus cannot satisfy the fresh-output minimum.
- Funding the user account checks actual receipt. The account checks the Intake's exact net spend and clears its exact allowance. Hub balance must drop by precisely the live Intake price. This rejects ordinary transfer-tax and nonconforming token behavior; the configured token itself remains trusted.
- Purchases, configuration changes, account asks and account execution are guarded against reentrancy. The v4 callback is intentionally callable inside a purchase, but authenticates the manager, committed callback data and a single-use phase. The phase is consumed before a hook can run.
- Accounts have an immutable user and hub. Only the user executes arbitrary calls. The hub can fund and submit requests only as a consequence of that same user's purchase. The launch owner cannot impersonate an account's user.
- No owner withdrawal or arbitrary-call function exists on the hub. All administration is explicit, emits events and increments the version checked by a purchase. Ownership transfer is two-step. Renunciation remains possible and removes recovery of administrative settings.

## Callback integrity

Requests are stored under the exact Intake address and raw request ID. The callback sender selects the Intake namespace and must find a pending record there. Unknown IDs, forged senders, repeated results, repeated failures and result/failure crossovers are rejected. Different Intakes may safely return the same raw ID. Reuse within one Intake reverts the entire new purchase.

Callbacks only record and emit. They do not pay, refund, unlock a queue or decide project ownership. A missing callback cannot block new business. A URI longer than 192 bytes still settles the request and stores `resultHash`, but the URI is emitted in full rather than stored, never stored partially. Maximum-length stored URIs and a 4096-byte emitted URI are tested under the real 200,000 gas call cap, with cold recipient state.

## Reviewed external assumptions

The owner must verify the actual manager, pool key, hook, wrapper, IMD and Intake. An owner-selected malicious manager or token can forge values reported through its own ABI, and an upgraded external proxy can change behavior without a hub configuration change. These are trusted dependencies, not permissionless user inputs.

The 0.5 IMD minimum guarantees enough IMD to submit work, not a fair market price. The buyer has no stake in the retained surplus, so the owner-settable `imdFloor`, not the buyer's own `minImdOut`, bounds what a sandwich can take from it. That floor is only as good as the owner's upkeep, and there is no on-chain oracle. A sandwich on a real 0.05% pool that profited without the floor is tested to revert with it. The payer-based continuation rule and result writer's honesty are properties of IdentityMD outside this contract. Tests model those rules from the supplied reference.

The contract enforces JSON string safety of the caller's words and fills every `Caller` slot from `msg.sender` only. Template parts are trusted owner JSON and are not parsed; their size and slot count are bounded below Intake's body limit. The contract cannot verify that a skill exists, that a key such as `owner` is admitted on `job.open`, that a new action still accepts a template's schema, or that a description will pass admission. Those require live preflight by the operator and client. Descriptions remain public permanently.

## Verification scope

The delivered Foundry suite exercises unit success/failure paths, fuzzed conservation and JSON construction, actual Uniswap v4 native/WETH settlement in both currency orders, a hook that dirties synced reserves, writer callback gas, and empty-chain factory deployment/runtime restrictions. All tests are deterministic and require no network or environment configuration.

No funded transaction, mainnet fork, live paid request, independent audit, Slither run or Mythril run is claimed. Mainnet liquidity, pool-specific hook semantics, protocol hosting availability, real request-checker admission and external upgrades require operational verification. Test helper contracts and the locally deployed PoolManager are fixtures, not launch applications.
