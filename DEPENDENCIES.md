# Vendored dependencies

Dependencies are ordinary Solidity source files under `lib/`; nothing is fetched at build or test time. Unneeded source files are omitted. Keep their source notices and bundled licenses.

| Directory | Upstream and pin | Usage |
| --- | --- | --- |
| `lib/openzeppelin-contracts` | [OpenZeppelin Contracts v5.0.2](https://github.com/OpenZeppelin/openzeppelin-contracts/tree/dbb6104ce834628e473d2173bbc9d47f81a9eec3), commit `dbb6104ce834628e473d2173bbc9d47f81a9eec3` | MIT; ownership, reentrancy guard, SafeERC20, strings, test ERC-20. |
| `lib/v4-core` | [Uniswap v4-core v4.0.0](https://github.com/Uniswap/v4-core/tree/e50237c43811bd9b526eff40f26772152a42daba), commit `e50237c43811bd9b526eff40f26772152a42daba` | Application uses MIT interfaces/types/math. The real PoolManager and its BUSL-1.1 implementation are used only in local tests; included MIT and BUSL licenses retain upstream terms. No PoolManager is deployed as part of this launch. |
| `lib/solmate` | [Solmate](https://github.com/transmissions11/solmate/tree/89365b880c4f3c786bdd453d4b8e8fe410344a69), commit `89365b880c4f3c786bdd453d4b8e8fe410344a69` | `Owned.sol` (MIT source notice), used by Uniswap's test-deployed PoolManager. Upstream repository license retained. |
| `lib/forge-std` | [forge-std v1.9.7](https://github.com/foundry-rs/forge-std/tree/77041d2ce690e692d6e03cc812b57d1ddaa4d505), commit `77041d2ce690e692d6e03cc812b57d1ddaa4d505` | Test utilities, Apache-2.0/MIT licenses. |

`src/interfaces/IIntake.sol` was copied from the assignment's canonical Intake v2 client reference. `IntakeAccount` adapts its per-user payer with a reentrancy guard, post-payment balance verification and explicit allowance cleanup. No runtime links to external libraries are required. Application code does not deploy the Uniswap or OpenZeppelin dependency implementations.
