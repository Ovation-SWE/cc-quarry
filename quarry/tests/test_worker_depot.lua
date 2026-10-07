-- Integration test for worker/worker.lua's opt-in depot workflow
-- (steps.COLLECTING_RESOURCES / the real steps.NAVIGATING_TO_START
-- journey): a job whose configuration.depotPoint differs from
-- starting_position, with the mock turtle physically placed at the
-- depot (not the job site) and a depot chest fixture (world.lua's
-- depotStock) stocked with fuel. Proves three things the plain
-- tests/test_worker_integration.lua (no depotPoint) cannot:
--   1. The worker actually travels from the depot to starting_position
--      (not a no-op -- see worker.lua's buildSubsystems, which seeds
--      dead reckoning at the depot when one is configured).
--   2. It refuels itself from nothing (fuel starts at 0) by sucking
--      from the depot, since turtle.suck() costs no fuel.
--   3. That transit leg digs through an obstruction OUTSIDE the
--      worker's partition (ctx.transitMining has no partition fence),
--      which the normal ctx.mining instance would refuse.
--
-- Run with: lua tests/test_worker_depot.lua   (from quarry/)

local ROOT = "/tmp/quarry-worker-depot"
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

local WORKER_ID = 2
local MASTER_ID = 1

-- Depot at (10,5,0) facing north; the job's starting_position is
-- (0,5,0) -- 10 blocks away along X, with a stray stone block at
-- (5,5,0) deliberately placed outside the 1x1x3 partition (which only
-- covers x=0,z=0) to prove the transit leg digs through it. Fuel
-- starts at 0: the only way the worker can ever move is by first
-- sucking from the depot's stock, which costs no fuel.
local world = World.new({
    x = 10, y = 5, z = 0, facing = directions.NORTH, fuel = 0,
    depotStock = { name = "minecraft:coal", count = 20 }, -- 1600 fuel potential
})
local bus = Bus.new()
local workerNode = bus:node(WORKER_ID)
local masterNode = bus:node(MASTER_ID)

_G.turtle = world:turtleAPI()
_G.rednet = workerNode
_G.peripheral = {
    find = function() return { isWireless = function() return true end } end,
    getName = function() return "back" end,
}
_G.fs = fsMock.new(ROOT)
_G.textutils = { serialize = serialize, unserialize = unserialize }
_G.gps = { locate = function() return nil end } -- no GPS constellation
_G.sleep = function() end
_G.os.getComputerID = function() return WORKER_ID end
_G.os.getComputerLabel = function() return "test-worker" end
_G.os.epoch = function() return 0 end

local PARTITION = {
    partition_min_x = 0, partition_max_x = 0,
    partition_min_y = 3, partition_max_y = 5,
    partition_min_z = 0, partition_max_z = 0,
}
world:fillBox(0, 0, 3, 4, 0, 0, "minecraft:stone") -- the 2 real blocks to mine
world:setBlock(5, 5, 0, "minecraft:stone")         -- transit obstruction, outside the partition

local JOB = {
    protocol = "quarry.v1",
    job_id = "job-depot-1",
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
        inventoryReturnThreshold = 0.99,
        liquidPolicy = "STOP_AT_LIQUID",
        ignoredBlocks = {},
        unloadPoint = { x = 5, y = 6, z = 5, direction = "down" },
        depotPoint = { x = 10, y = 5, z = 0, facing = directions.NORTH },
    },
}

_G.__QUARRY_TEST_YIELD_EACH_STEP = true
_G.__QUARRY_TEST_MAX_STEPS = 100000

local workerCo = coroutine.create(function() dofile("worker/worker.lua") end)

local function runWorkerSteps(n)
    for _ = 1, n do
        if coroutine.status(workerCo) == "dead" then error("worker coroutine ended unexpectedly") end
        local ok, err = coroutine.resume(workerCo)
        if not ok then error("worker crashed: " .. tostring(err)) end
    end
end

-- Phase 1: boot -> register.
runWorkerSteps(1) -- BOOT -> REGISTERING
workerNode.injectRaw(MASTER_ID,
    { type = "ack", protocolVersion = 1, jobId = nil, workerId = MASTER_ID, sequence = 1000, ackFor = 1 },
    "quarry.v1")
runWorkerSteps(1) -- REGISTERING: broadcasts (seq=1), finds the ack, registers

-- Phase 2: assign the job. buildSubsystems must seed dead reckoning
-- at the depot (10,5,0), NOT starting_position (0,5,0) -- confirmed
-- indirectly below by the turtle not having moved yet.
local jobMsg = { type = "job_assign", protocolVersion = 1, jobId = nil, workerId = MASTER_ID, sequence = 2, payload = JOB }
workerNode.injectRaw(MASTER_ID, jobMsg, "quarry.v1")
runWorkerSteps(2) -- WAITING_FOR_JOB (consume) -> VALIDATING_JOB -> ASSIGNED
check(world.pos.x == 10 and world.pos.y == 5 and world.pos.z == 0,
    "worker has not moved: VALIDATING_JOB seeded dead reckoning at the depot, not starting_position")
check(world.fuel == 0, "no fuel collected yet while merely ASSIGNED")

-- Phase 3: ASSIGNED waits for START; confirm it does nothing on its own.
runWorkerSteps(1)
check(world.pos.x == 10 and world.fuel == 0, "worker does not collect/move while merely ASSIGNED")

-- Phase 4: send START. The first step consumes it (ASSIGNED ->
-- COLLECTING_RESOURCES is just a state-machine transition -- the new
-- state's own handler body hasn't run yet, so still no fuel/movement).
local startMsg = { type = "start", protocolVersion = 1, jobId = "job-depot-1", workerId = MASTER_ID, sequence = 3 }
workerNode.injectRaw(MASTER_ID, startMsg, "quarry.v1")
runWorkerSteps(1)
check(world.fuel == 0 and world.pos.x == 10, "transitioning into COLLECTING_RESOURCES does not itself act")

-- Phase 5: COLLECTING_RESOURCES actually runs: sucks the depot's
-- stock (turtle.suck() costs no fuel, which is why this works from an
-- empty tank) and burns it via autoRefuel.
runWorkerSteps(1)
check(world.depotStock.count == 0, "worker drained the depot's fuel stock")
check(world.fuel > 0, "fuel level rose after collecting from the depot (from a standing start of 0)")
check(world.pos.x == 10, "collecting fuel at the depot involves no movement")

-- Phase 6: NAVIGATING_TO_START now does a *real* multi-block journey
-- (10 blocks west), digging through the stone at (5,5,0) via the
-- partition-free transitMining instance -- the normal partition-
-- fenced ctx.mining would refuse that dig (it's outside the 1x1x3
-- partition). moveTo runs to completion within this single step call.
local fuelBeforeTransit = world.fuel
runWorkerSteps(1)
check(world.pos.x == 0 and world.pos.y == 5 and world.pos.z == 0,
    "worker actually traveled from the depot to starting_position")
check(world:getBlock(5, 5, 0) == nil, "the transit obstruction (outside the partition) was dug through")
check(world.fuel == fuelBeforeTransit - 10, "transit consumed exactly 10 fuel for the 10-block journey")

-- Phase 7: mining proceeds exactly as in the no-depot integration
-- test (same 1x1x3 partition) -- generous step headroom through
-- COMPLETED, matching tests/test_worker_integration.lua.
runWorkerSteps(40)
check(world.pos.x == 0 and world.pos.z == 0, "worker stayed within its 1-wide partition during mining (no X/Z drift)")
check(world.pos.y == PARTITION.partition_min_y, "worker descended to the bottom of its partition")
for y = PARTITION.partition_min_y, PARTITION.partition_max_y - 1 do
    check(world:getBlock(0, y, 0) == nil, "block at y=" .. y .. " was actually mined")
end

local sawComplete = false
for _ = 1, 10 do
    local from, msg = masterNode.receive("quarry.v1", 0)
    if not msg then break end
    if from == WORKER_ID and msg.type == "complete" then sawComplete = true end
    if msg.type == "complete" then
        workerNode.injectRaw(MASTER_ID, { type = "ack", protocolVersion = 1, jobId = "job-depot-1", workerId = MASTER_ID, sequence = 9999, ackFor = msg.sequence }, "quarry.v1")
    end
end
check(sawComplete, "worker reported COMPLETE after finishing its partition")

print(string.format("\n%d checks, %d failures", checks, failures))
if failures > 0 then os.exit(1) end
