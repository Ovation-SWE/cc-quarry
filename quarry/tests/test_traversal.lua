-- Exhaustive correctness tests for lib/traversal.lua
-- Run with: lua tests/test_traversal.lua   (from the quarry/ directory)

package.path = "./lib/?.lua;" .. package.path
local traversal = require("traversal")

local failures = 0
local checks = 0

local function check(cond, msg)
    checks = checks + 1
    if not cond then
        failures = failures + 1
        print("FAIL: " .. msg)
    end
end

local function P(minX, maxX, minY, maxY, minZ, maxZ)
    return {
        partition_min_x = minX, partition_max_x = maxX,
        partition_min_y = minY, partition_max_y = maxY,
        partition_min_z = minZ, partition_max_z = maxZ,
    }
end

local function walk(p)
    local cell = traversal.startCell(p)
    local path = { cell }
    local guard = 0
    local maxGuard = traversal.volume(p) + 10
    while true do
        guard = guard + 1
        if guard > maxGuard then
            error("traversal did not terminate within expected bound")
        end
        local nxt = traversal.nextCell(p, cell.x, cell.y, cell.z)
        if not nxt then break end
        path[#path + 1] = nxt
        cell = nxt
    end
    return path
end

local function verify(p, label)
    local path = walk(p)
    local volume = traversal.volume(p)
    check(#path == volume, label .. ": path length (" .. #path .. ") == volume (" .. volume .. ")")

    local seen = {}
    local duplicates = 0
    local outOfBounds = 0
    local badSteps = 0
    for i, c in ipairs(path) do
        local key = c.x .. "," .. c.y .. "," .. c.z
        if seen[key] then duplicates = duplicates + 1 end
        seen[key] = true
        if c.x < p.partition_min_x or c.x > p.partition_max_x
            or c.y < p.partition_min_y or c.y > p.partition_max_y
            or c.z < p.partition_min_z or c.z > p.partition_max_z then
            outOfBounds = outOfBounds + 1
        end
        if i > 1 then
            local prev = path[i - 1]
            local dx = math.abs(c.x - prev.x)
            local dy = math.abs(c.y - prev.y)
            local dz = math.abs(c.z - prev.z)
            local axesChanged = (dx > 0 and 1 or 0) + (dy > 0 and 1 or 0) + (dz > 0 and 1 or 0)
            if axesChanged ~= 1 or (dx + dy + dz) ~= 1 then
                badSteps = badSteps + 1
            end
        end
    end
    check(duplicates == 0, label .. ": no cell visited twice (" .. duplicates .. " dups)")
    check(outOfBounds == 0, label .. ": no cell outside bounds (" .. outOfBounds .. ")")
    check(badSteps == 0, label .. ": every step moves exactly one axis by one block (" .. badSteps .. " bad)")

    -- indexOf must agree with actual path position (1-based)
    local indexMismatches = 0
    for i, c in ipairs(path) do
        if traversal.indexOf(p, c.x, c.y, c.z) ~= i then
            indexMismatches = indexMismatches + 1
        end
    end
    check(indexMismatches == 0, label .. ": indexOf matches path position (" .. indexMismatches .. " mismatches)")

    return path
end

verify(P(0, 0, 0, 0, 0, 0), "1x1x1")
verify(P(0, 0, 0, 99, 0, 0), "1x100x1 (vertical shaft)")
verify(P(0, 99, 0, 0, 0, 0), "100x1x1 (horizontal line)")
verify(P(0, 0, 0, 0, 0, 99), "1x1x100 (horizontal line, Z)")
verify(P(0, 6, 0, 4, 0, 8), "7x5x9 odd dims")
verify(P(-10, -1, 0, 5, -20, -11), "negative coords")
verify(P(-5, 5, -5, 5, -5, 5), "crossing zero cube 11^3")
verify(P(0, 15, 0, 63, 0, 15), "16x64x16 chunk column")
verify(P(0, 1, 0, 1, 0, 1), "2x2x2")

math.randomseed(7)
for i = 1, 100 do
    local dx = math.random(1, 10)
    local dy = math.random(1, 10)
    local dz = math.random(1, 10)
    local ox = math.random(-20, 20)
    local oy = math.random(-20, 20)
    local oz = math.random(-20, 20)
    verify(P(ox, ox + dx - 1, oy, oy + dy - 1, oz, oz + dz - 1),
        string.format("sweep#%d %dx%dx%d", i, dx, dy, dz))
end

print(string.format("\n%d checks, %d failures", checks, failures))
if failures > 0 then os.exit(1) end
