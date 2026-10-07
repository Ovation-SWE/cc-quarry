--- Quarry worker main program. Runs on a mining turtle. Loaded by
--- startup.lua on every boot. See docs/ARCHITECTURE.md for the full
--- state machine diagram and rationale.
--
-- This file is intentionally a thin orchestration layer: all
-- fallible logic (movement, digging, fuel, inventory, GPS, comms,
-- persistence) lives in lib/*.lua, which is unit-tested in tests/
-- against mocks. worker.lua wires those tested pieces together and
-- drives the state machine described in docs/ARCHITECTURE.md.

package.path = "lib/?.lua;" .. package.path

local directions = require("directions")
local navigation = require("navigation")
local mining = require("mining")
local traversal = require("traversal")
local fuel = require("fuel")
local inventory = require("inventory")
local gpsnav = require("gpsnav")
local protocol = require("protocol")
local comms = require("comms")
local persistence = require("persistence")
local validation = require("validation")
local logging = require("logging")
local state_machine = require("state_machine")

local STATE_PATH = "state"
local HEARTBEAT_INTERVAL = 10 -- seconds
local GPS_RECONCILE_INTERVAL = 8 -- mining steps between GPS checks

----------------------------------------------------------------------
-- Setup
----------------------------------------------------------------------

local log = logging.new({ path = "log.txt", level = "normal" })
local persist = persistence.new()

local modem = peripheral.find("modem", function(_, p) return p.isWireless and p.isWireless() end)
    or peripheral.find("modem")
if not modem then
    log:error("no wireless modem found; cannot operate without comms")
    print("FATAL: no wireless modem attached (left/right equip slot). Halting.")
    return
end
local modemSide = peripheral.getName(modem)
rednet.open(modemSide)

local selfId = os.getComputerID()
local comm = comms.new({ selfId = selfId, log = log })

local ctx = {
    comm = comm,
    log = log,
    persist = persist,
    selfId = selfId,
    job = nil,
    masterId = nil,
    pendingJob = nil,
    pendingFrom = nil,
    pendingSeq = nil,
    lastError = nil,
    lastHeartbeat = 0,
    stepsSinceGpsCheck = 0,
    returnPhase = nil,
    savedPosition = nil,
}

----------------------------------------------------------------------
-- Helpers
----------------------------------------------------------------------

local function jobPartition(job)
    return job -- job already carries partition_min_x .. partition_max_z fields directly
end

local function buildSubsystems(ctx, navState)
    local cfg = ctx.job.configuration
    ctx.nav = navigation.new({
        turtle = turtle,
        log = ctx.log,
        obstacleHandler = function(kind)
            -- NAVIGATING_TO_START (the depot-to-starting_position leg,
            -- see steps.COLLECTING_RESOURCES) is outside the worker's
            -- assigned partition by definition, so it uses the
            -- partition-free transitMining instance instead of the
            -- normal partition-fenced one -- see transitMining below.
            local m = ctx.sm:is("NAVIGATING_TO_START") and ctx.transitMining or ctx.mining
            return m:clear(kind)
        end,
    }, navState)
    ctx.mining = mining.new({
        turtle = turtle,
        nav = ctx.nav,
        log = ctx.log,
        partition = jobPartition(ctx.job),
        ignoredBlocks = cfg.ignoredBlocks,
        liquidPolicy = cfg.liquidPolicy,
        sealBlockSlot = cfg.sealBlockSlot,
    })
    -- Partition-free twin of ctx.mining, used only while traveling
    -- from an optional configured depotPoint to starting_position
    -- (steps.NAVIGATING_TO_START). That leg is necessarily outside
    -- the partition, so the normal instance's partition fence
    -- (lib/mining.lua's out_of_partition check) would refuse every
    -- dig along the way. Liquid safety (never walking into lava) is
    -- still enforced identically -- only the partition fence differs.
    ctx.transitMining = mining.new({
        turtle = turtle,
        nav = ctx.nav,
        log = ctx.log,
        partition = nil,
        ignoredBlocks = cfg.ignoredBlocks,
        liquidPolicy = cfg.liquidPolicy,
        sealBlockSlot = cfg.sealBlockSlot,
    })
    ctx.fuel = fuel.new({
        turtle = turtle,
        reserve = cfg.fuelReserve or 0,
        refuelSlots = cfg.refuelSlots,
        log = ctx.log,
    })
    ctx.inv = inventory.new({
        turtle = turtle,
        reservedSlots = cfg.reservedSlots or {},
        discardBlocks = cfg.discardBlocks or {},
        log = ctx.log,
    })
    ctx.gpsnav = gpsnav.new({ nav = ctx.nav, log = ctx.log })
    -- nav's obstacleHandler closure (set above, before ctx.mining/
    -- ctx.transitMining exist yet) reads both by upvalue at call time,
    -- so it's already correct once this function returns -- no
    -- separate rebuild step needed.
end

local function snapshot(ctx)
    return {
        job = ctx.job,
        nav = ctx.nav and ctx.nav:serialize() or nil,
        status = ctx.sm and ctx.sm:getState() or "BOOT",
        returnPhase = ctx.returnPhase,
        savedPosition = ctx.savedPosition,
        lastError = ctx.lastError,
        masterId = ctx.masterId,
    }
end

local function checkpoint(ctx)
    local ok, err = ctx.persist:save(STATE_PATH, snapshot(ctx))
    if not ok then
        ctx.log:error("checkpoint save failed", { error = err })
    end
end

local function progressPayload(ctx)
    local x, y, z = 0, 0, 0
    if ctx.nav then x, y, z = ctx.nav:getPosition() end
    local progress = nil
    if ctx.job then
        local vol = traversal.volume(jobPartition(ctx.job))
        local idx = traversal.indexOf(jobPartition(ctx.job), x, y, z)
        progress = vol > 0 and (idx / vol) or 1
    end
    return {
        state = ctx.sm and ctx.sm:getState() or "BOOT",
        x = x, y = y, z = z,
        fuel = ctx.fuel and ctx.fuel:level() or turtle.getFuelLevel(),
        inventoryUtilization = ctx.inv and ctx.inv:utilization() or 0,
        progress = progress,
        lastError = ctx.lastError,
    }
end

local function maybeSendHeartbeat(ctx)
    local now = os.clock()
    if now - ctx.lastHeartbeat < HEARTBEAT_INTERVAL then return end
    ctx.lastHeartbeat = now
    if ctx.masterId then
        ctx.comm:sendFireAndForget(ctx.masterId, protocol.TYPES.HEARTBEAT, progressPayload(ctx))
    end
end

--- What state RESUME should return to: the most recent state the
--- worker was actually interrupted from, read off ctx.sm's own
--- transition history (lib/state_machine.lua records {from,to,event}
--- on every transition already -- no separate bookkeeping needed).
--- Scans backward past repeated PAUSED<->PAUSED/ERROR<->ERROR entries
--- (e.g. re-pausing while already paused) to find the real source
--- state. Resuming unconditionally into "MINING" would be wrong now
--- that COLLECTING_RESOURCES/NAVIGATING_TO_START are real multi-step
--- processes that can themselves error out (e.g. an empty depot, or
--- a blocked transit path) -- resume must return there, not skip
--- straight to mining from wherever the turtle currently stands.
local function resumeTargetState(ctx)
    local history = ctx.sm.history
    local current = ctx.sm:getState()
    for i = #history, 1, -1 do
        local h = history[i]
        if h.to == current and h.from ~= "PAUSED" and h.from ~= "ERROR" then
            return h.from
        end
    end
    return "MINING"
end

--- Handle a control message that can arrive in almost any state.
--- Returns true if it was handled here (caller should re-check state).
local function handleControlMessage(ctx, from, msg)
    if msg.type == protocol.TYPES.PAUSE then
        ctx.comm:sendAck(from, msg)
        if not ctx.sm:is("EMERGENCY_STOP") then ctx.sm:transition("PAUSED", "master_pause") end
        return true
    elseif msg.type == protocol.TYPES.RESUME then
        ctx.comm:sendAck(from, msg)
        if ctx.sm:is("PAUSED") or ctx.sm:is("ERROR") then
            ctx.sm:transition(resumeTargetState(ctx), "master_resume")
        end
        return true
    elseif msg.type == protocol.TYPES.CANCEL then
        ctx.comm:sendAck(from, msg)
        if not ctx.sm:is("EMERGENCY_STOP") then
            ctx.lastError = "cancelled_by_master"
            ctx.sm:transition("COMPLETED", "master_cancel")
        end
        return true
    elseif msg.type == protocol.TYPES.ESTOP then
        ctx.comm:sendAck(from, msg)
        ctx.sm:transition("EMERGENCY_STOP", "master_estop")
        return true
    elseif msg.type == protocol.TYPES.STATUS then
        ctx.comm:sendFireAndForget(from, protocol.TYPES.STATUS, progressPayload(ctx))
        return true
    elseif msg.type == protocol.TYPES.START then
        ctx.comm:sendAck(from, msg)
        if ctx.sm:is("ASSIGNED") then
            local hasDepot = ctx.job.configuration.depotPoint ~= nil
            ctx.sm:transition(hasDepot and "COLLECTING_RESOURCES" or "NAVIGATING_TO_START", "master_start")
        end
        return true
    elseif msg.type == protocol.TYPES.JOB_ASSIGN then
        -- Idempotent re-ack of an assignment we already accepted;
        -- never restart an in-progress job from a duplicate/retried
        -- assignment message.
        ctx.comm:sendAck(from, msg)
        return true
    end
    return false
end

----------------------------------------------------------------------
-- State step functions
----------------------------------------------------------------------

local steps = {}

function steps.BOOT(ctx)
    local data = ctx.persist:load(STATE_PATH)
    if data and data.job then
        ctx.job = data.job
        ctx.masterId = data.masterId
        ctx.returnPhase = data.returnPhase
        ctx.savedPosition = data.savedPosition
        ctx.lastError = data.lastError
        ctx.comm:setJobId(ctx.job.job_id)
        buildSubsystems(ctx, data.nav)
        ctx.log:info("resumed persisted job", { jobId = ctx.job.job_id, state = data.status })

        if data.status == "EMERGENCY_STOP" then
            ctx.sm:transition("EMERGENCY_STOP", "boot_resume_estop")
        elseif data.status == "COMPLETED" then
            ctx.sm:transition("COMPLETED", "boot_resume_completed")
        else
            -- Remember exactly which state we were in (ASSIGNED still
            -- waiting for start / NAVIGATING_TO_START / MINING /
            -- INVENTORY_RETURN / FUEL_RETURN / PAUSED / ERROR) so
            -- RECOVERING resumes into that same state rather than
            -- guessing "MINING" for everything -- e.g. a worker that
            -- rebooted while still waiting for the master's `start`
            -- command must go back to waiting, not start moving on
            -- its own.
            ctx.resumeStatus = data.status
            ctx.sm:transition("RECOVERING", "boot_resume")
        end
    else
        ctx.sm:transition("REGISTERING", "boot_fresh")
    end
end

function steps.RECOVERING(ctx)
    ctx.gpsnav:reconcile()
    if not ctx.nav:isTrusted() then
        ctx.lastError = "position_untrusted_after_reboot:" .. tostring(ctx.nav.untrustedReason)
        ctx.log:error("cannot safely resume: position untrusted", { error = ctx.lastError })
        ctx.sm:transition("ERROR", "recovery_failed")
        return
    end
    ctx.log:info("recovery successful, resuming job", { x = ctx.nav.x, y = ctx.nav.y, z = ctx.nav.z })
    local target = ctx.resumeStatus or "MINING"
    ctx.resumeStatus = nil
    ctx.sm:transition(target, "resume_" .. target:lower())
end

function steps.REGISTERING(ctx)
    local seq = ctx.comm:broadcast(protocol.TYPES.REGISTER, { computerId = ctx.selfId, label = os.getComputerLabel() })
    local from, msg = ctx.comm:waitFor(function(_, m)
        return m.type == protocol.TYPES.ACK and m.ackFor == seq
    end, 3)
    if msg then
        ctx.masterId = from
        ctx.log:info("registered with master", { masterId = from })
        ctx.sm:transition("WAITING_FOR_JOB", "registered")
    else
        sleep(2)
    end
end

function steps.WAITING_FOR_JOB(ctx)
    local from, msg = ctx.comm:waitFor(function(_, m) return m.type == protocol.TYPES.JOB_ASSIGN end, 5)
    if msg then
        local ok, jobErrs = validation.validateJob(msg.payload, ctx.selfId)
        if ok then
            ctx.pendingJob = msg.payload
            ctx.pendingFrom = from
            ctx.pendingSeq = msg.sequence
            ctx.sm:transition("VALIDATING_JOB", "job_received")
        else
            ctx.log:error("rejected malformed job assignment", { error = table.concat(jobErrs, "; ") })
        end
    else
        -- Re-announce periodically in case the master restarted and
        -- lost its worker registry.
        ctx.comm:broadcast(protocol.TYPES.REGISTER, { computerId = ctx.selfId, label = os.getComputerLabel() })
    end
end

function steps.VALIDATING_JOB(ctx)
    local ok, jobErrs = validation.validateJob(ctx.pendingJob, ctx.selfId)
    if not ok then
        ctx.log:error("pending job failed re-validation", { error = table.concat(jobErrs, "; ") })
        ctx.sm:transition("WAITING_FOR_JOB", "job_invalid")
        return
    end
    ctx.job = ctx.pendingJob
    ctx.masterId = ctx.pendingFrom
    ctx.comm:setJobId(ctx.job.job_id)
    -- If the job configures a depotPoint (opt-in; see docs/SETUP.md),
    -- seed dead reckoning there instead of at starting_position: the
    -- operator placed the turtle at the depot, not at the job site,
    -- and steps.COLLECTING_RESOURCES/NAVIGATING_TO_START handle the
    -- real journey from one to the other. Without a depotPoint, this
    -- is exactly today's behavior: trust the operator placed the
    -- turtle at starting_position already.
    local depot = ctx.job.configuration.depotPoint
    local start = ctx.job.starting_position
    local seed = depot
        and { x = depot.x, y = depot.y, z = depot.z, facing = depot.facing }
        or { x = start.x, y = start.y, z = start.z, facing = ctx.job.starting_facing }
    buildSubsystems(ctx, seed)
    ctx.comm:sendAck(ctx.pendingFrom, { jobId = ctx.job.job_id, sequence = ctx.pendingSeq })
    ctx.sm:transition("ASSIGNED", "job_validated")
end

function steps.ASSIGNED(ctx)
    if not ctx.assignedCheckpointed then
        checkpoint(ctx)
        ctx.assignedCheckpointed = true
    end
    -- Wait here until the master explicitly sends START (see spec:
    -- "start" is a distinct, confirmed command from "deploy"). A
    -- worker must never begin moving/mining just because it accepted
    -- a job assignment.
    local from, msg = ctx.comm:pull(3)
    if msg then handleControlMessage(ctx, from, msg) end
end

--- Only entered when the job configures a depotPoint (see
--- handleControlMessage's START case). The worker was placed at the
--- depot, not starting_position -- buildSubsystems seeded nav there.
--- Top up fuel from whatever the turtle is facing (turtle.suck(),
--- which costs no fuel, so this works even from an empty tank -- see
--- docs/SETUP.md's depot/staging-pad workflow) before attempting the
--- real journey to starting_position in steps.NAVIGATING_TO_START.
function steps.COLLECTING_RESOURCES(ctx)
    ctx.gpsnav:reconcile()
    if not ctx.nav:isTrusted() then
        ctx.lastError = "position_untrusted:" .. tostring(ctx.nav.untrustedReason)
        ctx.sm:transition("ERROR", "position_untrusted")
        return
    end
    local start = ctx.job.starting_position
    local targetLevel = ctx.nav:distanceTo(start.x, start.y, start.z) + (ctx.job.configuration.fuelReserve or 0)
    local ok, err = ctx.fuel:collectFromDepot(targetLevel)
    checkpoint(ctx)
    if ok then
        ctx.sm:transition("NAVIGATING_TO_START", "depot_collected")
    else
        ctx.lastError = "depot_collection_failed:" .. tostring(err)
        ctx.log:error("failed to collect fuel at depot", { error = err })
        ctx.sm:transition("ERROR", "depot_empty")
    end
end

function steps.NAVIGATING_TO_START(ctx)
    ctx.gpsnav:reconcile()
    if not ctx.nav:isTrusted() then
        ctx.lastError = "position_untrusted:" .. tostring(ctx.nav.untrustedReason)
        ctx.sm:transition("ERROR", "position_untrusted")
        return
    end
    local start = ctx.job.starting_position
    if ctx.nav.x == start.x and ctx.nav.y == start.y and ctx.nav.z == start.z then
        ctx.sm:transition("MINING", "arrived_at_start")
        return
    end
    local distance = ctx.nav:distanceTo(start.x, start.y, start.z)
    if not ctx.fuel:hasEnoughFor(distance) then
        ctx.lastError = "insufficient_fuel_for_transit"
        ctx.log:error("not enough fuel to reach starting position", { distance = distance, fuel = ctx.fuel:level() })
        ctx.sm:transition("ERROR", "insufficient_fuel_for_transit")
        return
    end
    local ok, err = ctx.nav:moveTo(start.x, start.y, start.z)
    checkpoint(ctx)
    if ok then
        ctx.sm:transition("MINING", "arrived_at_start")
    else
        ctx.lastError = "navigate_to_start_failed:" .. tostring(err)
        ctx.log:error("failed to reach starting position", { error = err })
        ctx.sm:transition("ERROR", "navigation_failed")
    end
end

local function clearedMove(ctx, kind)
    local cok, cerr = ctx.mining:clear(kind)
    if not cok then return false, cerr end
    return ctx.nav[kind](ctx.nav)
end

function steps.MINING(ctx)
    local from, msg = ctx.comm:pull(0.1)
    if msg then
        handleControlMessage(ctx, from, msg)
        if not ctx.sm:is("MINING") then return end
    end
    maybeSendHeartbeat(ctx)

    ctx.stepsSinceGpsCheck = ctx.stepsSinceGpsCheck + 1
    if ctx.stepsSinceGpsCheck >= GPS_RECONCILE_INTERVAL then
        ctx.stepsSinceGpsCheck = 0
        ctx.gpsnav:reconcile()
        if not ctx.nav:isTrusted() then
            ctx.lastError = "position_untrusted:" .. tostring(ctx.nav.untrustedReason)
            ctx.sm:transition("ERROR", "position_untrusted")
            return
        end
    end

    if ctx.inv:isFull() or ctx.inv:utilization() >= (ctx.job.configuration.inventoryReturnThreshold or 0.9) then
        ctx.sm:transition("INVENTORY_RETURN", "inventory_threshold")
        return
    end

    local up = ctx.job.configuration.unloadPoint
    local distBack = up and ctx.nav:distanceTo(up.x, up.y, up.z) or 0
    if not ctx.fuel:hasEnoughFor(1 + distBack) then
        local rok = ctx.fuel:autoRefuel(distBack + (ctx.job.configuration.fuelReserve or 0) + 64)
        if not rok then
            ctx.sm:transition("FUEL_RETURN", "fuel_low")
            return
        end
    end

    local x, y, z = ctx.nav:getPosition()
    local target = traversal.nextCell(jobPartition(ctx.job), x, y, z)
    if not target then
        ctx.sm:transition("COMPLETED", "partition_finished")
        return
    end

    local ok, err
    if target.y ~= y then
        ok, err = clearedMove(ctx, target.y > y and "up" or "down")
    elseif target.x ~= x then
        ctx.nav:face(target.x > x and directions.EAST or directions.WEST)
        ok, err = clearedMove(ctx, "forward")
    else
        ctx.nav:face(target.z > z and directions.SOUTH or directions.NORTH)
        ok, err = clearedMove(ctx, "forward")
    end

    if not ok then
        ctx.lastError = "mining_blocked:" .. tostring(err)
        ctx.log:error("mining step failed", { error = err, x = x, y = y, z = z })
        checkpoint(ctx)
        ctx.sm:transition("ERROR", "mining_blocked")
        return
    end
    checkpoint(ctx)
end

--- Shared logic for INVENTORY_RETURN and FUEL_RETURN: travel to the
--- configured waypoint, perform an action, travel back to the exact
--- saved mining position, then resume mining. `performFn(ctx)` does
--- the state-specific action (unload / refuel) once at the waypoint.
local function stepReturnTrip(ctx, performFn, phaseName)
    if not ctx.savedPosition then
        local x, y, z, facing = ctx.nav:getPosition()
        ctx.savedPosition = { x = x, y = y, z = z, facing = facing }
        ctx.returnPhase = "traveling_out"
        checkpoint(ctx)
    end

    local up = ctx.job.configuration.unloadPoint
    if ctx.returnPhase == "traveling_out" then
        local ok, err = ctx.nav:moveTo(up.x, up.y, up.z)
        checkpoint(ctx)
        if not ok then
            ctx.lastError = phaseName .. "_travel_out_failed:" .. tostring(err)
            ctx.sm:transition("ERROR", "return_trip_blocked")
            return
        end
        ctx.returnPhase = "acting"
        checkpoint(ctx)
        return
    end

    if ctx.returnPhase == "acting" then
        local ok, err = performFn(ctx)
        if not ok then
            ctx.lastError = phaseName .. "_action_failed:" .. tostring(err)
            ctx.log:error(phaseName .. " failed at waypoint", { error = err })
            checkpoint(ctx)
            ctx.sm:transition("ERROR", "return_action_failed")
            return
        end
        ctx.returnPhase = "traveling_back"
        checkpoint(ctx)
        return
    end

    if ctx.returnPhase == "traveling_back" then
        local sp = ctx.savedPosition
        local ok, err = ctx.nav:moveTo(sp.x, sp.y, sp.z)
        if ok then ok, err = ctx.nav:face(sp.facing) end
        checkpoint(ctx)
        if not ok then
            ctx.lastError = phaseName .. "_travel_back_failed:" .. tostring(err)
            ctx.sm:transition("ERROR", "return_trip_blocked")
            return
        end
        ctx.returnPhase = nil
        ctx.savedPosition = nil
        checkpoint(ctx)
        ctx.sm:transition("MINING", phaseName .. "_complete")
    end
end

function steps.INVENTORY_RETURN(ctx)
    stepReturnTrip(ctx, function(c)
        local up = c.job.configuration.unloadPoint
        c.inv:consolidate()
        return c.inv:unload(up.direction)
    end, "inventory_return")
end

function steps.FUEL_RETURN(ctx)
    stepReturnTrip(ctx, function(c)
        return c.fuel:ensure((c.job.configuration.fuelReserve or 0) + 200)
    end, "fuel_return")
end

function steps.PAUSED(ctx)
    local from, msg = ctx.comm:pull(1)
    if msg then handleControlMessage(ctx, from, msg) end
end

function steps.ERROR(ctx)
    if ctx.masterId then
        ctx.comm:sendFireAndForget(ctx.masterId, protocol.TYPES.STATUS, progressPayload(ctx))
    end
    local from, msg = ctx.comm:pull(2)
    if msg then handleControlMessage(ctx, from, msg) end
end

--- Shared by COMPLETED and EMERGENCY_STOP: both are terminal states
--- for the *current* job, but a worker should be reusable for a
--- future one without requiring a manual reboot/state wipe. Only a
--- genuinely new job_id is honored -- a duplicate/retried assignment
--- for the job just finished (or the one that triggered the estop)
--- must not restart anything, matching the stale/duplicate-message
--- handling used everywhere else in this protocol. Returns true if a
--- new job was accepted (caller should not also treat msg as unhandled).
local function acceptNewJob(ctx, from, msg, event)
    if not (msg and msg.type == protocol.TYPES.JOB_ASSIGN) then
        return false
    end
    local ok = validation.validateJob(msg.payload, ctx.selfId)
    if not (ok and msg.payload.job_id ~= (ctx.job and ctx.job.job_id)) then
        return false
    end
    ctx.pendingJob = msg.payload
    ctx.pendingFrom = from
    ctx.pendingSeq = msg.sequence
    ctx.estopReported = false
    ctx.completeReported = false
    ctx.returnPhase = nil
    ctx.savedPosition = nil
    ctx.sm:transition("VALIDATING_JOB", event)
    return true
end

function steps.COMPLETED(ctx)
    if not ctx.completeReported then
        if ctx.masterId then
            ctx.comm:sendReliable(ctx.masterId, protocol.TYPES.COMPLETE, progressPayload(ctx), { maxRetries = 5 })
        end
        ctx.completeReported = true
        checkpoint(ctx)
    end
    local from, msg = ctx.comm:pull(3)
    if msg and not acceptNewJob(ctx, from, msg, "new_job_after_completion") then
        -- Not a fresh job assignment: fall back to normal handling
        -- (STATUS queries, idempotent re-acks, etc).
        handleControlMessage(ctx, from, msg)
    end
end

function steps.EMERGENCY_STOP(ctx)
    if not ctx.estopReported then
        ctx.log:error("EMERGENCY STOP engaged", { error = ctx.lastError })
        checkpoint(ctx)
        ctx.estopReported = true
    end
    -- Only a brand-new job assignment can lift an emergency stop;
    -- RESUME/PAUSE/CANCEL are deliberately not honored here (see
    -- docs/RECOVERY.md) -- everything except a fresh job is just acked.
    local from, msg = ctx.comm:pull(2)
    if msg and not acceptNewJob(ctx, from, msg, "new_job_after_estop") then
        ctx.comm:sendAck(from, msg)
    end
end

----------------------------------------------------------------------
-- Assemble and run
----------------------------------------------------------------------

local STATE_NAMES = {
    "BOOT", "REGISTERING", "WAITING_FOR_JOB", "VALIDATING_JOB", "ASSIGNED",
    "COLLECTING_RESOURCES", "NAVIGATING_TO_START", "MINING", "INVENTORY_RETURN", "FUEL_RETURN",
    "PAUSED", "RECOVERING", "COMPLETED", "ERROR", "EMERGENCY_STOP",
}
local stateSpec = {}
for _, name in ipairs(STATE_NAMES) do stateSpec[name] = {} end

ctx.sm = state_machine.new({ initial = "BOOT", states = stateSpec, context = ctx, log = log })
if _G.__QUARRY_TEST_YIELD_EACH_STEP then _G.__QUARRY_DEBUG_CTX = ctx end

log:info("worker starting", { workerId = selfId, label = os.getComputerLabel() })

-- _G.__QUARRY_TEST_YIELD_EACH_STEP / __QUARRY_TEST_MAX_STEPS are
-- integration-test-only escape hatches (see
-- tests/test_worker_integration.lua): both are nil in real
-- deployment, so this loop runs forever exactly as before. In tests,
-- the whole file is run inside a coroutine that yields after every
-- step, letting the test single-step the worker and script "the
-- master" in between steps within one continuous program state
-- (rather than restarting the script, which would lose in-memory
-- state that isn't persisted to disk, like the pre-job registration
-- handshake).
local __testYield = _G.__QUARRY_TEST_YIELD_EACH_STEP
local __testMaxSteps = _G.__QUARRY_TEST_MAX_STEPS
local __stepCount = 0

while true do
    local ok, err = pcall(function()
        local handler = steps[ctx.sm:getState()]
        handler(ctx)
    end)
    if not ok then
        log:error("unhandled error in step handler", { state = ctx.sm:getState(), error = tostring(err) })
        ctx.lastError = "internal_error:" .. tostring(err)
        if not ctx.sm:is("ERROR") and not ctx.sm:is("EMERGENCY_STOP") then
            ctx.sm:transition("ERROR", "internal_error")
        end
        sleep(1)
    end

    __stepCount = __stepCount + 1
    if __testYield then coroutine.yield() end
    if __testMaxSteps and __stepCount >= __testMaxSteps then return end
end
