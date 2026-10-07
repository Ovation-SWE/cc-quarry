-- Smoke test for master/master.lua: drives the command flow (new ->
-- validate -> partition -> deploy -> start) against a stubbed CC
-- environment and a scripted registered worker, using the
-- __QUARRY_TEST_MODE hook to call command functions directly instead
-- of going through the interactive parallel event loop.
--
-- Run with: lua tests/test_master_integration.lua   (from quarry/)

local ROOT = "/tmp/quarry-master-integration"
os.execute("rm -rf '" .. ROOT .. "' && mkdir -p '" .. ROOT .. "'")

package.path = "./lib/?.lua;./tests/mocks/?.lua;" .. package.path
local Bus = require("rednet_bus")
local fsMock = require("fs_mock")
local protocol = require("protocol")

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

local MASTER_ID = 1
local WORKER_ID = 2

local bus = Bus.new()
local masterNode = bus:node(MASTER_ID)
local workerNode = bus:node(WORKER_ID) -- used only to script "the worker" by hand

-- Scripted keyboard input for the `new` wizard + two `confirm()` calls.
local answers = {
    "0", "0", "0", "2", "0", "0", -- minX maxX minY maxY minZ maxZ (1x3x1 quarry)
    "1",              -- workerCount
    "200",            -- fuelReserve
    "0.9",            -- inventoryReturnThreshold
    "STOP_AT_LIQUID", -- liquidPolicy
    "0", "10", "0",   -- unload point x y z
    "down",           -- unload direction
    "n",              -- configure a depot? (no -- see the depot-specific check below)
    "n",              -- cleanup pass
    "CONFIRM",        -- deploy confirmation
    "CONFIRM",        -- start confirmation
}
local answerIdx = 0

_G.rednet = masterNode
_G.peripheral = {
    find = function() return { isWireless = function() return true end } end,
    getName = function() return "back" end,
}
_G.fs = fsMock.new(ROOT)
_G.textutils = { serialize = serialize, unserialize = unserialize }
_G.os.getComputerID = function() return MASTER_ID end
_G.os.epoch = function() return 0 end
_G.write = function() end
-- newJobId() mixes in math.random(); pin it so the generated job ID
-- (and hence the jobId this test must stamp on its scripted acks) is
-- fully deterministic: "q-<selfId>-<epoch>-<random>" = "q-1-0-0".
math.random = function() return 0 end
local EXPECTED_JOB_ID = "q-1-0-0"
_G.read = function()
    answerIdx = answerIdx + 1
    local a = answers[answerIdx]
    if a == nil then error("test ran out of scripted answers at index " .. answerIdx) end
    return a
end

_G.__QUARRY_TEST_MODE = true
dofile("master/master.lua")

local hooks = _G.__QUARRY_DEBUG_MASTER
check(hooks ~= nil, "master exposes test hooks and returns without entering the interactive loop")

-- Register a worker (simulating worker.lua's REGISTER broadcast) and
-- process it directly via the exposed handleMessage.
local registerMsg = protocol.build({
    type = protocol.TYPES.REGISTER, jobId = nil, workerId = WORKER_ID, sequence = 1,
    payload = { computerId = WORKER_ID, label = "worker-2" },
})
hooks.handleMessage(WORKER_ID, registerMsg)
check(hooks.state.workers[WORKER_ID] ~= nil, "handleMessage registers a new worker")
check(hooks.state.workers[WORKER_ID].status == "REGISTERED", "newly registered worker has status REGISTERED")

-- The register ack (comm sequence 1, master's first-ever message)
-- should now be sitting in the worker's queue.
do
    local from, msg = workerNode.receive("quarry.v1", 0)
    check(from == MASTER_ID and msg and msg.type == "ack" and msg.ackFor == 1,
        "master acked the worker's registration")
end

-- `new`: run the configuration wizard.
hooks.commands.new()
check(hooks.state.config ~= nil, "new populates state.config")
check(hooks.state.config.minX == 0 and hooks.state.config.maxY == 2,
    "wizard-entered bounds recorded correctly")
check(hooks.state.config.unloadPoint.direction == "down", "wizard-entered unload direction recorded correctly")

-- `validate`: should pass (1 worker requested, 1 registered).
local ok, errs = require("validation").validateConfig(hooks.state.config, { availableWorkers = 1 })
check(ok == true, "configuration entered via the wizard is valid: " .. table.concat(errs or {}, "; "))

-- `partition`: compute the layout for the 1x3x1 quarry / 1 worker.
hooks.commands.partition()
check(hooks.state.partitions ~= nil and #hooks.state.partitions == 1, "partition computes exactly 1 partition for 1 worker")
check(hooks.state.partitions[1].volume == 3, "the single partition covers the full 1x3x1 volume")

-- `deploy`: pre-inject the ack the worker would send for the
-- JOB_ASSIGN (master's 2nd-ever message: 1 was the register ack).
masterNode.injectRaw(WORKER_ID,
    { type = "ack", protocolVersion = 1, jobId = EXPECTED_JOB_ID, workerId = WORKER_ID, sequence = 500, ackFor = 2 },
    "quarry.v1")
hooks.commands.deploy()
check(hooks.state.jobId == EXPECTED_JOB_ID, "generated job ID matches the deterministic prediction")
check(hooks.state.deployed == true, "deploy marks the job as deployed")
check(hooks.state.workers[WORKER_ID].status == "ASSIGNED", "worker status becomes ASSIGNED after a successful deploy ack")
do
    local from, msg = workerNode.receive("quarry.v1", 0)
    check(from == MASTER_ID and msg and msg.type == "job_assign", "worker actually received a job_assign message")
    check(msg.payload.worker_id == WORKER_ID, "job payload addressed to the correct worker_id")
    check(msg.payload.partition_min_y == 0 and msg.payload.partition_max_y == 2,
        "job payload carries the correct partition bounds")
    -- Close the loop with test_worker_integration.lua / test_validation.lua:
    -- the master's *actual* generated payload, not a hand-written
    -- stand-in, must pass the exact same validation a real worker
    -- would apply on receipt.
    local jobOk, jobErrs = require("validation").validateJob(msg.payload, WORKER_ID)
    check(jobOk == true, "master's real job_assign payload passes the worker's own validateJob: "
        .. table.concat(jobErrs or {}, "; "))
end

-- `start`: pre-inject the ack for master's 3rd-ever message.
masterNode.injectRaw(WORKER_ID,
    { type = "ack", protocolVersion = 1, jobId = EXPECTED_JOB_ID, workerId = WORKER_ID, sequence = 501, ackFor = 3 },
    "quarry.v1")
hooks.commands.start()
check(hooks.state.started == true, "start marks the job as started")
check(hooks.state.workers[WORKER_ID].status == "MINING", "worker status becomes MINING after a successful start ack")
do
    local from, msg = workerNode.receive("quarry.v1", 0)
    check(from == MASTER_ID and msg and msg.type == "start", "worker actually received a start message")
end

-- A heartbeat/status update from the worker should update progress.
local statusMsg = protocol.build({
    type = protocol.TYPES.HEARTBEAT, jobId = hooks.state.jobId, workerId = WORKER_ID, sequence = 2,
    payload = { state = "MINING", x = 0, y = 1, z = 0, fuel = 900, inventoryUtilization = 0.1, progress = 0.5 },
})
hooks.handleMessage(WORKER_ID, statusMsg)
check(hooks.state.workers[WORKER_ID].last.progress == 0.5, "heartbeat updates the worker's recorded progress")

-- Depot configuration (opt-in): run `new` again with a fresh scripted
-- "yes" answer for the new depot prompt, verifying it's parsed and
-- stored correctly. Run last so it can't disturb the already-deployed
-- job checked above (commands.new() resets state.partitions/deployed).
do
    local depotAnswers = {
        "0", "0", "0", "2", "0", "0",
        "1", "200", "0.9", "STOP_AT_LIQUID",
        "0", "10", "0", "down",
        "y",            -- configure a depot? yes
        "5", "64", "5", -- depot x y z
        "east",         -- depot facing
        "n",            -- cleanup pass
    }
    local depotIdx = 0
    _G.read = function()
        depotIdx = depotIdx + 1
        local a = depotAnswers[depotIdx]
        if a == nil then error("test ran out of scripted depot answers at index " .. depotIdx) end
        return a
    end
    hooks.commands.new()
    check(hooks.state.config.depotPoint ~= nil, "depot prompt 'y' populates state.config.depotPoint")
    check(hooks.state.config.depotPoint.x == 5 and hooks.state.config.depotPoint.y == 64
        and hooks.state.config.depotPoint.z == 5, "depot coordinates recorded correctly")
    check(hooks.state.config.depotPoint.facing == 1, "depot facing name 'east' converted to the numeric convention (1)")
    local depotOk, depotErrs = require("validation").validateConfig(hooks.state.config, { availableWorkers = 1 })
    check(depotOk == true, "config with a depot configured is still valid: " .. table.concat(depotErrs or {}, "; "))
end

print(string.format("\n%d checks, %d failures", checks, failures))
if failures > 0 then os.exit(1) end
