# Known Limitations

Written deliberately and specifically, based on real behavior observed
while building and testing this system (including bugs the test suite
caught during development) -- not a generic disclaimer.

## Facing/placement trust has no automatic verification without GPS

Worker facing is not observable via any CC:Tweaked API. A worker seeds
its dead-reckoning position and facing directly from the job's
`starting_position`/`starting_facing` at the moment it accepts a job,
**trusting that the operator physically placed it there correctly**.

If GPS is unavailable (the common case without a constellation set
up), a misplacement is **silently undetected**: the worker will mine
starting from wherever it actually is, one block off (or more) from
where the master's partition math assumed, potentially even mining
outside the intended physical area (though never outside its own
*logical* partition -- the digging is still internally consistent,
just physically offset from the operator's intent). This was caught
directly during development: an early version of the integration test
(`tests/test_worker_integration.lua`) placed the mock turtle one block
away from `starting_position` and the worker proceeded without
complaint, silently mining the wrong physical column.

**Mitigation:** set up GPS (`docs/GPS_SETUP.md`). With it,
`lib/gpsnav.lua:reconcile()` will detect the mismatch on its first
periodic check and safely stop the worker in `ERROR`. Without it,
double-check physical placement against `dryrun`'s printed starting
positions before every `deploy`.

## All workers are assigned `starting_facing = 0` (north)

`master.lua`'s `deploy` command currently hardcodes every worker's
`starting_facing` to north rather than exposing it as a per-worker
configurable value. This matches the documented setup instruction
("face every turtle north before deployment") but means there's
currently no way to deploy workers in mixed orientations. Extending
the `new` wizard / job schema to accept a per-slot facing would be a
straightforward follow-up.

## No obstacle routing / pathfinding around permanently blocked cells

If a worker cannot clear a cell after bounded retries (a protected
block, or a liquid under `STOP_AT_LIQUID`), it stops safely in `ERROR`
rather than attempting to route around the obstacle through
neighboring, not-yet-visited cells. This is a deliberate scope
boundary, not an oversight: routing around an obstacle risks either
crossing into a neighboring worker's partition or leaving gaps in the
guaranteed "every block visited exactly once" traversal property that
`lib/traversal.lua` is built and tested around. See
`docs/RECOVERY.md`'s "Worker stuck in ERROR" for the manual recovery
path (resolve the obstacle, then `resume`).

## `cleanupPass` configuration exists but the pass itself is not implemented

The job configuration accepts a `cleanupPass` boolean (per the
requirement to support "an optional cleanup/pass after the main
excavation"), and it is validated and threaded through to the job
payload, but `worker.lua` does not currently act on it -- there is no
second traversal pass implemented. Treat this as a placeholder for a
follow-up: the traversal primitives (`lib/traversal.lua`) and
mining primitives (`lib/mining.lua`) needed to build one already exist
and are tested; what's missing is the orchestration in `worker.lua`'s
`MINING`/`COMPLETED` transition to loop back over the partition once
more, re-inspecting each cell for stragglers (e.g. blocks that fell in
from a neighboring partition's cascade after this worker already
passed).

## `unloadPoint.direction = "forward"` is fragile

`lib/navigation.lua:moveTo()` guarantees reaching the target
*coordinate*, not a specific final *facing*. If the last leg of travel
to the unload point is vertical (no horizontal move), the worker's
facing on arrival is whatever it was before -- not necessarily pointed
at the storage container. `"down"` or `"up"` are recommended instead
(facing-independent). See `docs/CONFIG_REFERENCE.md`.

## No mid-job re-partitioning or worker replacement

If a worker becomes permanently unresponsive or is destroyed mid-job,
its partition simply stops progressing; there is no mechanism to
reassign its remaining (unvisited) volume to another worker within the
same job. Recovering that volume today means configuring and deploying
a new, smaller job covering just the unfinished region.

## No "force-trust GPS and resume" recovery command

When GPS reconciliation marks a worker's position untrusted, the only
UI-exposed recovery path is investigate-and-cancel/redeploy (see
`docs/RECOVERY.md`). There is no button that says "trust the last GPS
fix and resume mining from there" -- this is deliberate (the system
should not make that judgment call automatically), but it does mean
recovery from this specific failure mode is more manual than other
failure modes.

## Single active job, single master

This system manages one quarry job at a time from one master computer.
Running multiple independent quarries concurrently would require
either multiple master computers with distinct protocol namespacing
(not currently parameterized -- `protocol.NAME` is a fixed constant)
or extending the protocol/job model to carry a master identity
distinct from `job_id`.

## No cryptographic message authentication

Per CC:Tweaked's own documentation, rednet provides no security
guarantees against eavesdropping or spoofing. This system validates
protocol version, job ID, worker ID, and sequence number on every
message (rejecting anything stale, unrelated, or duplicated), which
prevents accidental cross-talk and stale-message bugs, but does not
cryptographically prevent a malicious actor with their own rednet
computer on the same server from crafting valid-looking protocol
messages. This is an accepted risk consistent with typical CC:Tweaked
deployments (single-owner base, trusted server), not a gap specific to
this project.

## Falling-block cascades are bounded (default 8 attempts per cell)

`lib/mining.lua:clear()`'s retry loop is bounded
(`maxClearAttempts`, default 8) specifically so a permanently
obstructed cell can never hang the worker. An extraordinarily deep
falling-block stack (more than 8 blocks) would exhaust this bound and
be classified `BLOCKED` rather than fully drained. Raise
`maxClearAttempts` in `lib/mining.lua`'s construction if your world
generation produces unusually deep sand/gravel columns; this is a
constructor parameter, not a hardcoded constant.

## `BLOCK_LIQUID` needs `sealBlockSlot`, which the `new` wizard doesn't currently ask for

`lib/mining.lua`'s `BLOCK_LIQUID` policy seals a liquid by placing an
item from a specific configured inventory slot (`sealBlockSlot`).
`master.lua`'s `new` command wizard does not currently prompt for
this field, so choosing `BLOCK_LIQUID` via the interactive wizard
leaves `sealBlockSlot` unset. This fails **safely**: `sealLiquid()`
checks for a configured slot first and returns a classified
`CONFIGURATION_ERROR` (not a crash) if it's missing, so the worker
stops and reports the problem rather than doing anything destructive
-- but it means `BLOCK_LIQUID` is effectively non-functional through
the current wizard until either the wizard is extended or
`sealBlockSlot` is set by editing the generated configuration
directly before `deploy`.

## GPS facing calibration exists but isn't wired into automatic recovery

`lib/gpsnav.lua:calibrateFacing()` (take a GPS fix, make one controlled
move, infer facing from the delta) is implemented and unit-tested, but
`worker.lua` does not currently call it automatically anywhere (e.g.
during `RECOVERING`) -- it's available as a building block for a more
autonomous recovery flow but isn't part of the current state machine.
