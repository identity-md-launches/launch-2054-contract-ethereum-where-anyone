# WebsiteBuyer

`WebsiteBuyer` sells a hosted one-page website for **0.003 ETH** initially. The caller supplies a short description. The contract swaps the entire payment through a configured Uniswap v4 pool, buys `job.open@job-1` from IdentityMD Intake v2, and records the asynchronous result hash and URI.

## Purchase and ownership

1. Read `ethPrice`, `configurationVersion`, the selected template, the configured pool, and `intake.priceOf(action, imd)`.
2. Preview `bodyOf(templateId, caller, words)` and validate the exact body through IdentityMD's request checker before paying.
3. Obtain an independent quote for the configured pool. Submit `buyWebsite(words, purchase)` with **exactly** `ethPrice` wei, a short deadline, a suitable minimum IMD output, the maximum acceptable Intake price, and the configuration version you reviewed.
4. The full ETH payment is swapped. Fresh output must be at least the greatest of the owner's floor `imdFloor` (initially, and never below, **0.5 IMD**), the live Intake price, and the caller's minimum. Existing surplus cannot subsidize a deficient swap. Partial fills revert.
5. Exactly the live Intake price is sent to a deterministic `IntakeAccount` for the caller. That account approves only the payment, calls `requestWithFailure`, and clears the allowance. The Intake forwards payment to its treasury immediately. Excess IMD stays in `WebsiteBuyer`.
6. `WebsiteRequested` identifies the raw Intake request ID, user, originating Intake, payer account, template, body hash, ETH paid, IMD bought and IMD paid. Track results by **(originating Intake, request ID)**.

A template is the owner's JSON with gaps, as in the protocol's reference hub: `parts[0] ++ fill(slots[0]) ++ parts[1] ++ … ++ parts[n]`. A `Words` slot is filled with the caller's description and a `Caller` slot with the transaction caller in lowercase hex. Every template has exactly one `Words` slot and any number of `Caller` slots, up to 8 slots and 8192 bytes of parts. The parts are not parsed on chain, so the owner can add, drop or rename keys without a redeploy. The default template `0` is:

```json
{"objective":"Build a one-page website: <words>","skill":"build-website","host":true,"owner":"<transaction caller in lowercase hex>"}
```

That is the supplied body template with the caller's `owner` added, because the brief asks for the owner to be passed. Whether the plane admits `owner` on `job.open` could not be checked (see the assumptions below). If the checker refuses it, the owner switches to the brief's and the reference's exact body with one call. The owner key is gone, and every purchase still runs through the caller's own payer account:

```solidity
bytes[] memory parts = new bytes[](2);
parts[0] = '{"objective":"Build a one-page website: ';
parts[1] = '","skill":"build-website","host":true}';
WebsiteBuyer.Slot[] memory slots = new WebsiteBuyer.Slot[](1);
slots[0] = WebsiteBuyer.Slot.Words;
buyer.setTemplate(0, parts, slots, true);
```

The protocol reference says **project access is determined by the payer**, whereas an `owner` field selects ownership of launch contracts. An `owner` field alone would not isolate website projects. Consequently each user gets their own payer account, reused on later purchases. Its immutable `user` is the actual caller of `buyWebsite`, including smart contract wallets. There is no caller-supplied beneficiary and no use of transaction origin for authorization.

The hub can only make funded requests through an account; it cannot execute arbitrary calls as that account. Only its user can call `IntakeAccount.execute(target, value, data)`. This lets the user fund it with IMD, approve Intake, and buy `job.continue` directly as the same payer. The newest job ID comes from the result document. A continuation must satisfy Intake's completion/admission rules. The owner of `WebsiteBuyer` has no authority over users' `execute` functions.

## Calling the application

```solidity
WebsiteBuyer.Purchase memory purchase = WebsiteBuyer.Purchase({
    templateId: 0,
    minImdOut: quotedMinimum,          // 18-decimal units, based on a fresh independent quote
    maxIntakePrice: approvedIMDPrice,  // live price the user accepts
    deadline: block.timestamp + 120,
    configurationVersion: reviewedVersion
});
bytes32 requestId = buyer.buyWebsite{value: reviewedETHPrice}("a bakery in Lisbon", purchase);
```

The 120-second deadline above is an example, not a contract restriction. At exactly the deadline the request remains valid. A configuration change invalidates old purchases, even if the ETH price did not change. A newer live Intake price does not change the version; `maxIntakePrice` protects that case.

Words are 1–2000 **bytes** of valid UTF-8. Quotes, backslashes and control bytes below `0x20` are rejected, so words placed inside a JSON string cannot close it and add keys such as `owner`. Non-ASCII text is accepted if valid UTF-8. The largest possible body (8192 + 2000 + 7 × 42 bytes) is below Intake's 16 KiB limit. The owner must place every slot inside a JSON string, keep the objective under Intake's 8000-character limit, and preflight each template, because the parts are trusted owner JSON. The owner can maintain several templates by numeric ID and disable one with `enabled = false`. Clients must show the template they are buying, and `bodyOf` returns its exact bytes.

## Results and failures

`onIntakeResult(bytes32,bytes32,string)` stores `resultHash` and the URI and emits both in `WebsiteResult`. `onIntakeFailure(bytes32,uint8,bytes32,uint16,uint16,bytes)` records refusal/failure status and reason and emits `WebsiteFailed`. Read the complete record through `requestOf(sourceIntake, requestId)`.

Only the Intake that accepted that particular request can settle it. Unknown requests, duplicate callbacks and invalid failure statuses revert. Requests from different Intake deployments have separate namespaces, including when raw IDs coincide. Changing the current Intake, token, template or pause state cannot invalidate old requests' callback authority.

States are `None = 0`, `Pending = 1`, `Done = 2`, `Failed = 3`. Failure status `1` means refusal; `2` means work ended without a result. Payments are already spent in both cases. A result or failure transfers no value and is an unsigned statement from the Intake writer, not an on-chain proof of a working website. Consumers should fetch the URI and verify that its bytes hash to `resultHash`.

Intake attempts callbacks once with 200,000 gas. The stored URI is limited to **192 bytes**, so the largest stored callback fits that stipend, including cold storage. This covers ordinary IPFS result URIs (about 78 bytes). A longer URI still settles the request: the state becomes `Done` and `resultHash` is stored, but `requestOf(...).uri` is left empty and the full URI appears only in the `WebsiteResult` event. A 4096-byte URI is tested under the stipend. A lost callback leaves the record pending but never blocks further purchases or locks a user's funds. There is intentionally no owner settlement override, timeout refund or callback-triggered payment. Retrieve missed results through the protocol's documented `GET /intake/{chainId}/{transactionHash}` endpoint.

## Deployment parameters

Deploy **only `WebsiteBuyer`** as the application on Ethereum (chain ID **1**). `IntakeAccount` is a helper created by the application on a user's first successful purchase; do not list it as a separate launch application. No token, pool, proxy or hook is deployed by this project.

The nonpayable constructor has three static arguments, in this order:

| Argument | Launch value |
| --- | --- |
| `owner_` | `$owner`, resolving to `0x047f606fd5b2baa5f5c6c4ab8958e45cb6b054b7` |
| `intake_` | `0xa43e6f75ee006411f79ac1c84120606c2330de82` (supplied Ethereum Intake v2) |
| `imd_` | `0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7` (supplied Ethereum IMD) |

The constructor makes no external calls, does not require dependency code, and does not make the factory the owner. It initializes the 0.003 ETH price, the 0.5 IMD floor, the `bytes32("job.open@job-1")` action and default template `0`. The pool is deliberately **unconfigured**, not assigned a guessed fee tier, hook, pool ID or wrapper. Purchases revert `PoolNotConfigured` until configured by the owner. Nonzero dependency addresses are checked for code when used. Runtime code is below EIP-170 and needs no linked libraries. The separate launch process supplies its own manifest; none is included here.

## After launch

| Setter | What the owner sets and where to obtain it |
| --- | --- |
| `setPool(manager, input, fee, tickSpacing, hooks, hookData)` | Select a real, initialized and liquid IMD pool from verified Uniswap v4 pool records. Confirm all five `PoolKey` fields and any hook requirements. `input` is native ETH (`address(0)`, the actual v4 native-currency sentinel) or a verified WETH-compatible wrapper. The IMD side and currency sort order are derived. Use the fee, spacing and hook address of that existing pool, with the hook's required data. A zero hook means that the chosen pool actually has no hook. The brief did not supply this pool, so it must be selected before enabling sales. |
| `setIntake(next)` | Initially unnecessary; the constructor takes the supplied v2 address. Use the protocol's verified Ethereum deployment for migrations and check `priceOf`. Old requests remain bound to the old Intake. |
| `setIMD(next)` | Initially unnecessary; the constructor takes the supplied IMD. Verify the replacement token through protocol deployment records. Only ordinary **18-decimal** tokens are supported. Changing it disables the pool until `setPool` is called again. |
| `setIMDFloor(floor)` | Initially `500000000000000000` (0.5 IMD), the minimum the brief requires. After `setPool`, quote `ethPrice` wei on the chosen pool and set the floor to that quote less the slippage you tolerate, for example 95%. Re-set it after `setETHPrice`, `setPool` or `setIMD` and whenever the IMD price moves. Too high and purchases revert harmlessly with `InsufficientOutput`. Too low and a sandwich can take the surplus down to the floor. Cannot be set below 0.5 IMD. |
| `setETHPrice(price)` | Initially `3000000000000000` wei. Adjust the sale price as liquidity, IMD price and Intake costs change. Must be nonzero and no larger than signed int128 maximum. |
| `setAction(next)` | Initially right-padded UTF-8 `job.open@job-1`, **not** a keccak hash. Obtain future job action IDs from Intake's protocol documentation. If the body schema changes with it, pause, call `setAction` and `setTemplate`, then unpause. |
| `setTemplate(id, parts, slots, enabled)` | Owner JSON parts around exactly one `Words` slot and optional `Caller` slots (see above). Keep `"skill":"build-website"` and `"host":true` for hosted websites. Send `bodyOf(id, sampleCaller, sampleWords)` to the Intake's `POST /requests/check` as `{"action":"job.open","input":<body>}` before enabling, and after any change. Disable a template with `enabled = false`. |
| `setPaused(next)` | Pause new purchases during dependency problems or configuration changes. Existing callbacks and users' own account operations remain available. |
| `transferOwnership(next)` / `acceptOwnership()` | Two-step handover to an operator-controlled address. Renouncing ownership is inherited and irreversible; it also removes all configuration and pause recovery. |

Uniswap's [Ethereum deployment table](https://developers.uniswap.org/docs/protocols/v4/deployments) lists PoolManager `0x000000000004444c5dc75cB358380D2e3dE08A90`. This address is documentation, not a hard-coded application dependency. Verify its code on the launch chain and confirm the selected pool before configuring it. Swaps use Uniswap's [unlock, delta and settlement interface](https://developers.uniswap.org/docs/protocols/v4/guides/unlock-callback-and-deltas) directly; they do not require Universal Router or Permit2 approvals. Native settlement explicitly resets the synced currency, including after hooks run.

## Assumptions and operational responsibilities

- A direct native ETH/IMD or WETH/IMD pool with sufficient liquidity exists. Multi-hop routes, arbitrary input ERC-20s, fee-on-transfer tokens and rebasing assets are outside this implementation. A wrapper must implement payable `deposit()` and mint exactly one token unit per wei.
- Full ETH input must be consumed and the actual received IMD must equal the reported v4 delta. A liquidity shortage, partial fill, unsuitable hook or insufficient fresh output reverts the entire purchase. Gas remains the user's transaction cost.
- All swap surplus remains in the application, as the brief says ("extra stays in the contract"). There is **no owner sweep or withdrawal**, and surplus is not used to pay for subsequent purchases. The surplus, and any old token balance left after `setIMD`, is therefore locked permanently. Unsolicited tokens or forced ETH in the hub cannot be withdrawn either. If the requester wants the surplus usable, an owner-only sweep would have to be added before launch; that is their decision. Users can recover balances sent to their own payer accounts through `execute`.
- The owner is trusted to select legitimate protocol dependencies, suitable pools, safe hooks and valid templates. `setPool` accepts any manager, hook and hook data, and `setIntake` and `setIMD` accept any nonzero address, so a malicious owner could route new purchases to contracts it controls. Every setter increments `configurationVersion`, and a purchase quoting an older version reverts `ConfigurationChanged`, so a user is never silently redirected. Frontends must show the version, template, pool and floor they quote. A malicious dependency can lie about its own behavior. This code cannot validate a service's off-chain promises or detect a proxy upgrade that does not change its address. `renounceOwnership` is inherited and irreversible: it permanently removes pausing, re-pointing, the floor and template recovery.
- The buyer gets the same website whatever the swap returns, so the buyer's `minImdOut` cannot be relied on to protect the surplus. The owner's `imdFloor` does that: a sandwich can take at most the gap between the fair output and the floor. It has no oracle and only protects as well as the owner keeps it current. Until the owner raises it, only the 0.5 IMD minimum applies, and on a low-fee pool a sandwich can then take almost all of the surplus. Frontends should also use a tight user-approved `minImdOut` and deadline.
- Intake's writer and website workers are responsible for admission, building, hosting and result delivery. There is no service-level guarantee or refund after successful submission. Descriptions and bodies are public on chain.
- Live body preflight was **not available** during this assignment. No request-checker base URL was supplied. `POST /requests/check` and `/api/requests/check` returned HTTP 404 from `identity.md` (an unrelated site), no answer from `api.identity.md` or `plane.identity.md`, and a redirect from `www.identity.md`. The exact bodies are covered locally, but whether `job.open` admits the requested `owner` key is unverified. Before sales, the operator must send `{"action":"job.open","input":<bodyOf result>}` to the protocol's actual checker. If `owner` is refused, switch template `0` to the owner-less body shown above; no redeploy is needed. No paid live requests or broadcasts were made.
- Tests use the supplied canonical Intake v2 interface and a protocol-shaped mock, plus the real vendored Uniswap v4 core locally. They do not prove the state or behavior of a particular mainnet deployment. An independent adversarial review remains a release responsibility.

## Local verification

All Solidity dependencies are vendored as ordinary files. No network, credentials, environment lookups, submodules, package installs, FFI or filesystem cheatcode permissions are needed by the build or tests once Foundry and the pinned compiler are installed.

```sh
forge build
FOUNDRY_FUZZ_SEED=0xe06e1e69b569feaaad0ec0b21e39fcc2e3671591fa8e515b832ff0a024fb5449 forge test
forge fmt --check
```

`foundry.toml` pins Solidity **0.8.26**, Cancun, optimizer 200 runs, IR compilation and `bytecode_hash = "none"`. The tests cover real native and both ordered WETH pool swaps, hook settlement interference, and a sandwich on a real 0.05% pool stopped by the owner's floor. They also cover balances and atomic rollback, action/token/Intake migrations, deterministic account isolation, exact JSON for the default, owner-less and reshaped templates, malformed input and templates, price and slippage limits, configuration races, callbacks (including oversized URIs) and gas limits, access control, reentrancy, and factory-compatible deployment. See [SECURITY.md](SECURITY.md) for review boundaries and [DEPENDENCIES.md](DEPENDENCIES.md) for pinned sources and licenses.
