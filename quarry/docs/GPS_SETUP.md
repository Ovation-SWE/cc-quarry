# GPS Setup

GPS is **optional**. Without it, workers rely entirely on dead
reckoning (tracking position from a known starting point plus every
successful move) and cannot detect operator misplacement, physical
knockback, or desync -- see `docs/LIMITATIONS.md`. With it, workers
opportunistically verify their tracked position and refuse to continue
if it disagrees with reality (`lib/gpsnav.lua`).

## What CC:Tweaked's GPS actually requires

Per [tweaked.cc/module/gps.html](https://tweaked.cc/module/gps.html),
`gps.locate()` determines position by trilaterating distance
measurements from wireless-modem messages exchanged with other
computers ("GPS hosts") that already know their own position. This
system does **not** and cannot set up that infrastructure for you --
it is standard CC:Tweaked infrastructure you (the operator) provide,
the same as any other CC:Tweaked GPS-dependent program would need.

In practice, per CC:Tweaked's own GPS setup guide, you need **at least
four** fixed computers with wireless modems, at precisely known
coordinates, not all coplanar (i.e. not all at the same Y, and not
collinear), each running a `gps host <x> <y> <z>` program (the stock
CC:Tweaked `gps` program supports a `host` subcommand) advertising its
own known position on the reserved GPS channel. These are normally
placed high above the build (e.g. on tall pillars) so their wireless
range covers the whole quarry area.

## Verifying it works

From any computer with a wireless modem in range of your GPS hosts,
run the stock `gps locate` program. If it reports a plausible
coordinate, your constellation is working and this system's
`gps.locate()` calls (via `lib/gpsnav.lua`) will succeed under the
same conditions.

## What this system does with it

- On GPS reconciliation (`lib/gpsnav.lua:reconcile()`, called
  periodically during mining and before/after long navigation legs):
  if no fix is obtainable, this is treated as normal -- the worker
  simply continues on dead reckoning. If a fix *is* obtained and
  disagrees with the tracked position, the worker immediately marks
  its position untrusted and stops mining/moving until the operator
  resolves it (see `docs/RECOVERY.md`).
- Facing is never reported by GPS (CC:Tweaked has no compass API for
  turtles at all). `lib/gpsnav.lua:calibrateFacing()` can *infer*
  facing by taking a fix, performing one controlled forward move, and
  observing the resulting delta -- this is available as a diagnostic/
  recovery tool but is not required for normal operation as long as
  the operator correctly faces each turtle north before deployment.

## If you don't have GPS

Everything still works. Document your worker starting positions
carefully (the master's `dryrun` command prints them), physically
place each turtle exactly there facing north, and treat any unusual
worker behavior (mining in what looks like the wrong place) as a
signal to physically check that turtle's actual position against its
job's `starting_position` -- see `docs/TROUBLESHOOTING.md`.
