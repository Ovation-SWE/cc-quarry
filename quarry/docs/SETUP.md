# Setup Guide

## Target version

Written and verified against current **CC:Tweaked** documentation at
[tweaked.cc](https://tweaked.cc) (turtle API additions through
v1.116.0 are referenced there, i.e. the current stable 1.20.x/1.21.x
line). If your server runs a materially older CC:Tweaked, check
`docs/LIMITATIONS.md` for version-sensitive assumptions before
deploying.

## Required hardware

**Master:** any Computer (does not need to be a turtle, does not need
to move). Requires:
- A wireless modem (equip via crafting into an Advanced/Wireless Modem
  block placed adjacent to the computer, or peripheral-attached).
- Optionally a disk drive peripheral, if this computer will double as
  the worker-deployment station (see "Worker provisioning" below).

**Each worker:** a Mining Turtle (has a built-in pickaxe) or a regular
turtle with a pickaxe equipped via `turtle.equipLeft()`/`equipRight()`
(or crafted in). Requires:
- A wireless modem equipped to the left or right side
  (`equipLeft`/`equipRight`, or crafted with the turtle).
- Enough fuel (see "Fuel" below).
- Free inventory slots (leave at least a couple of slots unfilled at
  deployment time; the whole 16-slot inventory is usable by default,
  or reserve specific slots via `reservedSlots` in configuration for
  a fuel-item stack you never want auto-unloaded).

**GPS (optional but recommended):** see `docs/GPS_SETUP.md`. The
system works without GPS (pure dead reckoning), but cannot detect
operator misplacement or physical knockback/desync without it -- see
`docs/LIMITATIONS.md`.

**Storage:** any inventory block (chest, barrel, shulker box, hopper,
modded equivalent) placed adjacent to each worker's configured
`unloadPoint`, oriented so the configured `direction` (`forward` /
`up` / `down`) actually faces it. `down` or `up` is recommended --
see `docs/CONFIG_REFERENCE.md` for why `forward` is more fragile.

## Fuel

Any combustible item CC:Tweaked's `turtle.refuel()` accepts works;
this project never assumes a specific one. Coal/charcoal (80 fuel
each) is the common choice. Reserve a slot (or several) of fuel in
each worker's inventory and either mark it via `reservedSlots` in the
job configuration (so it's never auto-unloaded) or rely on
`autoRefuel()` topping off from any fuel item found in any slot --
your call based on whether you want workers to also pick up
naturally-mined coal as fuel.

## Installing the master or a worker (fast path: `http` API enabled)

If your server has the CC:Tweaked `http` API enabled (check with your
admin if unsure -- it's off by default on many servers), installation
on **any** computer or turtle is a single command:

```
wget run https://raw.githubusercontent.com/Ovation-SWE/cc-quarry/main/quarry/bootstrap.lua
```

This fetches `manifest.lua`, then every file it lists, from GitHub and
writes them to the right place. It auto-detects role: if the `turtle`
API is present it installs the worker (`worker.lua`, `worker/startup.lua`
as `startup.lua`, and `lib/`); otherwise it installs the master the same
way. To force a role (e.g. running the master software on a turtle),
pass it explicitly:

```
wget run https://raw.githubusercontent.com/Ovation-SWE/cc-quarry/main/quarry/bootstrap.lua master
```

It finishes by rebooting the computer, which runs the freshly-installed
`startup.lua` automatically -- a worker boots straight into
`WAITING_FOR_JOB`/`REGISTERING` and starts broadcasting a registration
announcement; the master attempts to recover any previously saved
session. Run this once per worker turtle (no provisioning station or
floppy disks needed) and once for the master, then skip straight to
"Placing a worker for a new job" below.

**If `http` is disabled**, fall back to one of these manual paths
instead:

### Installing the master manually

The master needs a full copy of this repository's `lib/`,
`master/master.lua`, and `master/startup.lua` **flattened** onto its
own root filesystem:

```
<master computer root>/
  startup.lua       (from master/startup.lua)
  master.lua        (from master/master.lua)
  lib/*.lua         (from lib/)
```

This is a one-time, single-computer setup, so however you can get
files onto it is fine. In rough order of convenience:

1. **Direct world-save file access** (if you can reach the server's
   files): CC:Tweaked computers persist their filesystem as ordinary
   files under the world save's `computer/<id>/` directory. Copying
   files there directly (server stopped, or many servers tolerate it
   live) is the most reliable method for a from-scratch setup.
2. **Manual entry via the in-game `edit` program**, for a small number
   of files -- tedious for a full repository, but always available as
   a last resort with zero external dependencies.
3. **A disk drive**, if you already have *any* computer with the files
   on it (e.g. you set up one worker's `lib/` first) -- `fs.copy` a
   directory onto a floppy and carry it over, same mechanism as
   worker provisioning below.

Once the files are in place, boot the computer; `startup.lua` runs
`master.lua` automatically. It will attempt to recover any previously
saved session automatically.

### Worker provisioning manually (the part that needs to scale)

**Do not** try to remotely push files onto worker turtles over the
network -- the master has no supported way to write arbitrary files
into a turtle it doesn't already control, and this project
deliberately does not pretend otherwise. Instead:

1. Get the master (or any other computer with the full repository, a
   dedicated "provisioning station") a disk drive peripheral attached
   (any side).
2. Insert a floppy disk (reusable across many turtles) and run:
   ```
   tools/provision_disk
   ```
   This copies `lib/`, `worker/worker.lua`, and `worker/startup.lua`
   onto the disk (see `tools/provision_disk.lua`), along with a small
   `install.lua` helper.
3. For each new worker turtle: attach a disk drive to it (or place it
   adjacent to one on a wired network), insert the floppy, and run:
   ```
   disk/install
   ```
   This copies everything from the disk onto the turtle's own root
   filesystem as `startup.lua`, `worker.lua`, and `lib/`.
4. Reboot the turtle. It boots into `WAITING_FOR_JOB`/`REGISTERING`
   state, broadcasting a registration announcement, and does nothing
   destructive until the master deploys and starts a job for it.
5. Repeat step 3-4 for every worker, reusing the same disk.

This cleanly separates **provisioning** (steps 1-4, one-time, physical
media, no network trust required) from **deployment** (assigning a
specific partition to a specific registered worker, done entirely over
rednet with application-level acknowledgement -- see
`docs/COMMANDS.md`'s `deploy`/`start`).

## Network setup

All communication uses `rednet` over wireless modems on the private
application protocol `quarry.v1` (`lib/protocol.lua`). Every worker
and the master must have a wireless modem equipped/attached and within
mutual wireless range (or relayed via `rednet.host`-style repeaters,
which CC:Tweaked supports transparently at the rednet layer -- no
special configuration needed here beyond normal wireless range
planning). There is no separate "network setup" step beyond having
modems equipped; `rednet.open()` is called automatically by both
`worker.lua` and `master.lua` on startup, auto-detecting the modem via
`peripheral.find("modem", ...)`.

## Placing a worker for a new job

Before running `deploy`+`start` in the master (see
`docs/COMMANDS.md`), physically place each worker turtle at (or as
close as physically possible to) the position the `partition` command
will assign it as that worker's `starting_position`, **facing north**
(Minecraft compass north, -Z). The system has no compass and, without
GPS, cannot detect a misplacement -- see `docs/LIMITATIONS.md`. Run
`dryrun` after `partition` to see exactly where each worker needs to
be placed before committing to `deploy`.
