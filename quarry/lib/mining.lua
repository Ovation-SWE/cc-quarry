--- Block-interaction layer: safely clearing a single cell in front
--- of / above / below the turtle, with correct handling of falling
--- blocks, liquids, protected blocks, and partition boundaries.
--
-- Falling-block handling design note: this module does NOT maintain
-- a hardcoded list of "falling block" names (gravel, sand, concrete
-- powder, modded equivalents, ...). Instead, clear() re-inspects the
-- target cell after every dig attempt, in a bounded loop, and keeps
-- digging until the cell is genuinely empty. This is agnostic to
-- *why* a new block appeared in the target cell -- whether it fell
-- from above, or (in principle) any other cause -- and it correctly
-- drains cascades of arbitrary depth without needing to enumerate
-- every falling block ID that could ever exist (including modded
-- ones). The loop is bounded (maxClearAttempts) so a genuinely
-- unbreakable obstruction can never cause an infinite retry.
--
-- Boundary safety: every dig is preceded by a check that the target
-- world coordinate lies within the worker's assigned partition
-- (lib/partition.lua's `contains`). A block outside the partition is
-- never touched, even if physically encountered (e.g. a neighbor's
-- gravel cascading into shared airspace) -- see docs/ARCHITECTURE.md.

local directions = require("directions")
local partitionLib = require("partition")
local errors = require("errors")

local mining = {}
mining.__index = mining

local SUFFIX = { forward = "", up = "Up", down = "Down" }

local DEFAULT_LIQUIDS = { ["minecraft:water"] = true, ["minecraft:lava"] = true }

--- deps = {
--   turtle = <turtle API>,
--   nav = <navigation instance, see lib/navigation.lua>,
--   sleep = function(seconds),
--   log = <logger, optional; expects :warn/:info/:error(msg, fields)>,
--   partition = <partition bounds table>,
--   ignoredBlocks = { [blockName] = true, ... },
--   liquidNames = { [blockName] = true, ... },     -- default water+lava
--   liquidPolicy = "STOP_AT_LIQUID"|"BLOCK_LIQUID"|"ALLOW_LIQUID",
--   sealBlockSlot = <inventory slot to draw sealing blocks from>,
--   maxClearAttempts = 8,
-- }
function mining.new(deps)
    assert(deps and deps.turtle and deps.nav, "mining.new requires deps.turtle and deps.nav")
    local self = setmetatable({}, mining)
    self.turtle = deps.turtle
    self.nav = deps.nav
    self.sleep = deps.sleep or sleep
    self.log = deps.log
    self.partition = deps.partition
    self.ignoredBlocks = deps.ignoredBlocks or {}
    self.liquidNames = deps.liquidNames or DEFAULT_LIQUIDS
    self.liquidPolicy = deps.liquidPolicy or "STOP_AT_LIQUID"
    self.sealBlockSlot = deps.sealBlockSlot
    self.maxClearAttempts = deps.maxClearAttempts or 8
    return self
end

function mining:isProtected(name)
    return self.ignoredBlocks[name] == true
end

function mining:isLiquid(name)
    return self.liquidNames[name] == true
end

--- World coordinate of the cell targeted by dig/inspect kind
--- ("forward" | "up" | "down"), given the navigator's current state.
function mining:worldCoord(kind)
    local x, y, z, facing = self.nav:getPosition()
    if kind == "up" then
        return x, y + 1, z
    elseif kind == "down" then
        return x, y - 1, z
    else
        local dx, dz = directions.vector(facing)
        return x + dx, y, z + dz
    end
end

local function log(self, level, msg, fields)
    if self.log then self.log[level](self.log, msg, fields) end
end

function mining:sealLiquid(kind)
    if not self.sealBlockSlot then
        return false, errors.make(errors.CONFIGURATION_ERROR, "no_seal_block_configured")
    end
    local placeFn = self.turtle["place" .. SUFFIX[kind]]
    local prevSlot = self.turtle.getSelectedSlot()
    self.turtle.select(self.sealBlockSlot)
    local count = self.turtle.getItemCount(self.sealBlockSlot)
    if count <= 0 then
        self.turtle.select(prevSlot)
        return false, errors.make(errors.RESOURCE_EXHAUSTED, "no_seal_blocks_left")
    end
    local ok, err = placeFn()
    self.turtle.select(prevSlot)
    if not ok then
        return false, errors.make(errors.BLOCKED, "seal_failed:" .. tostring(err))
    end
    return true
end

function mining:handleLiquid(kind, info)
    -- Lava is never left to flow freely regardless of configured
    -- policy: ALLOW_LIQUID only ever applies to water. This protects
    -- the turtle (and any workers below/behind it) from destruction.
    local isLava = info.name:find("lava", 1, true) ~= nil

    if isLava then
        if self.liquidPolicy == "BLOCK_LIQUID" then
            return self:sealLiquid(kind)
        end
        log(self, "warn", "lava encountered, stopping at boundary", { block = info.name })
        return false, errors.make(errors.BLOCKED, "lava:" .. self.liquidPolicy)
    end

    if self.liquidPolicy == "ALLOW_LIQUID" then
        return true
    elseif self.liquidPolicy == "BLOCK_LIQUID" then
        return self:sealLiquid(kind)
    else
        log(self, "info", "liquid encountered, stopping (STOP_AT_LIQUID)", { block = info.name })
        return false, errors.make(errors.BLOCKED, "liquid:" .. info.name)
    end
end

--- Clear the cell targeted by `kind` ("forward" | "up" | "down"),
--- repeatedly re-inspecting/digging until it is genuinely empty (to
--- absorb falling-block cascades), or returning a classified failure
--- after a bounded number of attempts. Never digs outside the
--- worker's partition and never touches a protected block.
function mining:clear(kind)
    local inspectFn = self.turtle["inspect" .. SUFFIX[kind]]
    local digFn = self.turtle["dig" .. SUFFIX[kind]]
    local detectFn = self.turtle["detect" .. SUFFIX[kind]]

    for attempt = 1, self.maxClearAttempts do
        local hasBlock, info = inspectFn()
        if not hasBlock then
            return true
        end

        local x, y, z = self:worldCoord(kind)
        if self.partition and not partitionLib.contains(self.partition, x, y, z) then
            log(self, "warn", "refusing to dig outside partition", { x = x, y = y, z = z, block = info.name })
            return false, errors.make(errors.CONFIGURATION_ERROR, "out_of_partition")
        end

        if self:isProtected(info.name) then
            log(self, "info", "skipping protected block", { block = info.name, x = x, y = y, z = z })
            return false, errors.make(errors.BLOCKED, "protected:" .. info.name)
        end

        if self:isLiquid(info.name) then
            local handled, herr = self:handleLiquid(kind, info)
            if not handled then
                return false, herr
            end
            -- Handled means either the liquid was sealed with a solid
            -- block (which must NOT then be dug back out by the next
            -- loop iteration) or it was deliberately left as passable
            -- water (ALLOW_LIQUID). Either way, clear() is done.
            return true
        else
            local ok, digErr = digFn()
            if not ok and attempt == self.maxClearAttempts then
                log(self, "error", "dig failed repeatedly", { block = info.name, err = digErr, attempts = attempt })
                return false, errors.make(errors.BLOCKED, "dig_failed:" .. tostring(digErr))
            end
            if not ok and self.sleep then
                self.sleep(0.1)
            end
            -- loop: re-inspect, whether dig succeeded (catches cascade) or
            -- failed (confirms whether it's still genuinely there)
        end
    end

    if detectFn() then
        return false, errors.make(errors.BLOCKED, "max_clear_attempts_exceeded")
    end
    return true
end

function mining:clearFront() return self:clear("forward") end
function mining:clearUp() return self:clear("up") end
function mining:clearDown() return self:clear("down") end

return mining
