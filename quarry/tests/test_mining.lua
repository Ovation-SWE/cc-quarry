-- Tests for lib/mining.lua: falling-block cascades, liquids,
-- protected blocks, and partition-boundary enforcement.
-- Run with: lua tests/test_mining.lua   (from the quarry/ directory)

package.path = "./lib/?.lua;./tests/mocks/?.lua;" .. package.path
local navigation = require("navigation")
local directions = require("directions")
local mining = require("mining")
local errors = require("errors")
local World = require("world")

local failures = 0
local checks = 0
local function check(cond, msg)
    checks = checks + 1
    if not cond then
        failures = failures + 1
        print("FAIL: " .. msg)
    end
end

local function noSleep() end

local function makeRig(opts)
    opts = opts or {}
    local w = World.new({ x = 0, y = 0, z = 0, facing = directions.SOUTH })
    local nav = navigation.new({ turtle = w:turtleAPI(), sleep = noSleep },
        { x = 0, y = 0, z = 0, facing = directions.SOUTH })
    local m = mining.new({
        turtle = w:turtleAPI(),
        nav = nav,
        sleep = noSleep,
        partition = opts.partition,
        ignoredBlocks = opts.ignoredBlocks,
        liquidPolicy = opts.liquidPolicy,
        sealBlockSlot = opts.sealBlockSlot,
        maxClearAttempts = opts.maxClearAttempts,
    })
    return w, nav, m
end

-- 1. Gravel cascade: a stack of 4 gravel blocks in front, all must be cleared
do
    local w, _, m = makeRig({ maxClearAttempts = 10 })
    -- Turtle faces south (+z). Front cell is (0,0,1); stack gravel above it too.
    w:setBlock(0, 0, 1, "minecraft:gravel")
    w:setBlock(0, 1, 1, "minecraft:gravel")
    w:setBlock(0, 2, 1, "minecraft:gravel")
    w:setBlock(0, 3, 1, "minecraft:gravel")
    local ok, err = m:clearFront()
    check(ok, "gravel cascade (4 deep) fully cleared: " .. tostring(err))
    check(w:getBlock(0, 0, 1) == nil, "front cell empty after cascade")
    check(w:getBlock(0, 1, 1) == nil, "cascade drained all the way up (y+1 empty)")
end

-- 2. Sand cascade above a digDown target
do
    local w, _, m = makeRig({ maxClearAttempts = 10 })
    w:setBlock(0, -1, 0, "minecraft:sand")
    w:setBlock(0, 0, 0, "minecraft:sand") -- above the down-target (falls into it)
    local ok, err = m:clearDown()
    check(ok, "sand cascade below turtle fully cleared: " .. tostring(err))
    check(w:getBlock(0, -1, 0) == nil, "down cell empty after sand cascade")
end

-- 3. Unbreakable/protected block: never touched, classified BLOCKED, no infinite retry
do
    local w, _, m = makeRig({ maxClearAttempts = 5 })
    w:setBlock(0, 0, 1, "minecraft:bedrock", { protected = true })
    local ok, err = m:clearFront()
    check(ok == false, "protected block is never cleared")
    check(errors.kindOf(err) == errors.BLOCKED, "protected block classified BLOCKED")
    check(w:getBlock(0, 0, 1) ~= nil, "protected block still present (never dug)")
end

-- 3b. Explicit ignoredBlocks configuration is honored even for normally-diggable blocks
do
    local w, _, m = makeRig({ maxClearAttempts = 5, ignoredBlocks = { ["minecraft:chest"] = true } })
    w:setBlock(0, 0, 1, "minecraft:chest")
    local ok, err = m:clearFront()
    check(ok == false, "explicitly ignored block is not dug")
    check(errors.kindOf(err) == errors.BLOCKED, "ignored block classified BLOCKED")
    check(w:getBlock(0, 0, 1) ~= nil, "ignored block left in place")
end

-- 4. A dig() that keeps failing (simulated permanently-unbreakable, non-protected)
--    still terminates within maxClearAttempts rather than looping forever.
do
    local w = World.new({ x = 0, y = 0, z = 0, facing = directions.SOUTH })
    local nav = navigation.new({ turtle = w:turtleAPI(), sleep = noSleep },
        { x = 0, y = 0, z = 0, facing = directions.SOUTH })
    w:setBlock(0, 0, 1, "minecraft:stone")
    local digCalls = 0
    local turtleApi = w:turtleAPI()
    turtleApi.dig = function() digCalls = digCalls + 1; return false, "simulated persistent failure" end
    local m = mining.new({ turtle = turtleApi, nav = nav, sleep = noSleep, maxClearAttempts = 5 })
    local ok, err = m:clearFront()
    check(ok == false, "a dig() that always fails eventually gives up rather than hanging")
    check(digCalls == 5, "dig() retried exactly maxClearAttempts (5) times, not indefinitely")
    check(errors.kindOf(err) == errors.BLOCKED, "persistent dig failure classified BLOCKED")
end

-- 5. Partition boundary: refuses to dig outside assigned partition
do
    local partition = {
        partition_min_x = -5, partition_max_x = 5,
        partition_min_y = -5, partition_max_y = 5,
        partition_min_z = -5, partition_max_z = 0, -- turtle at z=0 facing south; front cell z=1 is OUTSIDE
    }
    local w, _, m = makeRig({ partition = partition })
    w:setBlock(0, 0, 1, "minecraft:stone")
    local ok, err = m:clearFront()
    check(ok == false, "digging outside partition is refused")
    check(errors.kindOf(err) == errors.CONFIGURATION_ERROR, "out-of-partition dig classified CONFIGURATION_ERROR")
    check(w:getBlock(0, 0, 1) ~= nil, "block outside partition left untouched")
end

-- 6. Partition boundary: digging inside the partition is allowed
do
    local partition = {
        partition_min_x = -5, partition_max_x = 5,
        partition_min_y = -5, partition_max_y = 5,
        partition_min_z = -5, partition_max_z = 5,
    }
    local w, _, m = makeRig({ partition = partition })
    w:setBlock(0, 0, 1, "minecraft:stone")
    local ok, err = m:clearFront()
    check(ok, "digging inside partition succeeds: " .. tostring(err))
end

-- 7. Liquid default policy (STOP_AT_LIQUID): never digs/places, reports blocked
do
    local w, _, m = makeRig({}) -- default policy
    w:setBlock(0, 0, 1, "minecraft:water")
    local ok, err = m:clearFront()
    check(ok == false, "STOP_AT_LIQUID refuses to proceed through water")
    check(errors.kindOf(err) == errors.BLOCKED, "liquid-stop classified BLOCKED")
    check(w:getBlock(0, 0, 1).name == "minecraft:water", "water left completely untouched")
end

-- 8. Liquid BLOCK_LIQUID policy: seals with a configured block
do
    local w, _, m = makeRig({ liquidPolicy = "BLOCK_LIQUID", sealBlockSlot = 1 })
    w:setInventorySlot(1, "minecraft:cobblestone", 64)
    w:setBlock(0, 0, 1, "minecraft:water")
    local ok, err = m:clearFront()
    check(ok, "BLOCK_LIQUID seals water successfully: " .. tostring(err))
    check(w:getBlock(0, 0, 1).name == "minecraft:cobblestone", "water cell now sealed with cobblestone")
end

-- 9. Liquid ALLOW_LIQUID policy: passes through water without touching it
do
    local w, _, m = makeRig({ liquidPolicy = "ALLOW_LIQUID" })
    w:setBlock(0, 0, 1, "minecraft:water")
    local ok, err = m:clearFront()
    check(ok, "ALLOW_LIQUID treats water as passable: " .. tostring(err))
    check(w:getBlock(0, 0, 1).name == "minecraft:water", "water block itself is left as-is (not removed)")
end

-- 10. Lava is NEVER allowed through, even with ALLOW_LIQUID configured (safety override)
do
    local w, _, m = makeRig({ liquidPolicy = "ALLOW_LIQUID" })
    w:setBlock(0, 0, 1, "minecraft:lava")
    local ok, err = m:clearFront()
    check(ok == false, "lava is never passed through regardless of policy")
    check(errors.kindOf(err) == errors.BLOCKED, "lava-with-ALLOW_LIQUID classified BLOCKED")
end

-- 11. Lava with BLOCK_LIQUID: sealed rather than passed through
do
    local w, _, m = makeRig({ liquidPolicy = "BLOCK_LIQUID", sealBlockSlot = 1 })
    w:setInventorySlot(1, "minecraft:cobblestone", 64)
    w:setBlock(0, 0, 1, "minecraft:lava")
    local ok, err = m:clearFront()
    check(ok, "BLOCK_LIQUID seals lava: " .. tostring(err))
    check(w:getBlock(0, 0, 1).name == "minecraft:cobblestone", "lava cell now sealed")
end

-- 12. BLOCK_LIQUID with no sealing material left: fails safely, does not proceed
do
    local w, _, m = makeRig({ liquidPolicy = "BLOCK_LIQUID", sealBlockSlot = 1 })
    w:setInventorySlot(1, "minecraft:cobblestone", 0)
    w:setBlock(0, 0, 1, "minecraft:water")
    local ok, err = m:clearFront()
    check(ok == false, "BLOCK_LIQUID with no seal blocks left fails rather than proceeding")
    check(errors.kindOf(err) == errors.RESOURCE_EXHAUSTED, "out-of-seal-blocks classified RESOURCE_EXHAUSTED")
end

-- 13. Already-clear cell returns success immediately without digging
do
    local _, _, m = makeRig({})
    local ok, err = m:clearFront()
    check(ok, "clearing an already-empty cell succeeds trivially: " .. tostring(err))
end

print(string.format("\n%d checks, %d failures", checks, failures))
if failures > 0 then os.exit(1) end
