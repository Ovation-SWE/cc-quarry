--- Deterministic 3D rectangular partitioning for quarry workers.
--
-- Algorithm: recursive guillotine bisection ("k-d tree" style),
-- splitting geometry first and worker counts second.
--
-- We treat the quarry volume as a box of integer block-lengths
-- (lx, ly, lz). To split a region among n workers:
--
--   1. Pick the longest axis (ties broken X > Z > Y) with length > 1.
--      (Whenever n > 1 the region's volume is >= n >= 2, so such an
--      axis is guaranteed to exist.)
--   2. Cut that axis geometrically in half: L1 = floor(L/2), L2 = L - L1.
--      This is a pure geometry decision, independent of n, so it can
--      never demand more length than the axis has.
--   3. Compute the two sub-volumes vol1 = L1*otherArea, vol2 = L2*otherArea
--      (otherArea = the product of the two axes not being cut).
--   4. Allocate the n workers between the two sub-boxes proportionally
--      to their volume, clamped to the feasible range
--      [max(1, n - vol2), min(vol1, n - 1)]. This range is always
--      non-empty when n >= 2 and vol1, vol2 >= 1 (both hold here),
--      because vol1 + vol2 = volume >= n. The clamp guarantees
--      1 <= n1 <= vol1 and 1 <= n2 <= vol2, i.e. neither side is ever
--      asked to seat more workers than it has blocks for, and neither
--      side is ever left with zero workers despite having volume.
--
-- Recurse on both halves; stop at n == 1 (one leaf rectangle per
-- worker). Every split cuts an existing rectangle into two rectangles
-- sharing a flat boundary with no gap and no overlap, and each leaf's
-- volume is always > 0, so by induction the final leaf set exactly
-- tiles the original volume with no gaps, no overlaps, full coverage
-- — including degenerate shapes (1x1x100, 100xNx1), worker counts
-- that exceed a single dimension, and perfectly tight packing where
-- every worker gets exactly one block.
--
-- If workerCount > volume (more workers than blocks), only `volume`
-- workers receive a (1-block) partition; the rest are reported as
-- idle by the caller via the `idleWorkers` field. We never create a
-- zero-volume partition.

local partition = {}

local function clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

-- region: { x0, lx, y0, ly, z0, lz } (x0/y0/z0 = lower corner, l* = lengths)
local function volumeOf(region)
    return region.lx * region.ly * region.lz
end

local AXES = {
    { key = "x", origin = "x0", len = "lx" },
    { key = "z", origin = "z0", len = "lz" },
    { key = "y", origin = "y0", len = "ly" },
}

local function pickAxis(region)
    local best, bestLen = nil, 1
    for _, axis in ipairs(AXES) do
        local len = region[axis.len]
        if len > bestLen then
            best, bestLen = axis, len
        end
    end
    -- If every axis has length 1 the region is a single block; the
    -- caller only ever recurses with n == 1 in that case, so the
    -- axis choice is irrelevant. Default to X for determinism.
    return best or AXES[1]
end

local function splitRegion(region, axis, l1)
    local l2 = region[axis.len] - l1
    local a = {}
    local b = {}
    for k, v in pairs(region) do
        a[k] = v
        b[k] = v
    end
    a[axis.len] = l1
    b[axis.len] = l2
    b[axis.origin] = region[axis.origin] + l1
    return a, b
end

local function bisect(region, n, out)
    if n <= 1 then
        out[#out + 1] = region
        return
    end

    local axis = pickAxis(region)
    local L = region[axis.len]
    local otherArea = volumeOf(region) / L

    -- Step 1: pure geometric cut, independent of n.
    local l1 = math.floor(L / 2)
    local l2 = L - l1
    local vol1 = l1 * otherArea
    local vol2 = l2 * otherArea

    -- Step 2: allocate workers proportionally to the resulting volumes,
    -- clamped into the always-feasible range.
    local target = math.floor(n * vol1 / (vol1 + vol2) + 0.5)
    local n1 = clamp(target, math.max(1, n - vol2), math.min(vol1, n - 1))
    local n2 = n - n1

    local regionA, regionB = splitRegion(region, axis, l1)
    bisect(regionA, n1, out)
    bisect(regionB, n2, out)
end

--- Validate quarry bounds. Returns true, or false + error message.
function partition.validateBounds(bounds)
    for _, axis in ipairs({ "X", "Y", "Z" }) do
        local lo = bounds["min" .. axis]
        local hi = bounds["max" .. axis]
        if type(lo) ~= "number" or type(hi) ~= "number" then
            return false, "min" .. axis .. "/max" .. axis .. " must be numbers"
        end
        if lo ~= math.floor(lo) or hi ~= math.floor(hi) then
            return false, axis .. " bounds must be integers"
        end
        if lo > hi then
            return false, "min" .. axis .. " must be <= max" .. axis
        end
    end
    return true
end

--- Compute a deterministic partitioning of `bounds` among up to
--- `workerCount` workers.
--
-- bounds = { minX, maxX, minY, maxY, minZ, maxZ } (inclusive)
--
-- Returns a list of partitions sorted deterministically:
--   { partition_min_x, partition_max_x,
--     partition_min_y, partition_max_y,
--     partition_min_z, partition_max_z, volume }
-- plus a summary table: { volume, usedWorkers, idleWorkers, requestedWorkers }
function partition.compute(bounds, workerCount)
    assert(workerCount and workerCount >= 1, "workerCount must be >= 1")
    local ok, err = partition.validateBounds(bounds)
    if not ok then error("invalid bounds: " .. err) end

    local lx = bounds.maxX - bounds.minX + 1
    local ly = bounds.maxY - bounds.minY + 1
    local lz = bounds.maxZ - bounds.minZ + 1
    local volume = lx * ly * lz

    local usedWorkers = math.min(workerCount, volume)

    local rootRegion = { x0 = bounds.minX, lx = lx, y0 = bounds.minY, ly = ly, z0 = bounds.minZ, lz = lz }
    local leaves = {}
    bisect(rootRegion, usedWorkers, leaves)

    local results = {}
    for _, r in ipairs(leaves) do
        results[#results + 1] = {
            partition_min_x = r.x0,
            partition_max_x = r.x0 + r.lx - 1,
            partition_min_y = r.y0,
            partition_max_y = r.y0 + r.ly - 1,
            partition_min_z = r.z0,
            partition_max_z = r.z0 + r.lz - 1,
            volume = r.lx * r.ly * r.lz,
        }
    end

    table.sort(results, function(a, b)
        if a.partition_min_y ~= b.partition_min_y then return a.partition_min_y < b.partition_min_y end
        if a.partition_min_z ~= b.partition_min_z then return a.partition_min_z < b.partition_min_z end
        return a.partition_min_x < b.partition_min_x
    end)

    return results, {
        volume = volume,
        usedWorkers = usedWorkers,
        idleWorkers = workerCount - usedWorkers,
        requestedWorkers = workerCount,
    }
end

--- True if the world coordinate (x,y,z) lies within a partition
--- (inclusive bounds). Used as the hard mining-limit check.
function partition.contains(p, x, y, z)
    return x >= p.partition_min_x and x <= p.partition_max_x
        and y >= p.partition_min_y and y <= p.partition_max_y
        and z >= p.partition_min_z and z <= p.partition_max_z
end

return partition
