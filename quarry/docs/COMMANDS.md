# Master Command Reference

Run on the master computer (`master.lua`, auto-started by
`startup.lua`). Type `help` at the `quarry>` prompt for a short
summary at any time.

## GUI equivalent

Everything below also exists as a point-and-click GUI
(`master/gui.lua`, built on [Basalt2](https://github.com/Pyroxenium/Basalt2)),
which `startup.lua` launches automatically on an Advanced Computer
with `basalt.lua` installed -- see README.md's "GUI vs. text UI" and
`docs/SETUP.md`. The table below maps each CLI command to its GUI
location:

| Command | GUI location |
|---|---|
| `new`, `show` | Setup tab: form fields, pre-filled from the last saved config |
| `validate` | Setup tab: Validate button |
| `partition` | Setup tab: Partition button |
| `dryrun` | Setup tab: Dry Run button |
| `deploy`, `start` | Deploy tab: Deploy / Start buttons (confirm modal instead of typing `CONFIRM`) |
| `pause`, `resume` | Status tab: Pause / Resume buttons |
| `cancel`, `estop` | Status tab: Cancel / ESTOP buttons (confirm modal) |
| `status`, `worker <id>` | Status tab: live table; click a row for that worker's detail |
| `save`, `recover`/`load` | Automatic: every GUI action that changes state saves immediately; session is reloaded on launch |

| Command | Effect |
|---|---|
| `new` | Interactive wizard to configure a new quarry. Overwrites any in-progress (not yet deployed) draft configuration and clears any previously computed partitions. |
| `show` | Display the current configuration and active job ID, if any. |
| `validate` | Run every check in `lib/validation.lua:validateConfig()` against the current configuration and currently registered workers; prints every problem found (never stops at the first one). |
| `partition` | Compute the partition layout (`lib/partition.lua`) for the current configuration and display it. Safe to run repeatedly; does not touch any turtle. |
| `dryrun` | Simulate the job: partition layout, each worker's starting position, and a rough minimum-movement/fuel estimate -- without breaking any blocks or moving any turtle. Use this before `deploy` to know exactly where to place each turtle. |
| `deploy` | **Requires typing `CONFIRM`.** Assigns each computed partition to a registered worker (in partition order) and sends a `job_assign` message, retrying with backoff until each worker acknowledges or the attempt is exhausted. Does **not** start mining -- workers wait in `ASSIGNED` until `start`. |
| `start` | **Requires typing `CONFIRM`.** Sends the `start` command to every successfully assigned worker, which begins their navigation-then-mining sequence. |
| `pause` / `stop` | Sends `pause` to every worker with an active assignment. Resumable via `resume`. |
| `resume` | Sends `resume` to every worker; workers in `PAUSED` or (operator-acknowledged) `ERROR` return to `MINING`. |
| `cancel` | **Requires typing `CONFIRM`.** Permanently cancels the active job for every worker (they report `COMPLETED` with a cancelled flag and stop). Clears the master's deployed/started flags. |
| `estop` | **Requires typing `CONFIRM`.** Emergency-stops every worker immediately. Unlike `pause`, this is **not** liftable via `resume` -- an estopped worker only accepts a brand-new job assignment (a different `job_id`), by design (see `docs/RECOVERY.md`). |
| `status` | Live progress table: per-worker state, percentage complete (from `lib/traversal.lua`'s position-based progress calculation, not a guess), fuel, inventory utilization, plus overall volume-weighted progress. |
| `worker <id>` | Detailed view of a single worker: status, last known position/fuel/inventory/progress/last error, heartbeat recency. |
| `recover` / `load` | Reload the master's last saved session from disk (also happens automatically on startup). |
| `save` | Persist the current session immediately (also happens automatically after every structural change: registration, deploy, start, pause/resume, cancel, worker completion). |
| `quit` / `exit` | Exit the master's interactive program. **Workers are unaffected and keep running/mining independently** -- the master is not in the critical path of an in-progress job, only of issuing new commands. |

## Safety notes

- `start`, `cancel`, and `estop` all require typing the literal word
  `CONFIRM` in response to a prompt describing exactly what's about to
  happen. There is no way to trigger them accidentally with a single
  keystroke or a scripted/piped `yes`.
- `deploy` refuses to run if fewer workers are registered than
  partitions computed -- it will not silently deploy a partial job.
- No command partially applies configuration: `validate` reports every
  problem before you ever reach `deploy`, and `deploy` itself
  re-checks worker availability at the moment it runs.
