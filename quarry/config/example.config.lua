-- Example/reference quarry configuration.
--
-- This is NOT loaded automatically by master.lua -- the master's
-- `new` command builds this same structure interactively (see
-- docs/COMMANDS.md). This file exists purely as a documented
-- reference for every field, useful when scripting configurations or
-- just understanding what `new` is asking for and why.
--
-- See docs/CONFIG_REFERENCE.md for the full field-by-field reference.

return {
    -- Quarry bounds, inclusive on every axis. Any integers, including
    -- negative and crossing zero, are supported. minX<=maxX etc.
    minX = -32, maxX = 31,
    minY = 5, maxY = 60,
    minZ = -32, maxZ = 31,

    -- How many workers to partition the quarry among. If this exceeds
    -- the number of registered workers, `deploy` will refuse to run
    -- until either more workers register or this is lowered. If it
    -- exceeds the quarry's total block volume, the excess workers are
    -- simply left idle (reported by `partition`) rather than being
    -- given a zero-volume job.
    workerCount = 4,

    -- Fuel (in movement-blocks) that must always remain in reserve,
    -- on top of whatever a worker needs to complete its current
    -- action and return to the unload point. Set this comfortably
    -- above your `dryrun` estimate.
    fuelReserve = 500,

    -- Fraction (0, 1] of usable inventory slots that triggers an
    -- automatic trip to the unload point. 0.9 means "go unload once
    -- 90% of slots hold something".
    inventoryReturnThreshold = 0.9,

    -- STOP_AT_LIQUID (safest, default): never dig into or move through
    --   water/lava; the affected cell is reported as blocked.
    -- BLOCK_LIQUID: seal the liquid with a block drawn from the
    --   worker's inventory (see ignoredBlocks/sealBlockSlot notes in
    --   docs/CONFIG_REFERENCE.md) instead of digging through it.
    -- ALLOW_LIQUID: treat *water only* as passable and continue
    --   (lava is never allowed through regardless of this setting,
    --   for the turtle's own safety).
    liquidPolicy = "STOP_AT_LIQUID",

    -- Blocks that must never be broken, treated as obstacles rather
    -- than retried. Use modern namespaced block names.
    ignoredBlocks = {
        ["minecraft:bedrock"] = true,
    },

    -- Where workers travel to unload their inventory / top up fuel.
    -- `direction` is relative to the worker's facing when it arrives:
    -- "down" or "up" are recommended (independent of final facing);
    -- "forward" requires the storage to be reachable from whatever
    -- direction the worker's last horizontal move happened to leave
    -- it facing -- see docs/CONFIG_REFERENCE.md.
    unloadPoint = { x = 0, y = 64, z = 0, direction = "down" },

    -- Optional. A single shared staging-pad coordinate every worker
    -- can be placed at instead of its own exact starting_position --
    -- see docs/SETUP.md's depot workflow. `facing` is the 0-3 cardinal
    -- convention (0=north); the depot chest must be directly in front
    -- of the turtle at that facing. Omit this field entirely (nil) to
    -- keep today's default: every worker must be placed exactly at
    -- its own starting_position, facing north.
    depotPoint = nil, -- e.g. { x = 0, y = 64, z = 0, facing = 0 }

    -- Whether to run a second pass after the main excavation to catch
    -- any stragglers (e.g. blocks that fell into an already-visited
    -- cell from a neighboring partition after the worker passed).
    cleanupPass = false,

    -- Must match lib/protocol.lua's protocol.VERSION on both the
    -- master and every worker. A mismatch is a configuration error,
    -- not something to silently work around.
    protocolVersion = 1,
}
