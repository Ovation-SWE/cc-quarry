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

## The GUI's rendering/interaction layer is not covered by the "no Minecraft needed" test suite

Every other claim in this project is backed by a test running against
a deterministic mock, with no Minecraft instance required. `master/gui.lua`
only partially fits that pattern: `tests/test_master_gui.lua` verifies
its *logic* (config parsing, deploy/start/pause/cancel wiring into
`lib/*.lua`) against `tests/mocks/basalt_mock.lua`, a fake widget tree
with no real rendering. It cannot verify the real Basalt2 library's
actual behavior -- layout correctness, whether a given API call
(`:addTable`, `:onSelect`, the confirm-modal overlay, etc.) matches
what basalt2.5 actually does at runtime, or whether it behaves
correctly on a real turtle/computer terminal. That part was verified
by reading Basalt2's source and docs (see `master/gui.lua`'s header
comment and bootstrap.lua's install step), not by an automated test,
and should be smoke-tested in-game after first install. If something
about the GUI doesn't render or respond as expected, `master.lua` (the
text UI) is always available as a fallback -- see README.md's "GUI vs.
text UI".

## The depot workflow digs through anything outside the partition on the way in

When `depotPoint` is configured, the transit leg from the depot to
`starting_position` (`steps.NAVIGATING_TO_START`) uses a partition-free
mining instance (`ctx.transitMining` in `worker.lua`) specifically so it
can clear a path -- the normal partition-fenced instance would refuse
every dig on that leg, since it's necessarily outside the worker's own
assigned partition. Liquid safety is still enforced identically (lava
is never walked into regardless of policy); only the partition fence is
bypassed. This was a deliberate choice over requiring a pre-cleared
path: place the depot somewhere a worker tunneling straight-line toward
its job site won't go through anything you care about keeping intact.

## Depot fuel collection can draw more than one trip actually needs

`turtle.suck()` pulls up to a full item stack per call, and
`turtle.refuel()` burns an entire stack per call -- both real
CC:Tweaked behaviors this project doesn't try to make more granular
(see `lib/fuel.lua`'s header comment on never hardcoding a specific
fuel item's value). A single worker's one visit to the depot can
therefore consume substantially more of the shared stock than that
one trip strictly needs. Size what you stock the depot with
accordingly -- see `docs/SETUP.md`'s depot workflow.

## Depot placement is sequential, not parallel

A depot/staging pad is one physical block position; only one turtle
can occupy it at a time. Provisioning N workers via a depot means
placing them at that one spot one at a time (power on, let it collect
and depart, then place the next), not lining several up simultaneously.

## No pickaxe auto-equip at the depot

The depot workflow automates fuel collection, not tool equipping.
Equipping a pickaxe (`turtle.equipLeft`/`equipRight`) is a one-time
action at a turtle's crafting/setup time, not a recurring per-job
resource, and CC:Tweaked has no API to query whether a tool is already
equipped -- there's no safe way to auto-equip without risking swapping
out a tool that's already there. Mining Turtles (built-in pickaxe)
need nothing here; a plain turtle needs its pickaxe equipped once,
manually, before its first job.

## The GUI's Setup tab has the same `BLOCK_LIQUID` gap as the CLI wizard

Like `master.lua`'s `new` command (see "`BLOCK_LIQUID` needs
`sealBlockSlot`..." above), the GUI's Setup tab does not expose
`sealBlockSlot`. Choosing the `BLOCK_LIQUID` liquid policy through
either UI leaves it unset, which fails safely (a reported
`CONFIGURATION_ERROR`, not a crash) but requires editing the saved
`master_state` configuration directly to actually use that policy.
