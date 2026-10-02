# Recovery Procedures

## Worker reboot / crash

Automatic. On boot, `worker/startup.lua` runs `worker.lua`, which
loads persisted state (`lib/persistence.lua`) and resumes into
**exactly the state it was in** when last checkpointed -- not a
blanket restart. If it was mid-return-trip (inventory or fuel), it
resumes that specific trip's phase (traveling out / acting / traveling
back). If it was waiting for `start`, it goes back to waiting. If
persisted state is missing or corrupt beyond the automatic `.bak`
fallback, it starts fresh (`REGISTERING`) -- it will not guess at a
job it can't verify.

On every resume-from-reboot, the worker first attempts GPS
reconciliation (if GPS is available) before doing anything else. If
that fails (mismatch) or dead reckoning is otherwise deemed
untrustworthy, it goes to `ERROR` and reports the specific problem to
the master rather than continuing to mine from an unverified position.

## Master reboot / crash

Automatic. `master.lua` unconditionally attempts to load its last
saved session (`master_state`) on startup, restoring configuration,
job ID, partitions, worker registry, and deployment/start status.
Workers are entirely unaffected by a master restart -- they continue
operating from their own persisted state and simply resume sending
heartbeats, which the recovered master will start picking up again
immediately. **A worker never accidentally treats a message from a
newly-restarted master as belonging to a different/new job** -- every
message still carries the same `job_id`, checked via
`lib/protocol.lua:validate()`.

## Worker went unresponsive (missed heartbeats)

The master does not declare a worker dead after one missed heartbeat.
`HEARTBEAT_TIMEOUT` (15s) must elapse with no message before a miss is
counted, and `HEARTBEAT_MISSES_DEAD` (4) consecutive misses are
required before a worker is marked `UNRESPONSIVE` in `status`/`worker
<id>`. This is usually temporary wireless range/interference; if the
worker later sends a heartbeat again, its status updates normally
(there's no separate "un-mark dead" step needed).

If a worker is genuinely gone (broken, unloaded chunk, destroyed),
its partition simply never finishes; `status`'s overall progress
percentage will reflect that. Re-partitioning to exclude it requires a
fresh `new`/`partition`/`deploy` cycle for the remaining volume, since
partitions aren't currently reassignable mid-job (see
`docs/LIMITATIONS.md`).

## Worker stuck in `ERROR` (blocked cell)

A worker enters `ERROR` when it cannot clear a cell after bounded
retries (a protected block, or a liquid under `STOP_AT_LIQUID`) or
when GPS reconciliation fails. It reports the exact coordinate and
reason via its status payload (`worker <id>` on the master). To
recover:

1. Physically investigate the reported coordinate (or reconsider the
   job's `liquidPolicy`/`ignoredBlocks` configuration for future
   jobs).
2. If the obstruction is now resolved (you manually cleared it, or it
   was a transient GPS blip), send `resume` -- the worker re-attempts
   the *exact same* next cell it was blocked on. Nothing is skipped or
   guessed.
3. If the obstruction cannot be resolved, `cancel` the job for that
   worker's slot and accept the partition as partially complete, or
   `estop` and redeploy a corrected configuration.

**This system deliberately does not implement "route around the
obstacle"** pathfinding -- see `docs/LIMITATIONS.md`. A stuck worker
always stops safely and waits rather than attempting to reroute
through unvisited territory (which could cross into a neighboring
worker's partition or leave gaps in coverage).

## GPS position mismatch

The affected worker is in `ERROR` with `lastError` starting
`position_untrusted`. This means dead reckoning and a GPS fix
disagreed -- most likely the turtle was physically moved (knockback,
piston, manual pickup/replacement) since it last trusted its position.

There is no automatic recovery from this by design (the system will
never guess which source -- dead reckoning or GPS -- is correct).
Recovery requires operator judgment:

1. Physically verify the turtle's actual coordinate (F3 debug screen,
   or `gps locate` run from an adjacent computer).
2. If it matches the GPS fix reported in the worker's error, the
   turtle really was moved -- decide whether its current position is
   still usefully inside its partition. If not, this worker's job
   should be cancelled and its remaining volume redistributed in a
   future job.
3. There is currently no "force-trust GPS and resume" command exposed
   through the master UI (a deliberate omission -- see
   `docs/LIMITATIONS.md`); resolving this today requires cancelling
   and redeploying that worker's slot.

## Emergency stop

`estop` is intentionally **not** liftable via `resume` -- only a brand
new job assignment (a different `job_id`) can bring an estopped worker
back to life. This is a deliberate one-way door: an emergency stop
should mean "something is wrong enough that a human should re-evaluate
the whole plan," not "pause and immediately continue on the same
assumptions."

## Storage full / missing during unload

The worker stops (`ERROR`), preserves its full inventory (nothing is
lost or dropped on the ground), and reports the problem. Fix the
storage (empty the chest, or place one if missing/destroyed), then
`resume` -- the worker re-attempts the unload from where it left off
(it tracks which return-trip phase it was in: traveling out / acting /
traveling back, so it won't repeat a leg it already completed).

## Reboot during a state save

Cannot corrupt the only copy of state (`lib/persistence.lua`'s
tmp-then-backup-then-move sequence, verified in
`tests/test_persistence.lua` against a simulated interrupted write).
Worst case, the worker resumes from its *previous* checkpoint (loses
progress since the last completed block/action, never more).
