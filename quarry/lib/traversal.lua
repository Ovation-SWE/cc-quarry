--- Deterministic top-down boustrophedon ("serpentine") traversal of a
--- worker's rectangular partition.
--
-- The key design property: the next cell to visit is a *pure function
-- of the current cell* (plus the static partition bounds). No extra
-- "row index" / "layer index" counters need to be persisted — the
-- turtle's own (x, y, z) position (which is already persisted for
-- other reasons) is sufficient to resume traversal after a reboot.
--
-- Traversal order:
--   * Layers are visited top-down: y = partition_max_y .. partition_min_y.
--   * Within a layer, rows are visited along Z, alternating direction
--     each layer (layer 0: minZ -> maxZ, layer 1: maxZ -> minZ, ...)
--     so the last row of one layer ends adjacent to the first row of
--     the next layer (no wasted travel across Z when descending).
--   * Within a row, X is scanned in a snake pattern, alternating
--     direction each row (boustrophedon), so consecutive rows join
--     at the ends with no backtracking.
--
-- Every transition changes exactly one axis by exactly one block, so
-- the returned path is always physically realizable as a sequence of
-- single forward/up/down movements.

local traversal = {}

--- The cell a worker should start at for a given partition.
function traversal.startCell(p)
    return { x = p.partition_min_x, y = p.partition_max_y, z = p.partition_min_z }
end

local function layerParity(p, y)
    return (p.partition_max_y - y) % 2
end

local function rowIndexInLayer(p, z, lp)
    if lp == 0 then
        return z - p.partition_min_z
    else
        return p.partition_max_z - z
    end
end

--- The row direction must alternate continuously across the *entire*
--- traversal, not reset at each layer boundary: whichever end of a
--- row a layer's last row finishes on is exactly where the next
--- layer's first row begins, and the snake must keep going the same
--- way it was already going. So X direction is derived from a global
--- row counter (layer's row count so far, summed across all
--- preceding layers) rather than the row index within just the
--- current layer -- otherwise, whenever a layer has an even number of
--- rows, the naive per-layer parity would flip incorrectly and break
--- the path (verified by exhaustive test failures before this fix).
local function globalRowIndex(p, y, z)
    local layerIdx = p.partition_max_y - y
    local lp = layerParity(p, y)
    local rowsPerLayer = p.partition_max_z - p.partition_min_z + 1
    local rowIdxInLayer = rowIndexInLayer(p, z, lp)
    return layerIdx * rowsPerLayer + rowIdxInLayer, lp
end

--- Given the current cell (must lie inside partition p), return the
--- next cell to visit, or nil if (x, y, z) was the last cell (the
--- partition has been fully visited).
function traversal.nextCell(p, x, y, z)
    local globalRow, lp = globalRowIndex(p, y, z)
    local xIncreasing = (globalRow % 2 == 0)

    local atRowEnd
    if xIncreasing then
        atRowEnd = (x >= p.partition_max_x)
    else
        atRowEnd = (x <= p.partition_min_x)
    end

    if not atRowEnd then
        if xIncreasing then
            return { x = x + 1, y = y, z = z }
        else
            return { x = x - 1, y = y, z = z }
        end
    end

    local nextZ = (lp == 0) and (z + 1) or (z - 1)
    local rowsExhausted = (lp == 0 and nextZ > p.partition_max_z) or (lp == 1 and nextZ < p.partition_min_z)

    if not rowsExhausted then
        return { x = x, y = y, z = nextZ }
    end

    local nextY = y - 1
    if nextY < p.partition_min_y then
        return nil
    end
    return { x = x, y = nextY, z = z }
end

--- Total number of cells in the partition (used for progress %).
function traversal.volume(p)
    return (p.partition_max_x - p.partition_min_x + 1)
        * (p.partition_max_y - p.partition_min_y + 1)
        * (p.partition_max_z - p.partition_min_z + 1)
end

--- How many cells (inclusive of the current one) have already been
--- visited if the worker is currently at (x, y, z) and has mined it.
--- Used for progress reporting without re-walking the whole path.
function traversal.indexOf(p, x, y, z)
    local globalRow = globalRowIndex(p, y, z)
    local rowLen = p.partition_max_x - p.partition_min_x + 1
    local xIncreasing = (globalRow % 2 == 0)
    local xIdx
    if xIncreasing then
        xIdx = x - p.partition_min_x
    else
        xIdx = p.partition_max_x - x
    end
    return globalRow * rowLen + xIdx + 1
end

return traversal
