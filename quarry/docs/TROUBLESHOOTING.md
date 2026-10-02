# Troubleshooting Guide

## The GUI doesn't launch; I just get the text UI (`quarry>` prompt)

`startup.lua` only launches `gui.lua` when **both** `basalt.lua` and
`gui.lua` exist on the computer **and** `term.isColour()` is true.
Check which is missing:
1. `ls` at the root -- if `basalt.lua` is absent, the bootstrap
   install's Basalt fetch likely failed (it prints a warning and
   continues rather than aborting the whole install -- re-run
   `wget run https://raw.githubusercontent.com/Ovation-SWE/cc-quarry/main/quarry/bootstrap.lua`
   and watch for a "Basalt2 fetch failed" line).
2. If both files exist, this is a basic Computer, not an Advanced
   Computer -- Basalt needs color + mouse, which basic Computers don't
   have. Either accept the text UI, or move the setup to an Advanced
   Computer.
3. You can always launch either UI manually regardless of what
   auto-started: run `gui` or `master` at the shell prompt.

## The GUI launches but a widget looks wrong or a button does nothing

This project's test suite verifies `gui.lua`'s *logic* against a fake
widget tree (`tests/mocks/basalt_mock.lua`), not Basalt2's real
rendering -- see `docs/LIMITATIONS.md`'s GUI entry. If something looks
or behaves wrong in-game, it's most likely a mismatch between the
Basalt2 API version actually installed and what `gui.lua` assumes
(basalt2.5; see `master/gui.lua`'s header comment for why that
specific branch matters -- Basalt2's `main` branch has a different,
incompatible API). As an immediate workaround, run `master` instead of
`gui` to fall back to the text UI, which exercises the exact same
`lib/*.lua` logic without depending on Basalt at all.

## `worker.lua`/`master.lua` exited with "attempt to index global 'package' (a nil value)"

Fixed as of this version of `startup.lua` -- if you're seeing this,
you're running a `startup.lua` from before the fix and need to
re-install it (re-run `bootstrap.lua`, or re-copy `worker/startup.lua`/
`master/startup.lua` manually). The cause: CC:Tweaked's `dofile()`
always loads the target file with the raw global environment, which
does not have `require`/`package` on it -- those only exist in the
fresh per-program environment the shell builds for each program it
runs via `shell.run`. `startup.lua` now uses `shell.run("worker.lua")`/
`shell.run("master.lua")` instead of `dofile(...)` for exactly this
reason.

## "FATAL: no wireless modem found" on boot

Both `worker.lua` and `master.lua` require a wireless modem, found via
`peripheral.find("modem", isWireless)`. Attach one (craft it into the
turtle/computer, or place it adjacent and it's still detected as a
peripheral) and reboot. A wired-only modem will not satisfy this
check on its own (the fallback `peripheral.find("modem")` will accept
it, but rednet range will be limited to the wired network).

## Worker never registers / master never sees it

1. Confirm both computers have a modem attached and are within
   wireless range of each other (or a working repeater chain).
2. Check the worker's `log.txt` for `"worker starting"` -- if that
   line is missing, `startup.lua` itself may have failed; re-check
   file placement (`docs/SETUP.md`).
3. A worker broadcasts a `register` message roughly every few seconds
   while waiting; give it a little time before assuming it's stuck.

## `deploy` says "Only N worker(s) registered, but M partition(s) computed"

The master refuses to deploy a partial job. Either register more
workers (power them on, confirm they're in range) or re-run `new`/
`partition` with a smaller `workerCount`.

## A worker is stuck in `ASSIGNED` and never starts mining

This is correct if you haven't run `start` yet -- `deploy` and `start`
are deliberately separate, confirmed steps. If you *have* run `start`,
check `worker <id>` on the master: if its status is still `ASSIGNED`,
the `start` message may not have been acknowledged (check wireless
range); re-run `start`, which is safe to repeat.

## A worker is stuck in `ERROR`

See `docs/RECOVERY.md`'s "Worker stuck in ERROR" and "GPS position
mismatch" sections -- `worker <id>` on the master shows the exact
`lastError` recorded, which tells you which case you're in.

## A worker is mining in the wrong physical location

Almost always an operator-placement mismatch (see
`docs/LIMITATIONS.md`'s "Facing/placement trust" section) that GPS
would have caught but didn't (either GPS isn't set up, or the mismatch
happened before the first reconciliation check ran). Physically verify
the turtle's actual coordinate against its job's `starting_position`
(`worker <id>` shows both the job and last reported position). There
is no automatic fix once mining has started from the wrong spot --
`estop` that worker and reconsider whether its partition needs to be
redone.

## Worker inventory keeps filling up / can't unload

Check the reported error via `worker <id>`. Common causes: no
inventory block present at the configured `unloadPoint` (the worker
reports `CONFIGURATION_ERROR: no_storage_present`), the storage is
full (`RESOURCE_EXHAUSTED: storage_full`), or the configured
`direction` doesn't actually face the storage (see
`docs/CONFIG_REFERENCE.md`'s note on `forward` vs `down`/`up`). Fix the
physical setup, then `resume`.

## Worker ran out of fuel / can't refuel

`worker <id>` shows current fuel and last error. If
`RESOURCE_EXHAUSTED: insufficient_fuel_items`, no combustible item was
found in any of its configured `refuelSlots` (or any slot, if none
configured). Physically deliver fuel to the turtle (it will need to be
retrieved -- this system does not implement fuel delivery), or
increase pre-loaded fuel/reserve for future deployments.

## Progress percentage looks wrong

`status`/`worker <id>`'s progress comes directly from
`lib/traversal.lua:indexOf()` -- the worker's exact position within
its deterministic path, not an estimate. If it looks wrong, check
whether the worker actually is where its last heartbeat says (heartbeat
data can be a few seconds stale; `worker <id>` shows "last seen").

## Tests fail / I changed `lib/*.lua` and want to re-verify

Run `lua tests/run_all.lua` from the `quarry/` directory (requires a
local Lua 5.1+ interpreter -- no Minecraft needed). Each `test_*.lua`
file is independent and can be run alone (`lua tests/test_mining.lua`,
etc.) for faster iteration on one subsystem.

## "attempt to call a nil value" / similar Lua errors on a worker/master

This means a required global (`turtle`, `rednet`, `peripheral`, `fs`,
`textutils`, `gps`) wasn't available in the environment `worker.lua`/
`master.lua` ran in -- almost always means it's running on the wrong
kind of computer (e.g. `worker.lua` on a non-turtle computer has no
`turtle` global) or a required peripheral genuinely isn't attached.
Check `docs/SETUP.md`'s hardware requirements for that role.
