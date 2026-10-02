-- Exhaustive correctness tests for lib/partition.lua
-- Run with: lua tests/test_partition.lua   (from the quarry/ directory)

package.path = "./lib/?.lua;" .. package.path
local partition = require("partition")

local failures = 0
local checks = 0

local function check(cond, msg)
    checks = checks + 1
    if not cond then
        failures = failures + 1
        print("FAIL: " .. msg)
    end
end

-- Brute-force verifier: enumerates every block in `bounds` and checks
-- that it is covered by exactly one partition, plus checks pairwise
-- non-overlap via bounding-box intersection and positive volume.
local function verify(bounds, workerCount, label)
    local parts, info = partition.compute(bounds, workerCount)

    check(#parts == info.usedWorkers,
        label .. ": partition count (" .. #parts .. ") == usedWorkers (" .. info.usedWorkers .. ")")

    for i, p in ipairs(parts) do
        local vol = (p.partition_max_x - p.partition_min_x + 1)
            * (p.partition_max_y - p.partition_min_y + 1)
            * (p.partition_max_z - p.partition_min_z + 1)
        check(vol > 0, label .. ": partition " .. i .. " has positive volume")
        check(p.partition_min_x >= bounds.minX and p.partition_max_x <= bounds.maxX,
            label .. ": partition " .. i .. " X within bounds")
        check(p.partition_min_y >= bounds.minY and p.partition_max_y <= bounds.maxY,
            label .. ": partition " .. i .. " Y within bounds")
        check(p.partition_min_z >= bounds.minZ and p.partition_max_z <= bounds.maxZ,
            label .. ": partition " .. i .. " Z within bounds")
    end

    -- pairwise overlap check
    for i = 1, #parts do
        for j = i + 1, #parts do
            local a, b = parts[i], parts[j]
            local overlapX = a.partition_min_x <= b.partition_max_x and b.partition_min_x <= a.partition_max_x
            local overlapY = a.partition_min_y <= b.partition_max_y and b.partition_min_y <= a.partition_max_y
            local overlapZ = a.partition_min_z <= b.partition_max_z and b.partition_min_z <= a.partition_max_z
            check(not (overlapX and overlapY and overlapZ),
                label .. ": partitions " .. i .. " and " .. j .. " do not overlap")
        end
    end

    -- full coverage: brute-force enumerate blocks (only for small volumes)
    local volume = (bounds.maxX - bounds.minX + 1) * (bounds.maxY - bounds.minY + 1) * (bounds.maxZ - bounds.minZ + 1)
    if volume <= 20000 then
        local coverCount = {}
        for _, p in ipairs(parts) do
            for x = p.partition_min_x, p.partition_max_x do
                for y = p.partition_min_y, p.partition_max_y do
                    for z = p.partition_min_z, p.partition_max_z do
                        local key = x .. "," .. y .. "," .. z
                        coverCount[key] = (coverCount[key] or 0) + 1
                    end
                end
            end
        end
        local total = 0
        local doubleCovered = 0
        for _, c in pairs(coverCount) do
            total = total + 1
            if c ~= 1 then doubleCovered = doubleCovered + 1 end
        end
        check(total == volume, label .. ": every block covered (" .. total .. "/" .. volume .. ")")
        check(doubleCovered == 0, label .. ": no block covered more than once")
    end

    return parts, info
end

local function bounds(minX, maxX, minY, maxY, minZ, maxZ)
    return { minX = minX, maxX = maxX, minY = minY, maxY = maxY, minZ = minZ, maxZ = maxZ }
end

-- 1. 1x1x1 quarry
verify(bounds(0, 0, 0, 0, 0, 0), 1, "1x1x1 / 1 worker")
do
    local _, info = verify(bounds(0, 0, 0, 0, 0, 0), 4, "1x1x1 / 4 workers (oversubscribed)")
    check(info.usedWorkers == 1, "1x1x1/4 workers: only 1 worker used")
    check(info.idleWorkers == 3, "1x1x1/4 workers: 3 idle workers reported")
end

-- 2. 1x1x100 quarry (tall/long shaft), various worker counts
verify(bounds(0, 0, 0, 0, 0, 99), 1, "1x1x100 / 1 worker")
verify(bounds(0, 0, 0, 0, 0, 99), 3, "1x1x100 / 3 workers")
verify(bounds(0, 0, 0, 0, 0, 99), 7, "1x1x100 / 7 workers")
verify(bounds(0, 0, 0, 0, 0, 99), 100, "1x1x100 / 100 workers (exact)")
do
    local _, info = verify(bounds(0, 0, 0, 0, 0, 99), 150, "1x1x100 / 150 workers (oversubscribed)")
    check(info.usedWorkers == 100, "1x1x100/150 workers: only 100 used")
    check(info.idleWorkers == 50, "1x1x100/150 workers: 50 idle")
end

-- 3. 100x1x1 quarry
verify(bounds(0, 99, 0, 0, 0, 0), 1, "100x1x1 / 1 worker")
verify(bounds(0, 99, 0, 0, 0, 0), 7, "100x1x1 / 7 workers")
verify(bounds(0, 99, 0, 0, 0, 0), 13, "100x1x1 / 13 workers")

-- 4. odd dimensions
verify(bounds(0, 6, 0, 4, 0, 8), 5, "odd dims 7x5x9 / 5 workers")
verify(bounds(0, 6, 0, 4, 0, 8), 3, "odd dims 7x5x9 / 3 workers")

-- 5. worker count > X dimension
verify(bounds(0, 3, 0, 10, 0, 20), 10, "worker count(10) > dx(4)")

-- 6. worker count > Z dimension
verify(bounds(0, 20, 0, 10, 0, 2), 10, "worker count(10) > dz(3)")

-- 7. multiple Y layers, ordinary case
verify(bounds(0, 15, 0, 63, 0, 15), 4, "16x64x16 / 4 workers")
verify(bounds(0, 15, 0, 63, 0, 15), 8, "16x64x16 / 8 workers")

-- 8. negative coordinates
verify(bounds(-10, -1, 0, 5, -20, -11), 3, "negative coords / 3 workers")

-- 9. coordinates crossing zero
verify(bounds(-5, 5, 0, 5, -5, 5), 6, "crossing zero / 6 workers")
verify(bounds(-5, 5, -5, 5, -5, 5), 27, "crossing zero cube / 27 workers")

-- extreme: worker count equal to volume (every worker gets exactly 1 block)
verify(bounds(0, 2, 0, 2, 0, 2), 27, "3x3x3 / 27 workers (1 block each)")

-- extreme: worker count vastly exceeds volume
do
    local _, info = verify(bounds(0, 1, 0, 1, 0, 1), 1000, "2x2x2 / 1000 workers")
    check(info.usedWorkers == 8, "2x2x2/1000: usedWorkers == 8")
    check(info.idleWorkers == 992, "2x2x2/1000: idleWorkers == 992")
end

-- Sweep: many random-ish (deterministic) combinations for extra confidence
math.randomseed(1)
for i = 1, 200 do
    local dx = math.random(1, 12)
    local dy = math.random(1, 12)
    local dz = math.random(1, 12)
    local n = math.random(1, 40)
    local ox = math.random(-15, 15)
    local oy = math.random(-15, 15)
    local oz = math.random(-15, 15)
    local b = bounds(ox, ox + dx - 1, oy, oy + dy - 1, oz, oz + dz - 1)
    verify(b, n, string.format("sweep#%d dims=%dx%dx%d n=%d", i, dx, dy, dz, n))
end

-- Determinism: same input always yields identical output
do
    local b = bounds(-3, 12, 0, 20, -7, 9)
    local p1 = partition.compute(b, 6)
    local p2 = partition.compute(b, 6)
    check(#p1 == #p2, "determinism: same partition count across runs")
    for i = 1, #p1 do
        check(p1[i].partition_min_x == p2[i].partition_min_x
            and p1[i].partition_max_x == p2[i].partition_max_x
            and p1[i].partition_min_y == p2[i].partition_min_y
            and p1[i].partition_max_y == p2[i].partition_max_y
            and p1[i].partition_min_z == p2[i].partition_min_z
            and p1[i].partition_max_z == p2[i].partition_max_z,
            "determinism: partition " .. i .. " identical across runs")
    end
end

-- partition.contains boundary checks
do
    local p = { partition_min_x = 0, partition_max_x = 5, partition_min_y = 0, partition_max_y = 5, partition_min_z = 0, partition_max_z = 5 }
    check(partition.contains(p, 0, 0, 0) == true, "contains: min corner inside")
    check(partition.contains(p, 5, 5, 5) == true, "contains: max corner inside")
    check(partition.contains(p, -1, 0, 0) == false, "contains: just outside -X")
    check(partition.contains(p, 6, 0, 0) == false, "contains: just outside +X")
end

print(string.format("\n%d checks, %d failures", checks, failures))
if failures > 0 then os.exit(1) end
