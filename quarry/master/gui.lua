--- Quarry master GUI, built on Basalt2 (basalt2.5 API; see
--- https://basalt.madefor.cc/2.5/). Requires an Advanced Computer
--- (color + mouse) -- see docs/SETUP.md. Falls back to master.lua's
--- text UI automatically if basalt.lua isn't installed or the
--- computer has no color terminal (master/startup.lua decides which
--- to launch).
--
-- This file intentionally duplicates master.lua's state/networking
-- glue (setup, saveState/loadState, newJobId, handleMessage,
-- checkHeartbeatTimeouts) rather than refactoring master.lua to
-- share it: master.lua's exact structure (its `commands` table,
-- read()-driven `new` wizard, `__QUARRY_TEST_MODE` hook) is locked
-- down by tests/test_master_integration.lua, so leaving it untouched
-- is the lower-risk choice. Both programs read/write the same
-- `master_state` file, so switching between the CLI and GUI mid-job
-- is safe -- whichever you run next picks up the saved session.
--
-- Everything *below* the glue (lib/*.lua: partitioning, traversal,
-- validation, protocol, comms, persistence) is the same tested code
-- master.lua uses, just driven by button clicks instead of typed
-- commands.

package.path = "lib/?.lua;" .. package.path

local basalt = require("basalt")
local partitionLib = require("partition")
local traversal = require("traversal")
local protocol = require("protocol")
local comms = require("comms")
local persistence = require("persistence")
local validation = require("validation")
local logging = require("logging")

local STATE_PATH = "master_state"
local HEARTBEAT_TIMEOUT = 15
local HEARTBEAT_MISSES_DEAD = 4
local STATUS_REFRESH_SECONDS = 2

----------------------------------------------------------------------
-- Setup (see master.lua for the text-UI twin of this section)
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
    config = nil,
    jobId = nil,
    partitions = nil,
    slotWorker = {},
    workers = {},
    deployed = false,
    started = false,
}

local function saveState()
    local ok, err = persist:save(STATE_PATH, state)
    if not ok then log:error("failed to save master state", { error = err }) end
end

local function loadState()
    local data = persist:load(STATE_PATH)
    if data then
        state = data
        comm:setJobId(state.jobId)
        log:info("master state recovered", { jobId = state.jobId })
    end
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

loadState()
log:info("gui master starting", { selfId = selfId })

----------------------------------------------------------------------
-- Background message handling (identical logic to master.lua)
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
            w.lastSeen = now
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
-- GUI shell: header + tabs
----------------------------------------------------------------------

local main = basalt.getMainFrame()
local screenW, screenH = main:getSize()

main:addLabel({
    x = 1, y = 1, width = screenW, height = 1,
    text = " Quarry Master",
    background = colors.gray, foreground = colors.white,
})

local tabs = main:addTabControl({ x = 1, y = 2, width = screenW, height = screenH - 1 })
local setupTab = tabs:addTab("Setup")
local deployTab = tabs:addTab("Deploy")
local statusTab = tabs:addTab("Status")

----------------------------------------------------------------------
-- Confirmation modal (Basalt2's Dialog API wasn't something we could
-- verify precisely, so this is a plain overlay Frame + Yes/No
-- buttons added directly to `main`, above the tabs, toggled visible).
----------------------------------------------------------------------

local modalW, modalH = math.min(screenW - 4, 44), 7
local modal = main:addFrame({
    x = math.floor((screenW - modalW) / 2) + 1,
    y = math.floor((screenH - modalH) / 2) + 1,
    width = modalW, height = modalH,
    background = colors.black,
    visible = false,
})
local function closeModal()
    modal.visible = false
end

local modalLabel = modal:addLabel({ x = 2, y = 2, width = modalW - 2, height = 3, text = "" })
local modalYes = modal:addButton({ x = 2, y = modalH - 2, width = 10, text = "Yes", background = colors.red, foreground = colors.white })
local modalNo = modal:addButton({ x = modalW - 11, y = modalH - 2, width = 10, text = "No", background = colors.gray, foreground = colors.white })

local pendingConfirm = nil
modalYes:onClick(function()
    local action = pendingConfirm
    closeModal()
    if action then action() end
end)
modalNo:onClick(function()
    closeModal()
end)

local function confirmAction(message, action)
    modalLabel.text = message
    pendingConfirm = action
    modal.visible = true
end

----------------------------------------------------------------------
-- Setup tab: configuration form
----------------------------------------------------------------------

local function labeledInput(parent, x, y, labelText, labelWidth, inputWidth, default)
    parent:addLabel({ x = x, y = y, width = labelWidth, height = 1, text = labelText })
    return parent:addInput({
        x = x + labelWidth + 1, y = y, width = inputWidth,
        text = default ~= nil and tostring(default) or "",
    })
end

local cfg0 = state.config or {}
local up0 = cfg0.unloadPoint or {}

-- Left column: quarry bounds.
setupTab:addLabel({ x = 2, y = 1, text = "Quarry bounds", foreground = colors.yellow })
local minXIn = labeledInput(setupTab, 2, 2, "min X", 6, 6, cfg0.minX or 0)
local maxXIn = labeledInput(setupTab, 2, 3, "max X", 6, 6, cfg0.maxX or 0)
local minYIn = labeledInput(setupTab, 2, 4, "min Y", 6, 6, cfg0.minY or 0)
local maxYIn = labeledInput(setupTab, 2, 5, "max Y", 6, 6, cfg0.maxY or 0)
local minZIn = labeledInput(setupTab, 2, 6, "min Z", 6, 6, cfg0.minZ or 0)
local maxZIn = labeledInput(setupTab, 2, 7, "max Z", 6, 6, cfg0.maxZ or 0)

-- Left column, continued: job settings.
setupTab:addLabel({ x = 2, y = 9, text = "Job settings", foreground = colors.yellow })
local workerCountIn = labeledInput(setupTab, 2, 10, "workers", 8, 4, cfg0.workerCount or #registeredWorkerIds())
local fuelReserveIn = labeledInput(setupTab, 2, 11, "fuel", 8, 6, cfg0.fuelReserve or 200)
local invThreshIn = labeledInput(setupTab, 2, 12, "inv %", 8, 6, cfg0.inventoryReturnThreshold or 0.9)

local cleanupCheckbox = setupTab:addCheckbox({ x = 2, y = 13, text = "cleanup pass", checked = cfg0.cleanupPass or false })

-- Right column: unload point + choice buttons for liquid policy / direction.
local rightX = 24
setupTab:addLabel({ x = rightX, y = 1, text = "Unload point", foreground = colors.yellow })
local unloadXIn = labeledInput(setupTab, rightX, 2, "X", 2, 6, up0.x or 0)
local unloadYIn = labeledInput(setupTab, rightX, 3, "Y", 2, 6, up0.y or 0)
local unloadZIn = labeledInput(setupTab, rightX, 4, "Z", 2, 6, up0.z or 0)

-- Tab cycles focus to the next field (Basalt2 has no built-in Tab
-- navigation -- see docs/TROUBLESHOOTING.md). Shift+Tab/reverse is
-- not implemented: Basalt's key event doesn't report modifier state
-- directly, only (self, keyCode, held).
local tabOrder = {
    minXIn, maxXIn, minYIn, maxYIn, minZIn, maxZIn,
    workerCountIn, fuelReserveIn, invThreshIn,
    unloadXIn, unloadYIn, unloadZIn,
}
for i, input in ipairs(tabOrder) do
    local nextInput = tabOrder[i + 1] or tabOrder[1]
    input:onKey(function(_, keyCode)
        if keyCode == keys.tab then nextInput:focus() end
    end)
end

local function choiceGroup(parent, x, y, label, choices, current)
    parent:addLabel({ x = x, y = y, text = label, foreground = colors.yellow })
    local selected = current or choices[1]
    local buttons = {}
    for i, choice in ipairs(choices) do
        local btn = parent:addButton({
            x = x, y = y + i, width = 14, height = 1,
            text = choice,
            background = (choice == selected) and colors.lime or colors.gray,
            foreground = colors.white,
        })
        btn:onClick(function()
            selected = choice
            for _, b in ipairs(buttons) do b.background = colors.gray end
            btn.background = colors.lime
        end)
        buttons[i] = btn
    end
    return {
        get = function() return selected end,
        set = function(choice)
            selected = choice
            for i, b in ipairs(buttons) do
                b.background = (choices[i] == choice) and colors.lime or colors.gray
            end
        end,
        buttons = buttons,
    }
end

local directionGroup = choiceGroup(setupTab, rightX, 6, "Unload direction", { "forward", "up", "down" }, up0.direction)
local liquidGroup = choiceGroup(setupTab, rightX, 11, "Liquid policy",
    { "STOP_AT_LIQUID", "BLOCK_LIQUID", "ALLOW_LIQUID" }, cfg0.liquidPolicy)

-- Output area + action buttons, below all the form content above
-- (which runs through row 14: the liquid-policy choice group's last
-- button). Anchored from the top, not from screenH, so it can never
-- overlap the form regardless of actual screen size; it just gets
-- more/less breathing room on taller/shorter screens.
local buttonsY = 16
local outputY = 17
local outputHeight = math.max(3, screenH - outputY - 1)
local output = setupTab:addTextBox({
    x = 2, y = outputY, width = screenW - 4, height = outputHeight,
    background = colors.black, foreground = colors.white,
    text = "",
})

local function logOutput(widget, text)
    widget.text = (widget.text ~= "" and (widget.text .. "\n") or "") .. text
end

local function readConfigFromForm()
    local cfg = {
        minX = tonumber(minXIn.text), maxX = tonumber(maxXIn.text),
        minY = tonumber(minYIn.text), maxY = tonumber(maxYIn.text),
        minZ = tonumber(minZIn.text), maxZ = tonumber(maxZIn.text),
        workerCount = tonumber(workerCountIn.text),
        fuelReserve = tonumber(fuelReserveIn.text),
        inventoryReturnThreshold = tonumber(invThreshIn.text),
        liquidPolicy = liquidGroup.get(),
        ignoredBlocks = { ["minecraft:bedrock"] = true },
        unloadPoint = {
            x = tonumber(unloadXIn.text) or 0,
            y = tonumber(unloadYIn.text) or 0,
            z = tonumber(unloadZIn.text) or 0,
            direction = directionGroup.get(),
        },
        cleanupPass = cleanupCheckbox.checked,
        protocolVersion = protocol.VERSION,
    }
    return cfg
end

local saveBtn = setupTab:addButton({ x = 2, y = buttonsY, width = 10, text = "Save" })
local validateBtn = setupTab:addButton({ x = 13, y = buttonsY, width = 10, text = "Validate" })
local partitionBtn = setupTab:addButton({ x = 24, y = buttonsY, width = 10, text = "Partition" })
local dryrunBtn = setupTab:addButton({ x = 35, y = buttonsY, width = 10, text = "Dry Run" })

saveBtn:onClick(function()
    local cfg = readConfigFromForm()
    for _, v in pairs({ cfg.minX, cfg.maxX, cfg.minY, cfg.maxY, cfg.minZ, cfg.maxZ, cfg.workerCount, cfg.fuelReserve, cfg.inventoryReturnThreshold }) do
        if v == nil then
            output.text = ""
            logOutput(output, "Error: all numeric fields must be filled in with valid numbers.")
            return
        end
    end
    state.config = cfg
    state.jobId = nil
    state.partitions = nil
    state.slotWorker = {}
    state.deployed = false
    state.started = false
    saveState()
    output.text = ""
    logOutput(output, "Configuration saved. Click Validate, then Partition.")
end)

validateBtn:onClick(function()
    output.text = ""
    if not state.config then logOutput(output, "No configuration saved yet."); return end
    local ok, errs = validation.validateConfig(state.config, { availableWorkers = #registeredWorkerIds() })
    if ok then
        logOutput(output, "Configuration is valid.")
    else
        logOutput(output, #errs .. " problem(s):")
        for _, e in ipairs(errs) do logOutput(output, "  - " .. e) end
    end
end)

partitionBtn:onClick(function()
    output.text = ""
    if not state.config then logOutput(output, "No configuration saved yet."); return end
    local parts, info = partitionLib.compute(bounds(state.config), state.config.workerCount)
    state.partitions = parts
    saveState()
    logOutput(output, string.format("Volume %d blocks. Using %d of %d requested workers (%d idle).",
        info.volume, info.usedWorkers, info.requestedWorkers, info.idleWorkers))
    for i, p in ipairs(parts) do
        logOutput(output, string.format("  slot %d: X[%d,%d] Y[%d,%d] Z[%d,%d] (%d blocks)",
            i, p.partition_min_x, p.partition_max_x, p.partition_min_y, p.partition_max_y,
            p.partition_min_z, p.partition_max_z, p.volume))
    end
end)

dryrunBtn:onClick(function()
    output.text = ""
    if not state.config then logOutput(output, "No configuration saved yet."); return end
    local parts = partitionLib.compute(bounds(state.config), state.config.workerCount)
    local up = state.config.unloadPoint
    logOutput(output, "DRY RUN -- no blocks broken, no turtles moved.")
    for i, p in ipairs(parts) do
        local start = traversal.startCell(p)
        local outDist = math.abs(start.x - up.x) + math.abs(start.y - up.y) + math.abs(start.z - up.z)
        local estMovement = p.volume + 2 * outDist
        logOutput(output, string.format("  slot %d: start=(%d,%d,%d) est. movement=%d",
            i, start.x, start.y, start.z, estMovement))
    end
end)

----------------------------------------------------------------------
-- Deploy tab
----------------------------------------------------------------------

-- Two separate one-line labels, not one wrapped string: a wrapped
-- label's 2nd row has an unpredictable y position that's easy to
-- collide with whatever's placed next (this previously overlapped
-- the Deploy/Start buttons on screens narrow enough to force a wrap).
local deploySummaryLine1 = deployTab:addLabel({ x = 2, y = 2, width = screenW - 4, height = 1, text = "" })
local deploySummaryLine2 = deployTab:addLabel({ x = 2, y = 3, width = screenW - 4, height = 1, text = "" })
local deployBtn = deployTab:addButton({ x = 2, y = 5, width = 10, text = "Deploy" })
local startBtn = deployTab:addButton({ x = 13, y = 5, width = 10, text = "Start" })
local deployOutput = deployTab:addTextBox({
    x = 2, y = 7, width = screenW - 4, height = math.max(3, screenH - 8),
    background = colors.black, foreground = colors.white, text = "",
})

local function refreshDeploySummary()
    local parts = state.partitions and #state.partitions or 0
    local regs = #registeredWorkerIds()
    deploySummaryLine1.text = string.format("Partitions computed: %d    Registered workers: %d", parts, regs)
    deploySummaryLine2.text = string.format("Deployed: %s    Started: %s", tostring(state.deployed), tostring(state.started))
end
refreshDeploySummary()

local function doDeploy()
    deployOutput.text = ""
    if not state.partitions then logOutput(deployOutput, "Run Partition on the Setup tab first."); return end
    local ids = registeredWorkerIds()
    if #ids < #state.partitions then
        logOutput(deployOutput, string.format("Only %d worker(s) registered, but %d partition(s) computed.", #ids, #state.partitions))
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
            starting_facing = 0,
            configuration = {
                version = protocol.VERSION,
                fuelReserve = cfgCopy.fuelReserve,
                inventoryReturnThreshold = cfgCopy.inventoryReturnThreshold,
                liquidPolicy = cfgCopy.liquidPolicy,
                ignoredBlocks = cfgCopy.ignoredBlocks,
                unloadPoint = cfgCopy.unloadPoint,
            },
        }
        state.slotWorker[i] = workerId
        state.workers[workerId] = state.workers[workerId] or {}
        state.workers[workerId].status = "DEPLOYING"
        state.workers[workerId].slot = i
        local ok = comm:sendReliable(workerId, protocol.TYPES.JOB_ASSIGN, job, { maxRetries = 5, ackTimeout = 2 })
        state.workers[workerId].status = ok and "ASSIGNED" or "ASSIGN_FAILED"
        logOutput(deployOutput, "worker " .. workerId .. ": " .. (ok and "assigned" or "did not acknowledge"))
    end
    state.deployed = true
    saveState()
    refreshDeploySummary()
end

local function doStart()
    deployOutput.text = ""
    if not state.deployed then logOutput(deployOutput, "Deploy first."); return end
    for slot, workerId in pairs(state.slotWorker) do
        if state.workers[workerId] and state.workers[workerId].status == "ASSIGNED" then
            local ok = comm:sendReliable(workerId, protocol.TYPES.START, {}, { maxRetries = 5, ackTimeout = 2 })
            state.workers[workerId].status = ok and "MINING" or "START_FAILED"
            logOutput(deployOutput, "worker " .. workerId .. " (slot " .. slot .. "): " .. (ok and "started" or "failed to confirm"))
        end
    end
    state.started = true
    saveState()
    refreshDeploySummary()
end

deployBtn:onClick(function()
    confirmAction("Deploy computed partitions to registered workers?", doDeploy)
end)
startBtn:onClick(function()
    confirmAction("Command all assigned workers to START MINING?", doStart)
end)

----------------------------------------------------------------------
-- Status tab: live worker table + job controls
----------------------------------------------------------------------

local jobLabel = statusTab:addLabel({ x = 2, y = 1, width = screenW - 4, text = "No active job." })

-- detailLabel is a multi-row TextBox, not a 1-2 row Label: a one-line
-- Label previously truncated long lastError values (e.g. a full Lua
-- error message/stack line), which is exactly the information you
-- need most when a worker is in ERROR -- see docs/TROUBLESHOOTING.md.
local statusButtonsY = screenH - 2
local detailHeight = 5
local detailY = statusButtonsY - detailHeight - 1
local workerTable = statusTab:addTable({
    x = 2, y = 2, width = screenW - 4, height = math.max(3, detailY - 3),
    columns = {
        { title = "ID", width = 5 },
        { title = "Status", width = 14 },
        { title = "Progress", width = 9 },
        { title = "Fuel", width = 8 },
        { title = "Inv" },
    },
})

local detailLabel = statusTab:addTextBox({
    x = 2, y = detailY, width = screenW - 4, height = detailHeight,
    background = colors.black, foreground = colors.white,
    text = "Click a worker row for details.",
})

local function refreshStatus()
    jobLabel.text = state.jobId and ("Active job: " .. state.jobId) or "No active job."
    local rows = {}
    local ids = registeredWorkerIds()
    for _, id in ipairs(ids) do
        local w = state.workers[id]
        local last = w.last or {}
        local pct = last.progress and string.format("%d%%", math.floor(last.progress * 100 + 0.5)) or "?"
        rows[#rows + 1] = { id, w.status or "UNKNOWN", pct, tostring(last.fuel or "?"), tostring(last.inventoryUtilization or "?") }
    end
    workerTable:setData(rows)
end
refreshStatus()

workerTable:onSelect(function(self, dataIndex, row)
    local id = row and row[1]
    local w = id and state.workers[id]
    if not w then return end
    local last = w.last or {}
    detailLabel.text = string.format(
        "Worker %d (%s)  slot=%s\npos=(%s,%s,%s)  fuel=%s  inv=%s\nlastError=%s",
        id, tostring(w.label), tostring(w.slot),
        tostring(last.x), tostring(last.y), tostring(last.z),
        tostring(last.fuel), tostring(last.inventoryUtilization),
        tostring(last.lastError))
end)

local function broadcastCommand(msgType)
    local ids = registeredWorkerIds()
    for _, id in ipairs(ids) do
        if state.workers[id] and state.workers[id].slot then
            comm:sendReliable(id, msgType, {}, { maxRetries = 3, ackTimeout = 2 })
        end
    end
    saveState()
    refreshStatus()
end

local pauseBtn = statusTab:addButton({ x = 2, y = screenH - 2, width = 8, text = "Pause" })
local resumeBtn = statusTab:addButton({ x = 11, y = screenH - 2, width = 8, text = "Resume" })
local cancelBtn = statusTab:addButton({ x = 20, y = screenH - 2, width = 8, text = "Cancel" })
local estopBtn = statusTab:addButton({ x = 29, y = screenH - 2, width = 8, text = "ESTOP", background = colors.red, foreground = colors.white })

pauseBtn:onClick(function() broadcastCommand(protocol.TYPES.PAUSE) end)
resumeBtn:onClick(function() broadcastCommand(protocol.TYPES.RESUME) end)
cancelBtn:onClick(function()
    confirmAction("PERMANENTLY cancel the active job for all workers?", function()
        broadcastCommand(protocol.TYPES.CANCEL)
        state.deployed = false
        state.started = false
        saveState()
    end)
end)
estopBtn:onClick(function()
    confirmAction("EMERGENCY STOP all workers immediately?", function()
        broadcastCommand(protocol.TYPES.ESTOP)
    end)
end)

tabs:onChange(function()
    refreshDeploySummary()
    refreshStatus()
end)

-- Test-only hook (see tests/test_master_gui.lua), mirroring
-- master.lua's __QUARRY_TEST_MODE hook: exposes internals so a test
-- can drive button handlers and inspect state directly, against a
-- mocked `basalt` (tests/mocks/basalt_mock.lua), without a real
-- terminal/mouse. Always nil in real deployment.
if _G.__QUARRY_TEST_MODE then
    _G.__QUARRY_DEBUG_GUI = {
        state = state,
        handleMessage = handleMessage,
        confirmAction = confirmAction,
        refreshStatus = refreshStatus,
        refreshDeploySummary = refreshDeploySummary,
        readConfigFromForm = readConfigFromForm,
        widgets = {
            minXIn = minXIn, maxXIn = maxXIn, minYIn = minYIn, maxYIn = maxYIn, minZIn = minZIn, maxZIn = maxZIn,
            workerCountIn = workerCountIn, fuelReserveIn = fuelReserveIn, invThreshIn = invThreshIn,
            cleanupCheckbox = cleanupCheckbox,
            unloadXIn = unloadXIn, unloadYIn = unloadYIn, unloadZIn = unloadZIn,
            directionGroup = directionGroup, liquidGroup = liquidGroup,
            saveBtn = saveBtn, validateBtn = validateBtn, partitionBtn = partitionBtn, dryrunBtn = dryrunBtn,
            output = output,
            deployBtn = deployBtn, startBtn = startBtn, deployOutput = deployOutput,
            deploySummaryLine1 = deploySummaryLine1, deploySummaryLine2 = deploySummaryLine2,
            workerTable = workerTable, jobLabel = jobLabel, detailLabel = detailLabel,
            pauseBtn = pauseBtn, resumeBtn = resumeBtn, cancelBtn = cancelBtn, estopBtn = estopBtn,
            modal = modal, modalYes = modalYes, modalNo = modalNo,
        },
    }
    return
end

----------------------------------------------------------------------
-- Run: Basalt's event loop and the rednet message loop run as
-- separate coroutines under parallel.waitForAny, exactly like
-- master.lua already does with its read()-driven commandLoop -- see
-- that file's header comment for why this is safe (every pulled OS
-- event, including rednet_message and timer events, is fanned out to
-- both coroutines; each decides for itself whether it cares).
----------------------------------------------------------------------

local function statusRefreshLoop()
    while true do
        sleep(STATUS_REFRESH_SECONDS)
        refreshStatus()
        refreshDeploySummary()
    end
end

local ok, err = pcall(parallel.waitForAny, function() basalt.run() end, messageLoop, statusRefreshLoop)
if not ok then
    log:error("gui master crashed", { error = tostring(err) })
    print("Fatal error: " .. tostring(err))
end
