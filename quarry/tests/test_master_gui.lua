-- Smoke test for master/gui.lua: drives the Basalt widget handlers
-- directly (via the __QUARRY_TEST_MODE hook) against a mocked
-- `basalt` (tests/mocks/basalt_mock.lua) and a scripted registered
-- worker, mirroring tests/test_master_integration.lua's approach for
-- the CLI. This cannot verify the real Basalt2 library's rendering or
-- exact API (see master/gui.lua's header comment for the research
-- gaps there) -- it verifies that gui.lua's own logic (config
-- parsing, deploy/start/pause/cancel against lib/*.lua) is correct.
--
-- Run with: lua tests/test_master_gui.lua   (from quarry/)

local ROOT = "/tmp/quarry-gui-integration"
os.execute("rm -rf '" .. ROOT .. "' && mkdir -p '" .. ROOT .. "'")

package.path = "./lib/?.lua;./tests/mocks/?.lua;" .. package.path
local Bus = require("rednet_bus")
local fsMock = require("fs_mock")
local basaltMock = require("basalt_mock")
local protocol = require("protocol")
local validation = require("validation")

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
local workerNode = bus:node(WORKER_ID)

package.loaded["basalt"] = basaltMock.new({ width = 51, height = 19 })
_G.colors = { white = 1, black = 2, gray = 3, red = 4, lime = 5, yellow = 6 }
_G.rednet = masterNode
_G.peripheral = {
    find = function() return { isWireless = function() return true end } end,
    getName = function() return "back" end,
}
_G.fs = fsMock.new(ROOT)
_G.textutils = { serialize = serialize, unserialize = unserialize }
_G.os.getComputerID = function() return MASTER_ID end
_G.os.epoch = function() return 0 end
math.random = function() return 0 end
local EXPECTED_JOB_ID = "q-1-0-0"

_G.__QUARRY_TEST_MODE = true
dofile("master/gui.lua")

local hooks = _G.__QUARRY_DEBUG_GUI
check(hooks ~= nil, "gui exposes test hooks and returns without entering the Basalt/network loop")
local w = hooks.widgets

-- Register a worker (simulating worker.lua's REGISTER broadcast).
local registerMsg = protocol.build({
    type = protocol.TYPES.REGISTER, jobId = nil, workerId = WORKER_ID, sequence = 1,
    payload = { computerId = WORKER_ID, label = "worker-2" },
})
hooks.handleMessage(WORKER_ID, registerMsg)
check(hooks.state.workers[WORKER_ID] ~= nil, "handleMessage registers a new worker")
check(hooks.state.workers[WORKER_ID].status == "REGISTERED", "newly registered worker has status REGISTERED")
do
    local from, msg = workerNode.receive("quarry.v1", 0)
    check(from == MASTER_ID and msg and msg.type == "ack" and msg.ackFor == 1, "master acked the worker's registration")
end

-- Fill in the Setup tab's form fields (a 1x3x1 quarry, 1 worker) and
-- click Save -- equivalent of the CLI's `new` wizard.
w.minXIn.text, w.maxXIn.text = "0", "0"
w.minYIn.text, w.maxYIn.text = "0", "2"
w.minZIn.text, w.maxZIn.text = "0", "0"
w.workerCountIn.text = "1"
w.fuelReserveIn.text = "200"
w.invThreshIn.text = "0.9"
w.unloadXIn.text, w.unloadYIn.text, w.unloadZIn.text = "0", "10", "0"
w.directionGroup.set("down")
w.liquidGroup.set("STOP_AT_LIQUID")
w.cleanupCheckbox.checked = false
w.saveBtn._handlers.click()
check(hooks.state.config ~= nil, "Save populates state.config")
check(hooks.state.config.minX == 0 and hooks.state.config.maxY == 2, "form-entered bounds recorded correctly")
check(hooks.state.config.unloadPoint.direction == "down", "form-entered unload direction recorded correctly")
check(hooks.state.config.liquidPolicy == "STOP_AT_LIQUID", "form-entered liquid policy recorded correctly")
check(hooks.state.config.depotPoint == nil, "leaving the Depot tab's X/Y/Z blank means no depot is configured (opt-in default)")

-- Validate.
w.validateBtn._handlers.click()
check(w.output.text:find("valid") ~= nil, "Validate reports the config as valid: " .. w.output.text)

-- Partition.
w.partitionBtn._handlers.click()
check(hooks.state.partitions ~= nil and #hooks.state.partitions == 1, "Partition computes exactly 1 partition for 1 worker")
check(hooks.state.partitions[1].volume == 3, "the single partition covers the full 1x3x1 volume")

-- Deploy: clicking Deploy must only open the confirm modal, not act immediately.
masterNode.injectRaw(WORKER_ID,
    { type = "ack", protocolVersion = 1, jobId = EXPECTED_JOB_ID, workerId = WORKER_ID, sequence = 500, ackFor = 2 },
    "quarry.v1")
w.deployBtn._handlers.click()
check(w.modal.visible == true, "Deploy opens the confirm modal instead of acting immediately")
check(hooks.state.deployed == false, "deploy has not happened yet before the modal is confirmed")
w.modalYes._handlers.click()
check(w.modal.visible == false, "confirming the modal closes it")
check(hooks.state.jobId == EXPECTED_JOB_ID, "generated job ID matches the deterministic prediction")
check(hooks.state.deployed == true, "confirming Deploy marks the job as deployed")
check(hooks.state.workers[WORKER_ID].status == "ASSIGNED", "worker status becomes ASSIGNED after a successful deploy ack")
do
    local from, msg = workerNode.receive("quarry.v1", 0)
    check(from == MASTER_ID and msg and msg.type == "job_assign", "worker actually received a job_assign message")
    check(msg.payload.partition_min_y == 0 and msg.payload.partition_max_y == 2, "job payload carries the correct partition bounds")
    check(msg.payload.configuration.depotPoint == nil, "job payload has no depotPoint when none was configured")
    local jobOk, jobErrs = validation.validateJob(msg.payload, WORKER_ID)
    check(jobOk == true, "gui's real job_assign payload passes the worker's own validateJob: " .. table.concat(jobErrs or {}, "; "))
end

-- Start.
masterNode.injectRaw(WORKER_ID,
    { type = "ack", protocolVersion = 1, jobId = EXPECTED_JOB_ID, workerId = WORKER_ID, sequence = 501, ackFor = 3 },
    "quarry.v1")
w.startBtn._handlers.click()
check(w.modal.visible == true, "Start also opens the confirm modal first")
w.modalYes._handlers.click()
check(hooks.state.started == true, "confirming Start marks the job as started")
check(hooks.state.workers[WORKER_ID].status == "MINING", "worker status becomes MINING after a successful start ack")
do
    local from, msg = workerNode.receive("quarry.v1", 0)
    check(from == MASTER_ID and msg and msg.type == "start", "worker actually received a start message")
end

-- Heartbeat updates progress, and the Status tab's table reflects it.
local statusMsg = protocol.build({
    type = protocol.TYPES.HEARTBEAT, jobId = hooks.state.jobId, workerId = WORKER_ID, sequence = 2,
    payload = { state = "MINING", x = 0, y = 1, z = 0, fuel = 900, inventoryUtilization = 0.1, progress = 0.5 },
})
hooks.handleMessage(WORKER_ID, statusMsg)
hooks.refreshStatus()
local rows = w.workerTable:getData()
check(#rows == 1 and rows[1][1] == WORKER_ID, "status table has one row for the registered worker")
check(rows[1][3] == "50%", "status table shows the worker's heartbeat progress: " .. tostring(rows[1][3]))

-- Clicking a table row shows detail for that worker.
w.workerTable._handlers.select(w.workerTable, 1, rows[1])
check(w.detailLabel.text:find(tostring(WORKER_ID)) ~= nil, "selecting a worker row shows its detail")

-- Pause does not require confirmation (matches the CLI's `pause`).
-- No ack is injected here, so comm:sendReliable retries up to
-- maxRetries times (fast: the rednet_bus mock never really blocks,
-- and self.sleep is nil in this plain-Lua test environment) --
-- drain all of them so they don't bleed into the next check.
w.pauseBtn._handlers.click()
do
    local from, msg = workerNode.receive("quarry.v1", 0)
    check(from == MASTER_ID and msg and msg.type == "pause", "Pause sends a pause message without a confirm modal")
    while workerNode.receive("quarry.v1", 0) do end
end

-- Cancel requires confirmation (matches the CLI's `cancel`).
w.cancelBtn._handlers.click()
check(w.modal.visible == true, "Cancel opens the confirm modal")
w.modalYes._handlers.click()
check(hooks.state.deployed == false, "confirming Cancel clears the deployed flag")
do
    local from, msg = workerNode.receive("quarry.v1", 0)
    check(from == MASTER_ID and msg and msg.type == "cancel", "Cancel sends a cancel message")
    -- Like pause above, no ack was injected, so sendReliable retried
    -- (same sequence each time) -- drain the leftover duplicates so
    -- they don't bleed into the next check.
    while workerNode.receive("quarry.v1", 0) do end
end

-- Depot configuration (opt-in): fill in the Depot tab's fields and
-- re-save, verifying depotPoint flows all the way through to a
-- freshly deployed job's payload. Run last (after cancel above) so
-- it can't disturb the earlier deploy/start/pause/cancel assertions.
-- master's shared comm sequence counter is at 5 by this point
-- (1=register ack, 2=job_assign, 3=start, 4=pause, 5=cancel), so the
-- next sendReliable (this re-deploy's job_assign) will be sequence 6.
do
    w.depotXIn.text, w.depotYIn.text, w.depotZIn.text = "5", "64", "5"
    w.depotFacingGroup.set("east")
    w.saveBtn._handlers.click()
    check(hooks.state.config.depotPoint ~= nil, "filling in the Depot tab's X/Y/Z populates depotPoint")
    check(hooks.state.config.depotPoint.x == 5 and hooks.state.config.depotPoint.y == 64
        and hooks.state.config.depotPoint.z == 5, "depot coordinates recorded correctly")
    check(hooks.state.config.depotPoint.facing == 1, "depot facing 'east' converted to the numeric convention (1)")

    w.partitionBtn._handlers.click()
    -- sequence must differ from the earlier acks (500, 501) in this
    -- file: comm:isDuplicate() dedups purely on (from, sequence), so
    -- reusing 500 here would be silently dropped as an already-seen
    -- duplicate rather than matched against this new ackFor.
    masterNode.injectRaw(WORKER_ID,
        { type = "ack", protocolVersion = 1, jobId = EXPECTED_JOB_ID, workerId = WORKER_ID, sequence = 502, ackFor = 6 },
        "quarry.v1")
    w.deployBtn._handlers.click()
    w.modalYes._handlers.click()
    check(hooks.state.workers[WORKER_ID].status == "ASSIGNED", "worker status becomes ASSIGNED after the depot-enabled re-deploy ack")
    local from, msg = workerNode.receive("quarry.v1", 0)
    check(from == MASTER_ID and msg and msg.type == "job_assign", "re-deploying after enabling a depot still sends job_assign")
    check(msg.payload.configuration.depotPoint ~= nil and msg.payload.configuration.depotPoint.facing == 1,
        "the deployed job payload carries the configured depotPoint")
    local jobOk2, jobErrs2 = validation.validateJob(msg.payload, WORKER_ID)
    check(jobOk2 == true, "job payload with a depotPoint still passes validateJob: " .. table.concat(jobErrs2 or {}, "; "))
end

print(string.format("\n%d checks, %d failures", checks, failures))
if failures > 0 then os.exit(1) end
