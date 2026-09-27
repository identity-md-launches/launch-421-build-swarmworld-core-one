# Review: SwarmWorld Core

Scope: `src/SwarmWorld.sol`, `src/LaunchToken.sol`, `script/Deploy.s.sol`, the test suite and
`foundry.toml`. This is a self-review by the implementing seat, written against the audit
questions in the task reference. It is not a substitute for the independent adversarial review
the network runs before release.

## What was re-run

| Command | Result |
| --- | --- |
| `forge build --offline` (solc 0.8.26) | success, lint warnings only (`block-timestamp`, one `unsafe-typecast` on the `uint64` deadline) |
| `forge test --offline` | 65 passed, 0 failed (52 SwarmWorld incl. 3 fuzz, 9 LaunchToken incl. 1 fuzz, 4 Deploy) |
| `forge fmt --check` | clean |
| `EXPECTED_CHAIN_ID=0 forge script script/Deploy.s.sol:Deploy --offline` | one deployment, script ran successfully |
| `EXPECTED_CHAIN_ID=1 forge script ...` | reverts `UnexpectedChain(1, 31337)` as intended |
| Protected floor tests (`Project.protected.t.sol`, `Token.protected.t.sol`) run from `test/scratch/` with a simulated factory environment | 8 passed |

## Findings

### F1. Reward re-entrancy through `claim()` — no issue

`claim()` reads the balance, reverts on zero, zeroes storage and `totalClaimable`, emits, then
sends. A re-entrant `claim()` from the receiver sees zero and reverts. Test
`test_reentrantClaimAttempt` uses a contract that re-enters from `receive` and confirms it is
paid exactly once and the inner call reverted. No other function performs an external call.

### F2. Failed ETH send — accepted design

If the receiver reverts, `claim()` reverts with `EthTransferFailed` and the balance stays
claimable. Only that account is affected; `test_claimToRejectingReceiverRevertsAndKeepsBalance`
shows the other three workers still claim. A contract-wallet worker that cannot receive ETH
strands only its own share. Documented in README.

### F3. Conservation of ETH — holds

No `receive`/`fallback`, so the only inflow is `openEnergyMission`. Every terminal transition
moves the reward from `totalEscrowed` to `totalClaimable` exactly once. Tests assert
`balance == totalEscrowed + totalClaimable` after every scenario, including the fuzzed reward
split. Rounding dust goes to the verifier, so the four shares always sum to the reward.

### F4. Mission expiry vs. PASSED — design decision, documented

A PASSED mission cannot be expired by the sponsor; it can be settled at any time by anyone.
Rationale: the four gates have accepted the work, and the settlement's energy and materials are
frozen while a mission is active, so the proposal stays valid. The alternative (sponsor may
expire a PASSED mission after 3 days) would let a sponsor race the permissionless settlement to
claw back a reward the workers earned. `test_passedMissionCannotExpireAndSettlesAfterDeadline`
pins this.

### F5. Role actions after the deadline — reverts

`_live` rejects every builder/tester/reviewer/verifier action once `block.timestamp >= deadline`,
which is the same instant `expireMission` becomes available. There is no window where both the
workers and the sponsor can act, so no race on the reward. `test_threeDayExpiryBoundary` checks
`deadline - 1` and `deadline` on both sides.

### F6. Outcome bounds at settlement — re-checked

`_validateOutcome` runs at submit and again at settle. Because a settlement with an active
mission never changes energy (ticks skip it) or materials (only that mission can spend them),
the second check cannot fail today. It is kept so any future mission type that touches those
fields cannot push energy above 1000 or materials below 0.

### F7. `resulting energy <= 1000` is unreachable at open — noted

A mission opens only when energy < 300, and the maximum gain is 300, so the resulting energy
is at most 599. The bound is enforced in shared code but no on-chain path can trigger the
`EnergyWouldExceedMax` revert. `test_resultingEnergyCannotExceed1000` documents this.

### F8. Seat IDs — provenance only

The four `uint32` seat IDs are stored, required distinct, included in `proofHash` and emitted.
The contract does not authenticate them and the README says so. Seat 0 is accepted.

### F9. Timestamp dependence — accepted

`tick()` and mission deadlines compare `block.timestamp`. Validators can shift it by seconds; the
boundaries here are one day and three days, so this is not exploitable in a meaningful way.

### F10. Sponsor self-dealing — accepted, documented

A sponsor may name four addresses they control and therefore pass their own mission. This is
inherent to a permissionless open-mission design with sponsor-chosen roles; it cannot take
anyone else's funds, since the sponsor's own reward is the only ETH involved. The world state
change it produces is bounded by the outcome limits.

### F11. Launch token — required by the pipeline, decoupled from the world

The brief says "No token". SwarmWorld satisfies that. `LaunchToken` exists solely because the
ProjectFactory launch refuses a project without `src/LaunchToken.sol`; the previous submission
was rejected on that ground. The token is a minimal hand-written ERC-20 with fixed supply,
no admin functions, no proxy and no `SELFDESTRUCT`, and the protected floor tests for it pass.

### F12. Compiler warnings — lint only

Three `block-timestamp` lints and one `unsafe-typecast` (`uint64(block.timestamp + 3 days)`,
which cannot truncate before the year 584 billion). No compiler errors or warnings.

## Untested or out of scope

- Real Sepolia deployment. None was performed; no address or tx hash is claimed.
- Gas at scale: mission storage grows without bound (one struct per mission, never deleted).
  There is no loop over missions, so this only affects storage cost, not liveness.
- Multiple mission types and any effect on food, knowledge, population, stability.

## Disposition

No open defects. F2, F4, F7, F9 and F10 are design decisions recorded in the README.
