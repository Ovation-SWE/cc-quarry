-- Tests for lib/validation.lua
-- Run with: lua tests/test_validation.lua   (from the quarry/ directory)

package.path = "./lib/?.lua;" .. package.path
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

local function baseConfig()
    return {
        minX = -10, maxX = 10, minY = 0, maxY = 63, minZ = -10, maxZ = 10,
        workerCount = 4,
        fuelReserve = 500,
        inventoryReturnThreshold = 0.9,
        liquidPolicy = "STOP_AT_LIQUID",
        ignoredBlocks = { ["minecraft:bedrock"] = true },
        unloadPoint = { x = 0, y = 0, z = 0, direction = "forward" },
        protocolVersion = 1,
    }
end

-- 1. A well-formed config passes with no errors
do
    local ok, errs = validation.validateConfig(baseConfig(), { availableWorkers = 4 })
    check(ok == true, "well-formed config passes")
    check(#errs == 0, "no errors reported for a valid config")
end

-- 2. min > max on any axis is rejected
do
    local c = baseConfig(); c.minX = 20
    local ok, errs = validation.validateConfig(c, {})
    check(ok == false, "minX > maxX rejected")
    check(#errs >= 1, "at least one error reported")
end

-- 3. Non-integer coordinates rejected
do
    local c = baseConfig(); c.minY = 1.5
    local ok = validation.validateConfig(c, {})
    check(ok == false, "non-integer coordinate rejected")
end

-- 4. workerCount must be positive
do
    local c = baseConfig(); c.workerCount = 0
    local ok = validation.validateConfig(c, {})
    check(ok == false, "workerCount of 0 rejected")
end

-- 5. workerCount exceeding available registered workers is rejected
do
    local c = baseConfig(); c.workerCount = 10
    local ok, errs = validation.validateConfig(c, { availableWorkers = 4 })
    check(ok == false, "workerCount exceeding available workers rejected")
    local found = false
    for _, e in ipairs(errs) do if e:find("exceeds available") then found = true end end
    check(found, "error message explains the worker-count mismatch")
end

-- 6. Multiple problems are all reported at once (never stops at first error)
do
    local c = baseConfig()
    c.minX = 20 -- bad range
    c.workerCount = -1 -- bad worker count
    c.liquidPolicy = "YOLO" -- bad policy
    local ok, errs = validation.validateConfig(c, {})
    check(ok == false, "config with multiple problems rejected")
    check(#errs >= 3, "all three independent problems reported together (" .. #errs .. ")")
end

-- 7. Missing unloadPoint is rejected (storage location must be configured)
do
    local c = baseConfig(); c.unloadPoint = nil
    local ok, errs = validation.validateConfig(c, {})
    check(ok == false, "missing unloadPoint rejected")
end

-- 8. Incompatible protocolVersion is rejected
do
    local c = baseConfig(); c.protocolVersion = 99
    local ok = validation.validateConfig(c, {})
    check(ok == false, "incompatible protocolVersion rejected")
end

-- 8a. depotPoint is optional: absent is valid (today's default behavior)
do
    local c = baseConfig() -- no depotPoint field at all
    local ok, errs = validation.validateConfig(c, { availableWorkers = 4 })
    check(ok == true, "config with no depotPoint is valid: " .. table.concat(errs or {}, "; "))
end

-- 8b. A well-formed depotPoint is accepted
do
    local c = baseConfig()
    c.depotPoint = { x = 5, y = 64, z = 5, facing = 1 }
    local ok, errs = validation.validateConfig(c, { availableWorkers = 4 })
    check(ok == true, "well-formed depotPoint is valid: " .. table.concat(errs or {}, "; "))
end

-- 8c. depotPoint with a non-integer coordinate is rejected
do
    local c = baseConfig()
    c.depotPoint = { x = 5.5, y = 64, z = 5, facing = 0 }
    local ok = validation.validateConfig(c, {})
    check(ok == false, "depotPoint with a non-integer coordinate is rejected")
end

-- 8d. depotPoint.facing outside 0..3 is rejected
do
    local c = baseConfig()
    c.depotPoint = { x = 5, y = 64, z = 5, facing = 4 }
    local ok = validation.validateConfig(c, {})
    check(ok == false, "depotPoint.facing outside 0..3 is rejected")
end

-- 9. Degenerate but valid single-block dimensions are accepted (1x1x1 quarry)
do
    local c = baseConfig()
    c.minX, c.maxX, c.minY, c.maxY, c.minZ, c.maxZ = 5, 5, 5, 5, 5, 5
    local ok, errs = validation.validateConfig(c, { availableWorkers = 4 })
    check(ok == true, "1x1x1 bounds are valid, not rejected as degenerate: " .. table.concat(errs, "; "))
end

-- ===== validateJob =====

local function baseJob()
    return {
        protocol = "quarry.v1",
        job_id = "job-abc123",
        worker_id = 7,
        quarry_min_x = -10, quarry_max_x = 10, quarry_min_y = 0, quarry_max_y = 63, quarry_min_z = -10, quarry_max_z = 10,
        partition_min_x = -10, partition_max_x = 0, partition_min_y = 0, partition_max_y = 63, partition_min_z = -10, partition_max_z = 10,
        starting_position = { x = -10, y = 63, z = -10 },
        starting_facing = 0,
        configuration = { version = 1 },
    }
end

-- 10. Well-formed job accepted for the matching worker
do
    local ok, errs = validation.validateJob(baseJob(), 7)
    check(ok == true, "well-formed job accepted: " .. table.concat(errs or {}, "; "))
end

-- 11. Job addressed to a different worker is rejected (never silently accepted)
do
    local ok = validation.validateJob(baseJob(), 8)
    check(ok == false, "job for a different worker_id is rejected")
end

-- 12. Partition extending outside the quarry bounds is rejected
do
    local j = baseJob()
    j.partition_max_x = 999
    local ok = validation.validateJob(j, 7)
    check(ok == false, "partition exceeding quarry bounds is rejected")
end

-- 13. Wrong protocol name is rejected
do
    local j = baseJob()
    j.protocol = "some.other.v1"
    local ok = validation.validateJob(j, 7)
    check(ok == false, "mismatched protocol name is rejected")
end

print(string.format("\n%d checks, %d failures", checks, failures))
if failures > 0 then os.exit(1) end
