--- Quarry master/controller program. Runs on a stationary computer
--- (does not need to be a turtle). Provides the configuration UI,
--- partitioning, deployment, job control, and progress monitoring
--- described in docs/ARCHITECTURE.md.
--
-- Uses parallel.waitForAny to run the interactive command prompt and
-- the background network-message loop concurrently: both are plain
-- Lua functions cooperatively scheduled by CC:Tweaked's coroutine-
-- based `parallel` API (see tweaked.cc/module/parallel.html), sharing
-- the same in-memory `state` table. This is necessary because read()
-- blocks for keyboard input, and the master must keep processing
-- worker heartbeats/acks/registrations the whole time.

package.path = "lib/?.lua;" .. package.path

local partitionLib = require("partition")
local traversal = require("traversal")
local protocol = require("protocol")
local comms = require("comms")
local persistence = require("persistence")
local validation = require("validation")
local logging = require("logging")
local directions = require("directions")

local FACING_BY_NAME = { north = 0, east = 1, south = 2, west = 3 }

local STATE_PATH = "master_state"
local HEARTBEAT_TIMEOUT = 15      -- seconds without a heartbeat before "missed"
local HEARTBEAT_MISSES_DEAD = 4   -- consecutive misses before "unresponsive"

----------------------------------------------------------------------
-- Setup
----------------------------------------------------------------------

local log = logging.new({ path = "log.txt", level = "normal" })
local persist = persistence.new()

local modem = peripheral.find("modem", function(_, p) return p.isWireless and p.isWireless() end)
    or peripheral.find("modem")
if not modem then
    print("FATAL: no wireless modem attached. Attach one and reboot.")
    return
end
rednet.open(peripheral.getName(modem))

local selfId = os.getComputerID()
local comm = comms.new({ selfId = selfId, log = log })

local state = {
    config = nil,       -- draft/active quarry configuration
    jobId = nil,
    partitions = nil,   -- computed partition list (indexed 1..k, "slots")
    slotWorker = {},    -- [slotIndex] = computerId assigned to that partition
    workers = {},       -- [computerId] = { label=, status=, lastSeen=, misses=, last={} }
    deployed = false,
    started = false,
}

----------------------------------------------------------------------
-- Persistence
----------------------------------------------------------------------

local function saveState()
    local ok, err = persist:save(STATE_PATH, state)
    if not ok then log:error("failed to save master state", { error = err }) end
end

local function loadState()
    local data = persist:load(STATE_PATH)
    if data then
        state = data
        comm:setJobId(state.jobId)
        print("Recovered previous session" .. (state.jobId and (" (job " .. state.jobId .. ")") or "") .. ".")
        log:info("master state recovered", { jobId = state.jobId })
    end
end

----------------------------------------------------------------------
-- Helpers
----------------------------------------------------------------------

local function confirm(prompt)
    write(prompt .. " Type CONFIRM to proceed: ")
    local line = read()
    return line == "CONFIRM"
end

local function newJobId()
    return string.format("q-%d-%d-%d", selfId, os.epoch and os.epoch("utc") or os.clock() * 1000, math.random(0, 999999))
end

local function bounds(cfg)
    return { minX = cfg.minX, maxX = cfg.maxX, minY = cfg.minY, maxY = cfg.maxY, minZ = cfg.minZ, maxZ = cfg.maxZ }
end

local function registeredWorkerIds()
    local ids = {}
    for id, w in pairs(state.workers) do
        if w.status ~= "GONE" then ids[#ids + 1] = id end
    end
    table.sort(ids)
    return ids
end

local function askInt(prompt, default)
    write(prompt .. (default ~= nil and (" [" .. default .. "]") or "") .. ": ")
    local line = read()
    if line == "" and default ~= nil then return default end
    return tonumber(line)
end

local function askStr(prompt, default)
    write(prompt .. (default and (" [" .. default .. "]") or "") .. ": ")
    local line = read()
    if line == "" then return default end
    return line
end

----------------------------------------------------------------------
-- Commands
----------------------------------------------------------------------

local commands = {}

function commands.help()
    print([[
Commands:
  new        - configure a new quarry (interactive wizard)
  show       - display the current configuration
  validate   - check the current configuration for errors
  partition  - compute and display the partition layout
  dryrun     - simulate the job without touching any turtle
  deploy     - assign partitions to registered workers
  start      - signal deployed workers to begin mining (CONFIRM)
  pause      - pause all workers (resumable)
  resume     - resume all paused workers
  stop       - alias for pause
  cancel     - permanently cancel the active job (CONFIRM)
  estop      - emergency-stop all workers immediately (CONFIRM)
  status     - show live progress for all workers
  worker <id>- show detail for one worker
  recover    - reload the last saved session from disk
  save       - save the current session to disk
  load       - alias for recover
  quit       - exit the master program (workers keep running)
]])
end
commands.h = commands.help

function commands.new()
    local cfg = {}
    print("=== New quarry configuration ===")
    cfg.minX = askInt("min X"); cfg.maxX = askInt("max X")
    cfg.minY = askInt("min Y"); cfg.maxY = askInt("max Y")
    cfg.minZ = askInt("min Z"); cfg.maxZ = askInt("max Z")
    cfg.workerCount = askInt("number of worker turtles", #registeredWorkerIds())
    cfg.fuelReserve = askInt("fuel reserve (blocks)", 200)
    cfg.inventoryReturnThreshold = tonumber(askStr("inventory return threshold (0-1)", "0.9"))
    cfg.liquidPolicy = askStr("liquid policy (STOP_AT_LIQUID/BLOCK_LIQUID/ALLOW_LIQUID)", "STOP_AT_LIQUID")
    cfg.ignoredBlocks = { ["minecraft:bedrock"] = true }
    local ux = askInt("unload point X", 0)
    local uy = askInt("unload point Y", 0)
    local uz = askInt("unload point Z", 0)
    local udir = askStr("unload direction (forward/up/down)", "forward")
    cfg.unloadPoint = { x = ux, y = uy, z = uz, direction = udir }
    if askStr("configure a shared depot for auto-placement/auto-fuel? (y/n)", "n") == "y" then
        local dx = askInt("depot X", 0)
        local dy = askInt("depot Y", 0)
        local dz = askInt("depot Z", 0)
        local dfacing = askStr("depot facing (north/east/south/west)", "north")
        cfg.depotPoint = { x = dx, y = dy, z = dz, facing = FACING_BY_NAME[dfacing] or 0 }
    end
    cfg.cleanupPass = (askStr("perform cleanup pass? (y/n)", "n") == "y")
    cfg.protocolVersion = protocol.VERSION

    state.config = cfg
    state.jobId = nil
    state.partitions = nil
    state.slotWorker = {}
    state.deployed = false
    state.started = false
    saveState()
    print("Configuration recorded. Run 'validate' then 'partition' next.")
end

function commands.show()
    if not state.config then print("No configuration set. Run 'new' first."); return end
    local cfg = state.config
    print(string.format("X: %d -> %d   Y: %d -> %d   Z: %d -> %d", cfg.minX, cfg.maxX, cfg.minY, cfg.maxY, cfg.minZ, cfg.maxZ))
    print("Workers requested: " .. cfg.workerCount)
    print("Fuel reserve: " .. cfg.fuelReserve .. "   Inventory threshold: " .. cfg.inventoryReturnThreshold)
    print("Liquid policy: " .. cfg.liquidPolicy .. "   Cleanup pass: " .. tostring(cfg.cleanupPass))
    print(string.format("Unload point: (%d,%d,%d) facing %s", cfg.unloadPoint.x, cfg.unloadPoint.y, cfg.unloadPoint.z, cfg.unloadPoint.direction))
    if cfg.depotPoint then
        local dp = cfg.depotPoint
        print(string.format("Depot: (%d,%d,%d) facing %s", dp.x, dp.y, dp.z, directions.name(dp.facing)))
    else
        print("Depot: not configured (workers must be placed exactly at their starting_position)")
    end
    if state.jobId then print("Active job: " .. state.jobId) end
end

function commands.validate()
    if not state.config then print("No configuration set. Run 'new' first."); return end
    local ok, errs = validation.validateConfig(state.config, { availableWorkers = #registeredWorkerIds() })
    if ok then
        print("Configuration is valid.")
    else
        print("Configuration has " .. #errs .. " problem(s):")
        for _, e in ipairs(errs) do print("  - " .. e) end
    end
end

function commands.partition()
    if not state.config then print("No configuration set. Run 'new' first."); return end
    local parts, info = partitionLib.compute(bounds(state.config), state.config.workerCount)
    state.partitions = parts
    saveState()
    print(string.format("Quarry volume: %d blocks. Using %d of %d requested workers (%d idle).",
        info.volume, info.usedWorkers, info.requestedWorkers, info.idleWorkers))
    for i, p in ipairs(parts) do
        print(string.format("  slot %d: X[%d,%d] Y[%d,%d] Z[%d,%d]  (%d blocks)",
            i, p.partition_min_x, p.partition_max_x, p.partition_min_y, p.partition_max_y,
            p.partition_min_z, p.partition_max_z, p.volume))
    end
end

function commands.dryrun()
    if not state.config then print("No configuration set. Run 'new' first."); return end
    local parts, info = partitionLib.compute(bounds(state.config), state.config.workerCount)
    print(string.format("DRY RUN -- no blocks will be broken, no turtles will move."))
    print(string.format("Quarry volume: %d blocks across %d worker(s).", info.volume, info.usedWorkers))
    local up = state.config.unloadPoint
    for i, p in ipairs(parts) do
        local start = traversal.startCell(p)
        local outDist = math.abs(start.x - up.x) + math.abs(start.y - up.y) + math.abs(start.z - up.z)
        -- Rough fuel estimate: every block mined costs >=1 movement,
        -- plus at least one round trip to the unload point.
        local estMovement = p.volume + 2 * outDist
        print(string.format("  slot %d: start=(%d,%d,%d) volume=%d est. min. movement=%d (incl. 1 return trip)",
            i, start.x, start.y, start.z, p.volume, estMovement))
    end
    print("Configure fuelReserve comfortably above the largest estimate shown above.")
end

function commands.deploy()
    if not state.partitions then print("Run 'partition' first."); return end
    local ids = registeredWorkerIds()
    if #ids < #state.partitions then
        print(string.format("Only %d worker(s) registered, but %d partition(s) computed. Register more workers or re-partition with fewer.",
            #ids, #state.partitions))
        return
    end
    if not confirm(string.format("Deploy %d job(s) to registered workers?", #state.partitions)) then
        print("Deployment aborted.")
        return
    end

    state.jobId = newJobId()
    comm:setJobId(state.jobId)
    local cfgCopy = state.config

    for i, p in ipairs(state.partitions) do
        local workerId = ids[i]
        local start = traversal.startCell(p)
        local job = {
            protocol = protocol.NAME,
            job_id = state.jobId,
            worker_id = workerId,
            quarry_min_x = state.config.minX, quarry_max_x = state.config.maxX,
            quarry_min_y = state.config.minY, quarry_max_y = state.config.maxY,
            quarry_min_z = state.config.minZ, quarry_max_z = state.config.maxZ,
            partition_min_x = p.partition_min_x, partition_max_x = p.partition_max_x,
            partition_min_y = p.partition_min_y, partition_max_y = p.partition_max_y,
            partition_min_z = p.partition_min_z, partition_max_z = p.partition_max_z,
            starting_position = { x = start.x, y = start.y, z = start.z },
            starting_facing = 0, -- operator must face all workers north before deploy; see docs/SETUP.md
            configuration = {
                version = protocol.VERSION,
                fuelReserve = cfgCopy.fuelReserve,
                inventoryReturnThreshold = cfgCopy.inventoryReturnThreshold,
                liquidPolicy = cfgCopy.liquidPolicy,
                ignoredBlocks = cfgCopy.ignoredBlocks,
                unloadPoint = cfgCopy.unloadPoint,
                depotPoint = cfgCopy.depotPoint,
            },
        }
        state.slotWorker[i] = workerId
        state.workers[workerId] = state.workers[workerId] or {}
        state.workers[workerId].status = "DEPLOYING"
        state.workers[workerId].slot = i
        print("Assigning slot " .. i .. " to worker " .. workerId .. " ...")
        local ok = comm:sendReliable(workerId, protocol.TYPES.JOB_ASSIGN, job, { maxRetries = 5, ackTimeout = 2 })
        if ok then
            state.workers[workerId].status = "ASSIGNED"
            print("  worker " .. workerId .. " accepted the job.")
        else
            state.workers[workerId].status = "ASSIGN_FAILED"
            print("  worker " .. workerId .. " did not acknowledge the job assignment (offline or out of range).")
        end
    end
    state.deployed = true
    saveState()
    print("Deployment complete. Run 'start' when ready to begin mining.")
end

function commands.start()
    if not state.deployed then print("No job deployed yet. Run 'deploy' first."); return end
    if not confirm("This will command all assigned workers to START MINING.") then
        print("Start aborted.")
        return
    end
    for slot, workerId in pairs(state.slotWorker) do
        if state.workers[workerId] and state.workers[workerId].status == "ASSIGNED" then
            local ok = comm:sendReliable(workerId, protocol.TYPES.START, {}, { maxRetries = 5, ackTimeout = 2 })
            state.workers[workerId].status = ok and "MINING" or "START_FAILED"
            print("  worker " .. workerId .. " (slot " .. slot .. "): " .. (ok and "started" or "failed to confirm start"))
        end
    end
    state.started = true
    saveState()
end

local function broadcastCommand(msgType, label)
    local ids = registeredWorkerIds()
    for _, id in ipairs(ids) do
        if state.workers[id] and state.workers[id].slot then
            local ok = comm:sendReliable(id, msgType, {}, { maxRetries = 3, ackTimeout = 2 })
            print("  worker " .. id .. ": " .. (ok and (label .. " acknowledged") or "no response"))
        end
    end
end

function commands.pause()
    broadcastCommand(protocol.TYPES.PAUSE, "pause")
    saveState()
end
commands.stop = commands.pause

function commands.resume()
    broadcastCommand(protocol.TYPES.RESUME, "resume")
    saveState()
end

function commands.cancel()
    if not confirm("This will PERMANENTLY cancel the active job for all workers.") then
        print("Cancel aborted.")
        return
    end
    broadcastCommand(protocol.TYPES.CANCEL, "cancel")
    state.deployed = false
    state.started = false
    saveState()
end

function commands.estop()
    if not confirm("EMERGENCY STOP: all workers will halt immediately and require a new job to resume.") then
        print("Emergency stop aborted.")
        return
    end
    broadcastCommand(protocol.TYPES.ESTOP, "estop")
    saveState()
end

local function statusLine(id, w)
    local last = w.last or {}
    local pct = last.progress and string.format("%3d%%", math.floor(last.progress * 100 + 0.5)) or "  ?%"
    return string.format("  #%-4d %-16s %s  fuel=%s inv=%s",
        id, w.status or "UNKNOWN", pct, tostring(last.fuel), tostring(last.inventoryUtilization))
end

function commands.status()
    if state.jobId then
        print("QUARRY JOB: " .. state.jobId)
    else
        print("No active job.")
    end
    if state.config then
        local c = state.config
        print(string.format("Bounds: X[%d,%d] Y[%d,%d] Z[%d,%d]", c.minX, c.maxX, c.minY, c.maxY, c.minZ, c.maxZ))
    end
    print("Workers:")
    local totalVol, doneVol = 0, 0
    for slot, id in pairs(state.slotWorker) do
        local w = state.workers[id]
        if w then
            print(statusLine(id, w))
            if state.partitions and state.partitions[slot] then
                totalVol = totalVol + state.partitions[slot].volume
                local p = (w.last and w.last.progress) or 0
                doneVol = doneVol + p * state.partitions[slot].volume
            end
        end
    end
    if totalVol > 0 then
        print(string.format("Overall progress: %.1f%%", (doneVol / totalVol) * 100))
    end
end

function commands.worker(idStr)
    local id = tonumber(idStr)
    if not id or not state.workers[id] then print("Unknown worker id."); return end
    local w = state.workers[id]
    print("Worker " .. id .. " (" .. tostring(w.label) .. ")")
    print("  status: " .. tostring(w.status) .. "   slot: " .. tostring(w.slot))
    print("  last seen: " .. tostring(w.lastSeen) .. "   missed heartbeats: " .. tostring(w.misses or 0))
    if w.last then
        print(string.format("  position=(%s,%s,%s) fuel=%s inventory=%s progress=%s lastError=%s",
            tostring(w.last.x), tostring(w.last.y), tostring(w.last.z),
            tostring(w.last.fuel), tostring(w.last.inventoryUtilization),
            tostring(w.last.progress), tostring(w.last.lastError)))
    end
end

function commands.recover()
    loadState()
end
commands.load = commands.recover

function commands.save()
    saveState()
    print("Session saved.")
end

function commands.quit()
    print("Exiting master UI. Workers continue running independently.")
    error("__QUARRY_QUIT__", 0)
end
commands.exit = commands.quit

----------------------------------------------------------------------
-- Command loop
----------------------------------------------------------------------

local function commandLoop()
    print("Quarry master ready. Type 'help' for commands.")
    while true do
        write("quarry> ")
        local line = read()
        if line and line ~= "" then
            local parts = {}
            for word in line:gmatch("%S+") do parts[#parts + 1] = word end
            local cmdName = table.remove(parts, 1)
            local fn = commands[cmdName]
            if fn then
                local ok, err = pcall(fn, table.unpack(parts))
                if not ok then
                    if err == "__QUARRY_QUIT__" then error(err, 0) end
                    print("Error: " .. tostring(err))
                    log:error("command failed", { operation = cmdName, error = tostring(err) })
                end
            else
                print("Unknown command '" .. cmdName .. "'. Type 'help' for a list.")
            end
        end
    end
end

----------------------------------------------------------------------
-- Background message loop
----------------------------------------------------------------------

local function touchWorker(id, label)
    state.workers[id] = state.workers[id] or { status = "REGISTERED" }
    state.workers[id].label = label or state.workers[id].label
    state.workers[id].lastSeen = os.clock()
    state.workers[id].misses = 0
end

local function handleMessage(from, msg)
    if msg.type == protocol.TYPES.REGISTER then
        touchWorker(from, msg.payload and msg.payload.label)
        comm:sendAck(from, msg)
        log:info("worker registered", { workerId = from })
    elseif msg.type == protocol.TYPES.HEARTBEAT or msg.type == protocol.TYPES.STATUS then
        touchWorker(from)
        state.workers[from].last = msg.payload
        if msg.payload and msg.payload.state then
            state.workers[from].status = msg.payload.state
        end
    elseif msg.type == protocol.TYPES.COMPLETE then
        touchWorker(from)
        state.workers[from].status = "COMPLETED"
        state.workers[from].last = msg.payload
        comm:sendAck(from, msg)
        log:info("worker reported completion", { workerId = from })
        saveState()
    end
end

local function checkHeartbeatTimeouts()
    local now = os.clock()
    for id, w in pairs(state.workers) do
        if w.lastSeen and (now - w.lastSeen) > HEARTBEAT_TIMEOUT then
            w.misses = (w.misses or 0) + 1
            w.lastSeen = now -- avoid re-counting the same silence window repeatedly
            if w.misses >= HEARTBEAT_MISSES_DEAD then
                if w.status ~= "UNRESPONSIVE" then
                    log:warn("worker unresponsive", { workerId = id, misses = w.misses })
                end
                w.status = "UNRESPONSIVE"
            end
        end
    end
end

local function messageLoop()
    while true do
        local from, msg = comm:pull(2)
        if msg then handleMessage(from, msg) end
        checkHeartbeatTimeouts()
    end
end

----------------------------------------------------------------------
-- Run
----------------------------------------------------------------------

loadState()
log:info("master starting", { selfId = selfId })

-- Test-only hook (see tests/test_master_integration.lua): exposes the
-- otherwise-local `commands`/`state`/`handleMessage` so a test can
-- drive the command flow and background message handling directly,
-- without needing a real interactive terminal or the parallel event
-- loop. Always nil in real deployment.
if _G.__QUARRY_TEST_MODE then
    _G.__QUARRY_DEBUG_MASTER = { commands = commands, state = state, handleMessage = handleMessage, comm = comm }
else
    local ok, err = pcall(parallel.waitForAny, commandLoop, messageLoop)
    if not ok and err ~= "__QUARRY_QUIT__" then
        log:error("master crashed", { error = tostring(err) })
        print("Fatal error: " .. tostring(err))
    end
end
