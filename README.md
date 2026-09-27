# SwarmWorld Core

A persistent on-chain world where independent workers submit, test, review and verify missions
before world state changes. One standalone Foundry project, Solidity 0.8.26.

- `src/SwarmWorld.sol` is the world. No owner, no admin, no upgradeability, no pausing, no
  external contracts, no token. Mission rewards are native ETH only.
- `src/LaunchToken.sol` is the fixed-supply ERC-20 the IMD project-launch pipeline requires for
  every launch. SwarmWorld never references it. It exists only because the launch factory
  cannot deploy a project without one (see "Launch token" below).

## Layout

| Path | Contents |
| --- | --- |
| `src/SwarmWorld.sol` | World, missions, rewards |
| `src/LaunchToken.sol` | Launch ERC-20 (1,000,000,000 SWARM, 18 decimals, minted to deployer) |
| `script/Deploy.s.sol` | Deploys exactly one SwarmWorld; reads no keys |
| `test/SwarmWorld.t.sol` | 53 tests including fuzz, every case the brief lists |
| `test/LaunchToken.t.sol` | Supply, transfer, allowance, no admin entrypoints |
| `test/Deploy.t.sol` | Calls the deploy function and chain guard directly |
| `docs/abi/SwarmWorld.json`, `docs/abi/LaunchToken.json` | Exported ABIs |
| `lib/forge-std` | Vendored forge-std 1.16.2 (ordinary files, no submodule) |
| `REVIEW.md` | Independent-style review: findings, disposition, what was re-run |

## World rules

Three settlements with fixed IDs. Resources `energy`, `food`, `materials`, `knowledge` are
bounded 0..1000; `stability` is bounded 0..100.

| ID | Name | energy | food | materials | knowledge | population | stability |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 0 | Genesis City | 500 | 500 | 500 | 500 | 100 | 80 |
| 1 | Iron Valley | 420 | 550 | 700 | 350 | 100 | 75 |
| 2 | Nova Port | 120 | 420 | 300 | 180 | 100 | 75 |

### Time

`tick()` is permissionless and executes at most once per 24 hours, measured from the last
accepted tick (`lastTickAt`, initialised to deployment time). It succeeds exactly at
`lastTickAt + 1 days` and reverts with `TickTooEarly` one second earlier. Each tick reduces
energy by 25, saturating at zero, for every settlement that has no active mission. It emits
`Tick(tickNumber, timestamp)` and then `EnergyCrisis(settlementId, energy)` for every settlement
whose energy is strictly below 300 after the reduction. Missed days are not caught up: three
days without a tick still produce a single tick.

### Missions

One mission type: `ENERGY_REPAIR`. `openEnergyMission(settlementId, roles)` is payable; anyone
may call it for a settlement with energy < 300 and no active mission. The requirements are:

- `msg.value > 0` (this is the escrowed reward);
- four nonzero, pairwise distinct payout addresses: builder, tester, reviewer, verifier;
- four pairwise distinct `uint32` IMD seat IDs. They are provenance only. The contract does not
  and cannot authenticate seat IDs; the payout addresses are the authorisation.

Mission IDs start at 1. Lifetime is 3 days from creation. Exactly one active mission per
settlement; the slot is freed on SETTLED, FAILED or EXPIRED.

States: `OPEN, WORKING, VERIFYING, PASSED, FAILED, SETTLED, EXPIRED`.

| Step | Caller | From | To | Notes |
| --- | --- | --- | --- | --- |
| `submitOutcome(id, energyGain, materialsCost, artifactHash)` | builder | OPEN | WORKING | 200 <= gain <= 300, cost <= 100, energy + gain <= 1000, materials >= cost |
| `submitTest(id, testHash, pass)` | tester | WORKING | WORKING or FAILED | pass records `testPassed`; fail refunds sponsor |
| `submitReview(id, reviewHash, pass)` | reviewer | WORKING (after test pass) | VERIFYING or FAILED | |
| `verifyOutcome(id, verificationHash, pass)` | verifier | VERIFYING | PASSED or FAILED | |
| `settleMission(id)` | anyone | PASSED | SETTLED | applies outcome, stores proofHash, credits workers |
| `expireMission(id)` | anyone | OPEN, WORKING, VERIFYING | EXPIRED | only at or after `deadline`; refunds the sponsor |

Role actions revert with `MissionDeadlinePassed` once `block.timestamp >= deadline`. A PASSED
mission cannot expire and can be settled at any later time: the work was accepted and the
settlement's energy is frozen while the mission is active, so the proposal remains valid.

Expiry is permissionless on purpose. After the deadline no role can act, so if only the sponsor
could expire, a sponsor who disappears (or who opened a 1 wei mission to grief) would hold the
settlement's single mission slot forever and stop its ticks. Whoever calls `expireMission`, the
full reward is credited to the recorded sponsor and nothing to the caller.

### Settlement

On `settleMission` the contract adds `energyGain` to energy, subtracts `materialsCost` from
materials, marks the mission SETTLED and clears the active-mission pointer. Food, knowledge,
population and stability are never modified. Both bounds are re-checked defensively before the
write.

`proofHash = keccak256(abi.encode(missionId, settlementId, worldStateBefore, energyGain,
materialsCost, builderArtifactHash, testHash, reviewHash, verificationHash, builderSeat,
testerSeat, reviewerSeat, verifierSeat))` where `worldStateBefore = worldStateHash()` taken
immediately before the write. `worldStateHash()` hashes every field of every settlement except
the active-mission pointer. `computeProofHash(...)` is a public pure function so the value can be
recomputed off-chain. `MissionSettled` carries the proof hash, the before and after world hashes
and the energy and materials transition.

### Rewards

Pull payments only. Terminal transitions credit `claimable[account]`; `claim()` zeroes the
caller's balance before sending ETH and reverts (restoring nothing, because state was already
zeroed inside the reverted call) if the send fails. A recipient that rejects ETH blocks only
itself.

| Outcome | Credit |
| --- | --- |
| SETTLED | builder 50%, tester 15%, reviewer 15%, verifier the remainder (20% plus rounding dust) |
| FAILED | sponsor receives the full reward |
| EXPIRED | sponsor receives the full reward |

Each mission credits exactly once because every terminal transition is guarded by the state
machine, and `claim()` cannot pay twice because the balance is zeroed first. The contract has no
`receive` or `fallback`, so `address(this).balance == totalEscrowed + totalClaimable` holds at all
times; the tests assert this after every scenario.

## Building and testing offline

```
forge build --offline
forge test --offline
forge fmt --check
EXPECTED_CHAIN_ID=0 forge script script/Deploy.s.sol:Deploy --offline
```

`foundry.toml` pins `solc = "0.8.26"`, optimizer on with 200 runs, `evm_version = "paris"`,
`bytecode_hash = "none"`, `ffi = false`, `fs_permissions = []`. No remote dependencies: forge-std
is committed under `lib/`. Tests read no environment variables and pass in any order.

## Deployment

SwarmWorld has a nonpayable constructor with no arguments and no post-deployment configuration.
The deploy script performs exactly one deployment between the broadcast markers. It reads a
single environment variable, `EXPECTED_CHAIN_ID`; when nonzero it must equal `block.chainid` and
be 31337 (Anvil) or 11155111 (Sepolia). The script never reads a private key. The operator that
holds the deployer key runs:

```
EXPECTED_CHAIN_ID=11155111 forge script script/Deploy.s.sol:Deploy \
  --rpc-url <sepolia-rpc> --broadcast <signer flags>
```

Target chain: Sepolia (11155111). **No Sepolia deployment was performed by this assignment.** No
contract address or transaction hash is claimed. Deployment is performed by the network's own
deployer after review.

### Launch pipeline (ProjectFactory)

- Launch token: `LaunchToken`, no constructor arguments, mints 10^27 minor units to
  `msg.sender` (the factory).
- Application contract: `SwarmWorld`, no constructor arguments, no `$owner`, `$token` or
  `$contract:` references needed.
- Neither contract contains `DELEGATECALL`, `CALLCODE` or `SELFDESTRUCT`. SwarmWorld runtime is
  well under the EIP-170 limit.

### Launch token

The brief says "No token" and that rule is honoured by SwarmWorld: it holds no token, references
no token and pays rewards in ETH only. The IMD project-launch pipeline separately refuses any
launch without a fixed-supply ERC-20 at `src/LaunchToken.sol`, and the previous submission was
rejected for exactly that reason. `LaunchToken` therefore ships as an independent contract with
no coupling to the world. It has no mint, burn, owner, pause, blocklist, fee or upgrade path.

## Operational responsibilities and assumptions

- Someone must call `tick()` daily. Nothing happens automatically; a missed day is simply lost.
- Someone must call `expireMission` on missions that pass their deadline without reaching
  PASSED. Anyone may do so; until it happens the settlement stays busy and its ticks are skipped.
- The sponsor chooses the four workers and their seat IDs. The contract enforces distinctness,
  not competence or independence. A sponsor can name four addresses they control; the reward
  is then paid to themselves, which harms no one else, but the resulting world-state change is
  only as trustworthy as the sponsor.
- The builder alone chooses `energyGain` and `materialsCost` within the bounds. Tester, reviewer
  and verifier gate whether that proposal is applied.
- Timestamps come from `block.timestamp`. Validators can nudge them by seconds, which is
  irrelevant at day-scale boundaries.
- Only `ENERGY_REPAIR` exists. Food, knowledge, population and stability are stored and hashed
  but no mission type changes them yet.
- There is no way to recover ETH except through `claim()` by its rightful owner. There is no
  admin sweep.
- This assignment did not deploy anything and never held a key.
