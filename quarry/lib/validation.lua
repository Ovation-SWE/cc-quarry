--- Pre-flight validation of a quarry configuration. Returns a full
--- list of problems rather than stopping at the first one, so the
--- master can display everything wrong at once (never partially
--- starts a job after validation failure -- see master.lua).

local protocol = require("protocol")

local validation = {}

local AXES = { "X", "Y", "Z" }

local function isInteger(v)
    return type(v) == "number" and v == math.floor(v)
end

--- context = { availableWorkers = <number of registered/deployed workers> }
function validation.validateConfig(config, context)
    context = context or {}
    local errs = {}
    local function fail(msg) errs[#errs + 1] = msg end

    if type(config) ~= "table" then
        return false, { "configuration is missing or not a table" }
    end

    for _, axis in ipairs(AXES) do
        local lo, hi = config["min" .. axis], config["max" .. axis]
        if not isInteger(lo) then
            fail("min" .. axis .. " must be an integer (got " .. tostring(lo) .. ")")
        end
        if not isInteger(hi) then
            fail("max" .. axis .. " must be an integer (got " .. tostring(hi) .. ")")
        end
        if isInteger(lo) and isInteger(hi) and lo > hi then
            fail("min" .. axis .. " (" .. lo .. ") must be <= max" .. axis .. " (" .. hi .. ")")
        end
    end

    if not isInteger(config.workerCount) or config.workerCount < 1 then
        fail("workerCount must be a positive integer")
    elseif context.availableWorkers ~= nil and config.workerCount > context.availableWorkers then
        fail(string.format(
            "workerCount (%d) exceeds available registered workers (%d)",
            config.workerCount, context.availableWorkers))
    end

    if config.fuelReserve ~= nil and (not isInteger(config.fuelReserve) or config.fuelReserve < 0) then
        fail("fuelReserve must be a non-negative integer")
    end

    if config.inventoryReturnThreshold ~= nil then
        local t = config.inventoryReturnThreshold
        if type(t) ~= "number" or t <= 0 or t > 1 then
            fail("inventoryReturnThreshold must be a number in (0, 1]")
        end
    end

    local validLiquidPolicies = { STOP_AT_LIQUID = true, BLOCK_LIQUID = true, ALLOW_LIQUID = true }
    if config.liquidPolicy ~= nil and not validLiquidPolicies[config.liquidPolicy] then
        fail("liquidPolicy must be one of STOP_AT_LIQUID, BLOCK_LIQUID, ALLOW_LIQUID")
    end

    if config.ignoredBlocks ~= nil then
        if type(config.ignoredBlocks) ~= "table" then
            fail("ignoredBlocks must be a table of block-name -> true")
        else
            for name, flag in pairs(config.ignoredBlocks) do
                if type(name) ~= "string" or flag ~= true then
                    fail("ignoredBlocks entries must be [\"minecraft:block_name\"] = true")
                    break
                end
            end
        end
    end

    if config.unloadPoint == nil then
        fail("unloadPoint (storage location) must be configured before starting")
    else
        local up = config.unloadPoint
        if not (isInteger(up.x) and isInteger(up.y) and isInteger(up.z)) then
            fail("unloadPoint must specify integer x, y, z")
        end
        local validDirs = { forward = true, up = true, down = true }
        if not validDirs[up.direction] then
            fail("unloadPoint.direction must be one of forward, up, down")
        end
    end

    if config.protocolVersion ~= nil and config.protocolVersion ~= protocol.VERSION then
        fail(string.format(
            "configuration protocolVersion (%s) is incompatible with this build (%d)",
            tostring(config.protocolVersion), protocol.VERSION))
    end

    return (#errs == 0), errs
end

--- Validate a single job-assignment payload as received by a worker
--- (or, defensively, re-checked by the master before dispatch).
--- `expectedWorkerId` should be os.getComputerID() on the worker
--- side, so a message misdirected/replayed for a different worker
--- can never be silently accepted.
function validation.validateJob(job, expectedWorkerId)
    local errs = {}
    local function fail(msg) errs[#errs + 1] = msg end

    if type(job) ~= "table" then
        return false, { "job payload is not a table" }
    end
    if job.protocol ~= protocol.NAME then
        fail("job.protocol (" .. tostring(job.protocol) .. ") does not match " .. protocol.NAME)
    end
    if type(job.job_id) ~= "string" or job.job_id == "" then
        fail("job.job_id must be a non-empty string")
    end
    if expectedWorkerId ~= nil and job.worker_id ~= expectedWorkerId then
        fail(string.format("job.worker_id (%s) does not match this computer's ID (%s)",
            tostring(job.worker_id), tostring(expectedWorkerId)))
    end

    for _, prefix in ipairs({ "quarry_", "partition_" }) do
        for _, axis in ipairs(AXES) do
            local lo = job[prefix .. "min_" .. axis:lower()]
            local hi = job[prefix .. "max_" .. axis:lower()]
            if not isInteger(lo) or not isInteger(hi) then
                fail(prefix .. "min_" .. axis:lower() .. "/max_" .. axis:lower() .. " must be integers")
            elseif lo > hi then
                fail(prefix .. "min_" .. axis:lower() .. " must be <= " .. prefix .. "max_" .. axis:lower())
            end
        end
    end

    if type(job.partition_min_x) == "number" and type(job.quarry_min_x) == "number" then
        if job.partition_min_x < job.quarry_min_x or job.partition_max_x > job.quarry_max_x
            or job.partition_min_y < job.quarry_min_y or job.partition_max_y > job.quarry_max_y
            or job.partition_min_z < job.quarry_min_z or job.partition_max_z > job.quarry_max_z then
            fail("partition bounds must lie entirely within the quarry bounds")
        end
    end

    local sp = job.starting_position
    if type(sp) ~= "table" or not (isInteger(sp.x) and isInteger(sp.y) and isInteger(sp.z)) then
        fail("starting_position must be a table with integer x, y, z")
    end
    if job.starting_facing == nil or job.starting_facing < 0 or job.starting_facing > 3 then
        fail("starting_facing must be an integer in 0..3")
    end

    return (#errs == 0), errs
end

return validation
