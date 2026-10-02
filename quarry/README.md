# CC:Tweaked Distributed Quarry System

A production-quality, fault-tolerant distributed quarry system for
**CC:Tweaked**: a master controller computer partitions a 3D region
among any number of worker turtles, deploys jobs to them over a
private `rednet` protocol with application-level acknowledgements, and
each worker independently navigates, mines, manages fuel/inventory,
and persists/recovers its state across reboots.

Every non-trivial algorithm here (partitioning, traversal,
navigation, falling-block/liquid handling, message reliability,
crash-safe persistence) is exercised by an automated test suite
running against deterministic mocks -- **no Minecraft instance is
required to verify this system's correctness.**

```
lua tests/run_all.lua      # from the quarry/ directory
# -> TOTAL: 80084 checks, 0 failures across 13 files
```

The master also has a point-and-click GUI (`master/gui.lua`, built on
[Basalt2](https://github.com/Pyroxenium/Basalt2)) covering every step
-- Setup, Deploy, and a live Status dashboard -- for anyone who'd
rather not type commands. It installs automatically alongside the
text UI and launches by default on an Advanced Computer; see "GUI vs.
text UI" below.

## Quick start

1. Read `docs/SETUP.md` for hardware requirements and installation.
2. If the server has the `http` API enabled, install both the master
   and every worker turtle with one command each:
   ```
   wget run https://raw.githubusercontent.com/Ovation-SWE/cc-quarry/main/quarry/bootstrap.lua
   ```
   It auto-detects master vs. worker and reboots when done (see
   `docs/SETUP.md`'s "Installing the master or a worker"). Otherwise,
   fall back to the manual/disk-based steps in the same section.
3. On the master: `new` (configure), `validate`, `partition`,
   `dryrun` (check where to place turtles), physically place each
   worker turtle facing north at its printed starting position, then
   `deploy` and `start`.
4. Watch progress with `status` / `worker <id>` (or the Status tab, in the GUI).

Full command reference: `docs/COMMANDS.md`. Configuration field
reference: `docs/CONFIG_REFERENCE.md`.

## GUI vs. text UI

`master/startup.lua` launches `gui.lua` automatically if `basalt.lua`
got installed (the bootstrap command fetches it for the master role
whenever `http` is enabled) **and** the computer is an Advanced
Computer (`term.isColour()`) -- Basalt needs color and mouse input,
which basic computers don't have. Otherwise it falls back to the text
UI (`master.lua`). You can always launch either one by hand regardless
of what auto-started: run `gui` or `master` at the shell prompt. Both
read/write the same `master_state` session file, so switching between
them mid-job is safe.

## Repository layout

```
quarry/
  bootstrap.lua          One-command installer (wget run), auto-detects master/worker
  manifest.lua           File list bootstrap.lua fetches, kept in sync with lib/worker/master

  lib/                  Shared, unit-tested modules (single source of truth)
    partition.lua       3D partitioning algorithm
    traversal.lua       Deterministic per-worker mining path
    directions.lua      Facing/vector helpers (no native compass exists)
    navigation.lua      Dead-reckoning movement engine
    mining.lua          Safe block clearing: falling blocks, liquids, boundaries
    fuel.lua            Fuel budgeting + auto-refuel
    inventory.lua       Inventory fullness, consolidation, unloading
    gpsnav.lua          GPS reconciliation (never trusted blindly)
    protocol.lua        "quarry.v1" message envelope + validation
    comms.lua           Reliable messaging on rednet (acks, retries, dedup)
    persistence.lua     Crash-safe atomic save/load
    validation.lua      Configuration + job payload validation
    logging.lua         Structured, leveled logging
    state_machine.lua   Generic FSM helper
    errors.lua          Shared failure classification vocabulary

  worker/
    startup.lua          Tiny boot shim (auto-run by CC:Tweaked)
    worker.lua            Worker state machine, wires together lib/*

  master/
    startup.lua          Tiny boot shim; picks gui.lua or master.lua (see README)
    master.lua            Text command UI, partitioning, deployment, monitoring
    gui.lua                Point-and-click UI (Basalt2), same lib/* underneath

  tools/
    provision_disk.lua    Worker deployment station helper (disk drive)

  tests/
    mocks/
      world.lua           In-memory turtle + block-world simulator
      rednet_bus.lua       In-memory multi-node rednet substitute
      fs_mock.lua           Real-filesystem-backed fs API mock
      basalt_mock.lua       Fake Basalt widget tree (see gui.lua's header)
    test_*.lua              13 test files, ~80k assertions total
    run_all.lua              Convenience runner + summary

  config/
    example.config.lua    Fully-commented reference configuration

  docs/
    ARCHITECTURE.md    Design + algorithm explanations (partitioning, traversal,
                       navigation, falling-block/liquid handling, persistence, protocol)
    SETUP.md            Installation, provisioning, network, hardware, fuel, storage
    GPS_SETUP.md         GPS constellation requirements and what this system does with it
    CONFIG_REFERENCE.md  Every configuration field explained
    COMMANDS.md          Master command reference
    RECOVERY.md          Step-by-step recovery for every failure mode below
    LIMITATIONS.md       Honest, specific known limitations
    TROUBLESHOOTING.md   Symptom -> cause -> fix
```

## Target CC:Tweaked version / verified APIs

Verified directly against [tweaked.cc](https://tweaked.cc) during
development (not assumed from memory): `turtle.*` (movement, dig/
inspect/detect/place/drop/suck variants, fuel, inventory, equip --
docs reference additions through v1.116.0, i.e. current stable),
`gps.locate`, `rednet.open/close/send/broadcast/receive/host` (and its
explicit "send does not guarantee receipt" documentation, which drives
this project's whole application-ack design), `fs.*` (open modes,
handle methods, `copy`/`move`/`delete` semantics), `textutils.serialize/
unserialize`, `os.*` (`getComputerID`, `getComputerLabel`, `pullEvent`/
`pullEventRaw`, `startTimer`, `epoch`), `peripheral.find/wrap/getType/
call`, the disk `drive` peripheral (`getMountPath()`, used instead of
assuming a fixed `"disk/"` mount), `parallel.waitForAny/waitForAll`
(cooperative coroutines, confirmed via docs before relying on it for
the master's simultaneous command-prompt + network-message loop), and
CC:Tweaked's `require()`/`package.path` module resolution (confirmed
via the official "Reusing code with require" guide).

**Explicit assumption, documented and load-bearing:** rather than
using CC:Tweaked's dot-notation `require("lib.module")` resolution
(which the docs describe as relative to the *top-level running
program's* directory), every module in `lib/` uses flat
`require("modulename")` calls, with `worker.lua`/`master.lua` each
prepending `"lib/?.lua;"` to `package.path` before requiring anything.
This is a standard, documented Lua/CC:Tweaked mechanism (a mutable
`package.path` string) and was chosen so the exact same `require(...)`
statements run unmodified both in the test suite (via the same
`package.path` trick) and in real deployment -- eliminating a class of
"works in tests, fails on hardware" bugs from day one.

## What makes this "fault-tolerant" concretely

Each claim below is backed by a specific, named test:

- **Partitioning never produces overlaps, gaps, or zero-volume
  jobs**, including 1x1x1, 1x1x100, worker count exceeding a
  dimension, and worker count equal to total volume (one block each).
  `tests/test_partition.lua`, ~79,300 brute-force-verified assertions.
- **The mining path visits every block in a partition exactly once**
  and is resumable from just the current position after a reboot (no
  extra counters to persist). `tests/test_traversal.lua`.
- **Falling-block cascades of arbitrary depth are fully drained**
  without a hardcoded block list, bounded so a genuine obstruction
  never hangs. `tests/test_mining.lua`.
- **Liquids never trap or destroy the turtle**; lava is never passed
  through regardless of configuration. `tests/test_mining.lua`.
- **A worker never digs outside its assigned partition**, even when
  physically encountering a neighbor's cascade. `tests/test_mining.lua`.
- **`rednet.send()` "success" is never treated as delivery
  confirmation** -- every message requiring guaranteed delivery is
  application-acked with bounded retry/backoff; duplicates, stale
  jobs, and unrelated in-flight messages are all handled correctly.
  `tests/test_protocol.lua`.
- **State survives a simulated crash mid-write**, including recovery
  from a corrupted primary via automatic backup fallback, against a
  real filesystem. `tests/test_persistence.lua`.
- **GPS is never trusted blindly**; a mismatch stops the worker safely
  rather than guessing. `tests/test_gpsnav.lua`.
- **The full worker and master programs run end-to-end** (register ->
  validate config -> partition -> deploy -> start -> mine -> unload
  logic -> complete) against a stubbed CC:Tweaked environment, not
  just their component libraries in isolation.
  `tests/test_worker_integration.lua`, `tests/test_master_integration.lua`.

See `docs/ARCHITECTURE.md` for the full design rationale behind each
of these, and `docs/LIMITATIONS.md` for an equally specific accounting
of what this system does **not** yet handle automatically (facing
verification without GPS, obstacle routing, mid-job worker
replacement, and others) -- discovered in several cases by the test
suite itself catching real bugs during development, documented rather
than papered over.
