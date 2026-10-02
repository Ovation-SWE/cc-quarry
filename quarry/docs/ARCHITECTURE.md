# Architecture Overview

## Target platform

This system targets **CC:Tweaked**, current stable as documented at
[tweaked.cc](https://tweaked.cc) at the time of writing (the fetched
`turtle` API docs reference additions up through v1.116.0, i.e. the
current 1.20.x/1.21.x-era CC:Tweaked line). All APIs used were
verified against that documentation (see "Verified APIs" below).
Code is written in Lua 5.1/5.2-compatible syntax (no `goto`, no
integer-division `//`, no `<const>` attributes, no `utf8` library) to
avoid depending on Cobalt (CC:Tweaked's Lua runtime) supporting any
particular newer Lua feature beyond what's documented.

## Component map

```
quarry/
  lib/            shared, unit-tested modules (see tests/)
  worker/         worker turtle program (startup.lua + worker.lua)
  master/         master computer program (startup.lua + master.lua)
  tools/          provision_disk.lua -- worker deployment station helper
  tests/          unit + integration tests, run with a local `lua` interpreter
  config/         example/reference configuration
  docs/           this documentation set
```

A worker computer's root filesystem, once deployed, contains its own
copy of `lib/`, plus `worker.lua` and `startup.lua` at the root
(flattened -- see docs/SETUP.md). The master computer similarly has
its own copy of `lib/`, plus `master.lua` and `startup.lua`.
`lib/` is duplicated across the two roles by deployment (copy), not by
in-repo duplication -- there is exactly one canonical copy of each
module in this repository, under `quarry/lib/`.

## Why library code and top-level programs are split

`worker.lua` and `master.lua` are thin orchestration layers: they wire
together tested modules from `lib/` and drive a state machine. All the
logic that can fail in interesting ways -- movement, digging, fuel,
inventory, GPS reconciliation, message reliability, persistence,
partitioning, validation -- lives in `lib/*.lua`, each of which is
unit-tested against deterministic mocks in `tests/` (a simulated
turtle+world, an in-memory rednet bus, a real-filesystem-backed `fs`
mock). `worker.lua` and `master.lua` themselves are additionally
exercised end-to-end in `tests/test_worker_integration.lua` and
`tests/test_master_integration.lua`, which stub the full CC:Tweaked
global environment and drive each program through a complete job
lifecycle. See "Testing" below.

## The partitioning algorithm

Implemented in `lib/partition.lua`. Given a quarry volume (dx * dy *
dz blocks) and a worker count N, we need exactly N non-overlapping,
gap-free rectangular sub-volumes that together cover the whole quarry,
even in degenerate cases (a 1x1x100 shaft, N exceeding one dimension,
N equal to the total volume so every worker gets exactly one block).

**Algorithm: recursive guillotine bisection, geometry-first.**

To split a region among n workers (n > 1):

1. Pick the longest axis with length > 1 (ties broken X > Z > Y).
   Whenever n > 1 the region's volume is >= n >= 2, so such an axis
   always exists.
2. Cut that axis *geometrically* in half: `l1 = floor(L/2)`,
   `l2 = L - l1`. This is a pure geometry decision, independent of n,
   so it can never demand more length than the axis actually has.
3. Compute the two sub-volumes `vol1 = l1*otherArea`,
   `vol2 = l2*otherArea` (`otherArea` = product of the two axes not
   being cut).
4. Allocate the n workers between the two halves proportionally to
   their volume, **clamped** to the range
   `[max(1, n - vol2), min(vol1, n - 1)]`. This range is always
   non-empty when n >= 2 and vol1, vol2 >= 1 (which always holds
   here), because `vol1 + vol2 = volume >= n`. The clamp guarantees
   `1 <= n1 <= vol1` and `1 <= n2 <= vol2`: neither half is ever asked
   to seat more workers than it has blocks for, and neither half is
   ever left with zero workers despite having volume.

Recurse on both halves; stop at n == 1 (one leaf rectangle per
worker). An earlier version of this algorithm tried to fix the
worker split first (`n1 = floor(n/2)`) and derive the geometric cut
from that -- this is provably wrong (see the git-history-adjacent
comment in `lib/partition.lua`): for tight packing (e.g. a 3x3x3
volume split 27 ways, one block per worker) it can demand a slab
thinner than the workers assigned to it need, producing a
negative-length region. The geometry-first approach sidesteps this
because the cut is always physically valid before any worker count is
assigned to it.

**Verification:** `tests/test_partition.lua` doesn't just spot-check a
few cases -- for every case with a small-enough volume (<=20000
blocks) it brute-force enumerates every block and asserts each is
covered by exactly one partition, plus checks pairwise
non-overlap and positive volume for every partition. This runs over a
200-case randomized sweep plus every explicitly required edge case
(1x1x1, 1x1x100, 100x1x1, odd dimensions, worker count exceeding a
single dimension, negative coordinates, coordinates crossing zero,
worker count equal to and vastly exceeding total volume). All ~79,300
individual assertions pass.

## The traversal (navigation) algorithm

Implemented in `lib/traversal.lua`. A worker's assigned partition is
visited top-down, one Y layer at a time, in a boustrophedon
("serpentine") pattern within each layer.

The key design property: **the next cell to visit is a pure function
of the current cell** (`traversal.nextCell(partition, x, y, z)`) --
no separate "row index" / "layer index" counters need to be persisted.
The worker's own (x, y, z) position, which is already persisted for
other reasons, is sufficient to resume traversal after a reboot at any
point.

Row direction must alternate *continuously across the entire path*,
not reset at each layer boundary -- whichever end of a row a layer's
last row finishes on is exactly where the next layer's first row
begins. This is implemented via a "global row index" (summed across
all preceding layers), not a per-layer row index; an earlier version
that reset the row-parity calculation per layer broke whenever a
layer had an even row count, producing a path that terminated early
and left the tail of the partition unvisited (caught by
`tests/test_traversal.lua`'s exhaustive path-connectivity checks
before this code ever reached a real turtle).

`tests/test_traversal.lua` exhaustively walks the generated path for
every required edge case and a 100-case randomized sweep, asserting:
every cell in the partition is visited exactly once, no step moves
more than one block on more than one axis (i.e. the path is always
physically realizable as a sequence of single forward/up/down moves),
and `traversal.indexOf()` (used for progress reporting) agrees with
actual path position.

## Navigation engine

Implemented in `lib/navigation.lua` + `lib/directions.lua`. Position
is tracked as `{x, y, z, facing}` via dead reckoning: `facing` only
changes through `turnLeft()`/`turnRight()` calls this module itself
issues, and `x/y/z` only change after a movement call *reports
success*, never optimistically. Movement functions
(`forward/back/up/down`, `moveX/moveY/moveZ`, `moveTo`) are
dependency-injected against a `turtle`-shaped API and a `sleep`
function, so they're fully unit-testable against
`tests/mocks/world.lua` (a deterministic in-memory turtle+world
simulator) without a running Minecraft instance.

Every movement call: checks fuel availability first; attempts the
move; on failure, if an `obstacleHandler` is configured (worker.lua
wires this to `lib/mining.lua`'s `clear()`), invokes it to attempt to
clear the obstacle, then retries -- bounded by `maxMoveRetries`
(default 6), never an unbounded loop; classifies every failure via
`lib/errors.lua`'s fixed vocabulary (`TRANSIENT`, `RECOVERABLE`,
`BLOCKED`, `RESOURCE_EXHAUSTED`, `CONFIGURATION_ERROR`, `FATAL`).

**No compass exists in CC:Tweaked.** `gps.locate()` reports position
only, never facing. The system's only ground truth for facing is: (a)
the operator physically orienting the turtle to the job's
`starting_facing` before deployment, which the worker trusts at job
acceptance time (see "GPS reconciliation" below and
docs/LIMITATIONS.md for what happens if this trust is misplaced), and
(b) an opportunistic recalibration technique
(`lib/gpsnav.lua:calibrateFacing()`) that takes a GPS fix, performs
one raw (nav-bypassing) forward move, takes a second fix, and infers
facing from the observed delta -- used for validation, not routine
tracking.

## GPS reconciliation

Implemented in `lib/gpsnav.lua`. **A GPS fix is never trusted
blindly.** `reconcile()` compares a fix against the navigator's
dead-reckoned position:

- No fix obtainable (no constellation in range, timeout, temporary
  wireless issue) -> treated as a normal, expected condition; the
  worker simply continues on dead reckoning and tries again later.
  This is *not* an error.
- Fix matches dead reckoning (within a configurable tolerance,
  default 0 blocks) -> confirms trust, no state change.
- Fix disagrees -> the navigator is marked **untrusted**
  (`nav:markUntrusted()`), which makes every subsequent
  mining/movement operation refuse to proceed until the operator
  resolves it (see docs/RECOVERY.md). The system never "splits the
  difference" or guesses which source is right.

Reliable GPS requires an operator-provided GPS host constellation
(see docs/GPS_SETUP.md) -- this system can consume it defensively but
cannot create it.

## Falling-block (gravel/sand/etc.) handling

Implemented in `lib/mining.lua`'s `clear()`. **No hardcoded list of
"falling block" names is used.** Instead, after every dig attempt the
target cell is re-inspected in a bounded loop (default 8 attempts):
if a new block is now present (because something fell into the
space), the loop digs it too; if the cell is genuinely empty, `clear()`
returns success; if the bound is exhausted with a block still present,
it's classified `BLOCKED` and reported rather than retried forever.

This is deliberately agnostic to *why* a new block appeared -- it
handles gravel, sand, suspicious sand/gravel, concrete powder, and any
modded falling block equally, without needing to enumerate every
possible falling-block ID (including ones that don't exist yet).
`tests/mocks/world.lua` simulates gravity by shifting exactly one
falling block down per `dig()` call (matching the granularity
`clear()`'s retry loop expects), and `tests/test_mining.lua` verifies
a 4-deep gravel cascade and a sand cascade are both fully drained.

Before any dig, the target's world coordinate is checked against the
worker's partition bounds (`lib/partition.lua:contains()`); a block
outside the partition is never touched, even if physically
encountered (e.g. a neighbor's gravel cascading into shared airspace).

## Liquid handling

Also in `lib/mining.lua`. Three policies, `STOP_AT_LIQUID` (default,
safest), `BLOCK_LIQUID` (seal with a configured inventory item via
`turtle.place*()`, since liquids aren't diggable but *are*
displaceable by placing a solid block into them), and `ALLOW_LIQUID`
(water only -- **lava is never passed through regardless of
configured policy**, a hardcoded safety override to protect the
turtle).

## Inventory and fuel management

`lib/inventory.lua` unloads via `turtle.drop()/dropUp()/dropDown()`
rather than the peripheral inventory API -- this works against *any*
adjacent inventory-holding block without needing to know its specific
peripheral type, satisfying "must not assume every chest has the same
interface." `lib/fuel.lua` never assumes a specific fuel item;
`autoRefuel()` scans configured (or all) inventory slots and consumes
whatever `turtle.refuel()` accepts, stopping once the target level is
reached.

## Persistence and recovery

Implemented in `lib/persistence.lua`. Every save writes to a `.tmp`
file first, then preserves the previous good copy as `.bak` before
the tmp file replaces the real path. A crash/power-loss/reboot at any
point during a save can only ever leave behind the old good file
untouched, or the old file renamed to `.bak` with a complete new file
in place -- never a half-written primary. `load()` automatically falls
back to `.bak` if the primary is missing or fails to deserialize.
`tests/test_persistence.lua` verifies this against a real filesystem,
including a simulated crash mid-write (a stray `.tmp` left over from
an interrupted save must never be read) and primary corruption
(falls back to backup).

Workers checkpoint (persist job, dead-reckoned position, current
state, in-progress return-trip phase, last error) after every
successful movement/state transition. On boot, a worker loads its
state, attempts GPS reconciliation, and resumes into *the exact state
it was in* (not a blanket "resume mining") -- e.g. a worker that
rebooted while waiting for the master's `start` command goes back to
waiting, not straight into moving.

The master persists its configuration, job ID, partitions, worker
registry, and deployment/start status, and reconstructs this
automatically on startup (`loadState()` runs unconditionally before
the command loop starts).

## Worker state machine

Implemented generically in `lib/state_machine.lua` (explicit
enter/exit hooks per state, shared context, no scattered boolean
flags) and instantiated in `worker/worker.lua`:

```
BOOT -> REGISTERING -> WAITING_FOR_JOB -> VALIDATING_JOB -> ASSIGNED
  -> NAVIGATING_TO_START -> MINING <-> INVENTORY_RETURN
                                    <-> FUEL_RETURN
     MINING -> COMPLETED
     (any)   -> PAUSED -> MINING (on RESUME)
     (any)   -> ERROR -> MINING (on RESUME, operator-confirmed)
     (any)   -> EMERGENCY_STOP (terminal until a new job is assigned)
     BOOT    -> RECOVERING -> (whichever state was persisted)
```

`ASSIGNED` is a deliberate waiting state: a worker that has validated
and accepted a job does **not** start moving on its own. It waits for
an explicit `start` command from the master (a distinct, confirmed
step from `deploy`), matching the requirement that starting a
destructive quarry job requires a clear, separate confirmation.

## Communication protocol ("quarry.v1")

Implemented in `lib/protocol.lua` (pure envelope construction/
validation) and `lib/comms.lua` (stateful reliable messaging on top of
rednet). Every message carries `protocolVersion`, `jobId`, `workerId`,
and a monotonically increasing per-sender `sequence` number.

`rednet.send()` only reports whether transmission was *attempted*, not
whether it was received (per tweaked.cc's own documentation) --
`comms:sendReliable()` is the only way this codebase sends anything
that must provably arrive: it retries with exponential backoff
(capped) until it receives an application-level ACK referencing the
same sequence number, or exhausts a bounded retry count. Heartbeats
use `comms:sendFireAndForget()` deliberately: a single lost heartbeat
is harmless (superseded by the next one shortly), so retrying would
only add latency risk to the worker's main loop for no benefit.

Every incoming message is validated (protocol version, and job ID
when one is active) and deduplicated (a bounded per-sender window of
recently seen sequence numbers) before any handler ever sees it --
ordinary message-handling code cannot accidentally act on a stale,
unrelated, or replayed message. A message received while waiting for
a *different* specific reply (e.g. an unrelated heartbeat arriving
while waiting for a job-assignment ack) is preserved in an inbox for
the next ordinary receive, not dropped.

The master and worker run their network message loop and (for the
master) interactive command prompt concurrently via CC:Tweaked's
`parallel.waitForAny` (cooperative coroutines sharing the same event
queue copies -- see tweaked.cc/module/parallel.html), since `read()`
blocks for keyboard input and the master must keep processing worker
traffic the whole time.

## Testing

See `tests/`. Everything is run with a local `lua` interpreter (no
Minecraft required) against deterministic mocks:

- `tests/mocks/world.lua` -- in-memory turtle + block-world simulator
  (movement, digging with falling-block cascades, liquids, fuel,
  inventory, placing).
- `tests/mocks/rednet_bus.lua` -- in-memory multi-node rednet
  substitute supporting simulated message loss, duplication, and
  out-of-order/delayed delivery via direct queue injection.
- `tests/mocks/fs_mock.lua` -- `fs` API backed by a real temp
  directory, so persistence tests exercise genuine file I/O.

`tests/test_worker_integration.lua` and
`tests/test_master_integration.lua` stub the *entire* CC:Tweaked
global environment (`turtle`, `rednet`, `peripheral`, `fs`,
`textutils`, `os.*`, `gps`, `sleep`) and run the actual top-level
`worker.lua`/`master.lua` files end-to-end through a full job
lifecycle, using a small test-only coroutine-yield hook (a no-op in
real deployment, gated by a global flag that is always nil outside
tests) to single-step the worker's main loop between scripted network
events. Run `lua tests/run_all.lua` from `quarry/` for a full summary.
