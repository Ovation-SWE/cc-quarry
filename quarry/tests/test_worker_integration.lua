-- End-to-end integration test for worker/worker.lua: boots a fresh
-- worker against a fully stubbed CC:Tweaked environment (mock turtle
-- world, mock rednet bus, in-memory fs, minimal textutils), scripts
-- "the master" by hand (injecting/reading raw bus messages), and
-- drives the worker through register -> job assign -> start -> mine
-- a small partition to completion -> report COMPLETE.
--
-- This exists to catch integration/wiring bugs (typos in field
-- names, wrong function signatures between worker.lua and lib/*.lua)
-- that per-module unit tests can't see, since worker.lua itself is
-- untested elsewhere. It relies on the __QUARRY_TEST_MAX_STEPS escape
-- hatch documented in worker.lua's final loop.
--
-- Run with: lua tests/test_worker_integration.lua   (from quarry/)

local ROOT = "/tmp/quarry-worker-integration"
os.execute("rm -rf '" .. ROOT .. "' && mkdir -p '" .. ROOT .. "'")

package.path = "./lib/?.lua;./tests/mocks/?.lua;" .. package.path
local World = require("world")
local Bus = require("rednet_bus")
local fsMock = require("fs_mock")
local directions = require("directions")

local failures = 0
local checks = 0
local function check(cond, msg)
    checks = checks + 1
    if not cond then
        failures = failures + 1
        print("FAIL: " .. msg)
    end
end

-- ---- Minimal Lua-literal (de)serializer standing in for textutils ----
local function serialize(t)
    local ty = type(t)
    if ty == "string" then return string.format("%q", t) end
    if ty == "number" or ty == "boolean" then return tostring(t) end
    if ty == "table" then
        local parts = { "{" }
        for k, v in pairs(t) do
            local key = type(k) == "string" and ("[" .. string.format("%q", k) .. "]") or ("[" .. tostring(k) .. "]")
            parts[#parts + 1] = key .. "=" .. serialize(v) .. ","
        end
        parts[#parts + 1] = "}"
        return table.concat(parts)
    end
    return "nil"
end
local function unserialize(s)
    local chunk = load("return " .. s)
    if not chunk then return nil end
    local ok, result = pcall(chunk)
    if not ok then return nil end
    return result
end

-- ---- Build the stubbed global environment ----
local WORKER_ID = 2
local MASTER_ID = 1

-- The turtle starts exactly at the job's starting_position, in open
-- air (as a real deployment requires: a turtle cannot physically
-- occupy a solid block, so the operator must place it somewhere
-- already open -- typically the top of the shaft). worker.lua seeds
-- its dead-reckoning position directly from starting_position at job
-- acceptance time, trusting that the operator placed it correctly;
-- without GPS (stubbed unavailable below) there is no way to verify
-- this, so a real misplacement here would go undetected -- see the
-- "GPS unavailable" limitation in docs/LIMITATIONS.md.
local world = World.new({ x = 0, y = 5, z = 0, facing = directions.NORTH, fuel = 5000 })
local bus = Bus.new()
local workerNode = bus:node(WORKER_ID)
local masterNode = bus:node(MASTER_ID) -- used only to script "the master" by hand

_G.turtle = world:turtleAPI()
_G.rednet = workerNode
_G.peripheral = {
    find = function() return { isWireless = function() return true end } end,
    getName = function() return "back" end,
}
_G.fs = fsMock.new(ROOT)
_G.textutils = { serialize = serialize, unserialize = unserialize }
_G.gps = { locate = function() return nil end } -- simulate "no GPS constellation" throughout
_G.sleep = function() end
_G.os.getComputerID = function() return WORKER_ID end
_G.os.getComputerLabel = function() return "test-worker" end
_G.os.epoch = function() return 0 end

-- A small 1x1x3 partition (deliberately tiny so the test runs fast
-- while still exercising a multi-step traversal + descent).
local PARTITION = {
    partition_min_x = 0, partition_max_x = 0,
    partition_min_y = 3, partition_max_y = 5,
    partition_min_z = 0, partition_max_z = 0,
}
-- Fill the partition with stone below the turtle's starting cell
-- (y=5, where the turtle already stands, is left as air -- it must
-- be, physically). This gives 2 real blocks to mine (y=4, y=3).
world:fillBox(0, 0, 3, 4, 0, 0, "minecraft:stone")

local JOB = {
    protocol = "quarry.v1",
    job_id = "job-integration-1",
    worker_id = WORKER_ID,
    quarry_min_x = 0, quarry_max_x = 0, quarry_min_y = 3, quarry_max_y = 5, quarry_min_z = 0, quarry_max_z = 0,
    partition_min_x = PARTITION.partition_min_x, partition_max_x = PARTITION.partition_max_x,
    partition_min_y = PARTITION.partition_min_y, partition_max_y = PARTITION.partition_max_y,
    partition_min_z = PARTITION.partition_min_z, partition_max_z = PARTITION.partition_max_z,
    starting_position = { x = 0, y = 5, z = 0 },
    starting_facing = directions.NORTH,
    configuration = {
        version = 1,
        fuelReserve = 50,
        inventoryReturnThreshold = 0.99, -- effectively "only when truly full", 16 stone won't trigger it
        liquidPolicy = "STOP_AT_LIQUID",
        ignoredBlocks = {},
        -- "down" is the recommended default (see docs/CONFIG_REFERENCE.md):
        -- it's independent of whatever facing the turtle happens to
        -- arrive with, unlike "forward". Never actually visited in
        -- this test (inventory never fills up), but must still be a
        -- well-formed waypoint since it's part of every job payload.
        unloadPoint = { x = 5, y = 6, z = 5, direction = "down" },
    },
}

-- ---- Run the worker as a single continuous coroutine that yields
-- ---- after every step, so the test can single-step it and script
-- ---- "the master" in between steps without losing in-memory state
-- ---- that worker.lua doesn't persist to disk (e.g. masterId before
-- ---- a job exists). ----
_G.__QUARRY_TEST_YIELD_EACH_STEP = true
_G.__QUARRY_TEST_MAX_STEPS = 100000 -- generous safety cap, not the real control

local workerCo = coroutine.create(function() dofile("worker/worker.lua") end)

local function runWorkerSteps(n)
    for _ = 1, n do
        if coroutine.status(workerCo) == "dead" then error("worker coroutine ended unexpectedly") end
        local ok, err = coroutine.resume(workerCo)
        if not ok then error("worker crashed: " .. tostring(err)) end
    end
end

-- Phase 1: fresh boot -> REGISTERING -> broadcasts REGISTER.
-- worker.lua's comm sequence counter starts at 0, so the very first
-- message it ever sends (this REGISTER broadcast) is deterministically
-- sequence 1. We pre-inject the matching ack *before* letting
-- REGISTERING run, since its single step call both broadcasts and
-- waits for the ack in one uninterrupted (non-yielding) function call
-- -- there is no opportunity to react in between.
runWorkerSteps(1) -- BOOT -> REGISTERING (no network activity yet)
workerNode.injectRaw(MASTER_ID,
    { type = "ack", protocolVersion = 1, jobId = nil, workerId = MASTER_ID, sequence = 1000, ackFor = 1 },
    "quarry.v1")
runWorkerSteps(1) -- REGISTERING: broadcasts (seq=1), immediately finds the pre-injected ack, registers
do
    local from, msg = masterNode.receive("quarry.v1", 0)
    check(from == WORKER_ID and msg and msg.type == "register" and msg.sequence == 1,
        "worker's first-ever message was the predicted REGISTER broadcast (sequence 1)")
end

-- Phase 2: inject a JOB_ASSIGN "from master", run through
-- VALIDATING_JOB -> ASSIGNED, and capture the worker's ack.
local jobMsg = { type = "job_assign", protocolVersion = 1, jobId = nil, workerId = MASTER_ID, sequence = 2, payload = JOB }
workerNode.injectRaw(MASTER_ID, jobMsg, "quarry.v1")
runWorkerSteps(2) -- WAITING_FOR_JOB (consume) -> VALIDATING_JOB -> ASSIGNED
do
    local from, msg = masterNode.receive("quarry.v1", 0)
    check(from == WORKER_ID and msg and msg.type == "ack" and msg.ackFor == 2,
        "worker acks the job assignment with the correct sequence")
end

-- Phase 3: worker should now be sitting in ASSIGNED, waiting for
-- START. Confirm it does NOT move on its own.
runWorkerSteps(1)
check(world.pos.x == 0 and world.pos.y == 5 and world.pos.z == 0,
    "worker has not moved while merely ASSIGNED (waits for explicit START)")

-- Phase 4: send START, then let the worker run enough steps to mine
-- both real blocks (y=4, y=3) in its 1x1x3 partition (y=5, its
-- starting cell, is already open air) and reach COMPLETED, plus
-- headroom for bookkeeping steps.
local startMsg = { type = "start", protocolVersion = 1, jobId = "job-integration-1", workerId = MASTER_ID, sequence = 3 }
workerNode.injectRaw(MASTER_ID, startMsg, "quarry.v1")
runWorkerSteps(40)

check(world.pos.x == 0 and world.pos.z == 0, "worker stayed within its 1-wide partition (no X/Z drift)")
check(world.pos.y == PARTITION.partition_min_y, "worker descended to the bottom of its partition (y=" .. PARTITION.partition_min_y .. ")")

for y = PARTITION.partition_min_y, PARTITION.partition_max_y - 1 do
    check(world:getBlock(0, y, 0) == nil, "block at y=" .. y .. " was actually mined")
end

-- The worker's own inventory should now hold the mined stone
-- (nothing was in range of the inventory-return threshold, so it
-- should still be carrying it rather than having unloaded early).
local carriedStone = 0
for slot = 1, 16 do
    local item = world.inventory[slot]
    if item and item.name == "minecraft:stone" then carriedStone = carriedStone + item.count end
end
check(carriedStone == 2, "worker picked up both mined stone blocks (has " .. carriedStone .. ")")

-- Phase 5: worker should have reported COMPLETE to "master".
local sawComplete = false
for _ = 1, 10 do
    local from, msg = masterNode.receive("quarry.v1", 0)
    if not msg then break end
    if from == WORKER_ID and msg.type == "complete" then sawComplete = true end
    if msg.type == "complete" then
        -- worker is using sendReliable for COMPLETE, so it expects an ack;
        -- without one it would keep retrying on subsequent steps. Ack it.
        workerNode.injectRaw(MASTER_ID, { type = "ack", protocolVersion = 1, jobId = "job-integration-1", workerId = MASTER_ID, sequence = 9999, ackFor = msg.sequence }, "quarry.v1")
    end
end
check(sawComplete, "worker reported COMPLETE after finishing its partition")

print(string.format("\n%d checks, %d failures", checks, failures))
if failures > 0 then os.exit(1) end
