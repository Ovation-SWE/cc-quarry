--- Inventory management: fullness detection, stack consolidation, and
--- unloading to storage.
--
-- Unloading uses turtle.drop()/dropUp()/dropDown() rather than the
-- peripheral inventory API. This is a deliberate choice: drop() works
-- against *any* adjacent inventory-holding block (chest, barrel,
-- hopper, shulker box, modded storage that accepts item insertion)
-- without needing to know its specific peripheral type, satisfying
-- "must not assume every chest/storage block has the same interface."
-- The tradeoff is that the turtle must be physically positioned next
-- to the storage, facing the configured direction -- which the worker
-- already must do to navigate to its configured unload point anyway.

local errors = require("errors")

local inventory = {}
inventory.__index = inventory

--- deps = {
--   turtle = <turtle API>,
--   reservedSlots = { [slot] = true, ... },  -- never touched by dump/discard
--   discardBlocks = { [blockName] = true, ... }, -- optional junk filter
--   log = <logger, optional>,
-- }
function inventory.new(deps)
    assert(deps and deps.turtle, "inventory.new requires deps.turtle")
    local self = setmetatable({}, inventory)
    self.turtle = deps.turtle
    self.reservedSlots = deps.reservedSlots or {}
    self.discardBlocks = deps.discardBlocks or {}
    self.log = deps.log
    return self
end

function inventory:usableSlots()
    local slots = {}
    for i = 1, 16 do
        if not self.reservedSlots[i] then slots[#slots + 1] = i end
    end
    return slots
end

--- True if every usable (non-reserved) slot holds a full or partial
--- stack, i.e. there is no room left to pick up newly mined blocks.
function inventory:isFull()
    for _, slot in ipairs(self:usableSlots()) do
        if self.turtle.getItemCount(slot) == 0 then
            return false
        end
    end
    return true
end

function inventory:freeSlotCount()
    local free = 0
    for _, slot in ipairs(self:usableSlots()) do
        if self.turtle.getItemCount(slot) == 0 then free = free + 1 end
    end
    return free
end

--- Fraction (0..1) of usable slots currently occupied, for heartbeat
--- "inventory utilization" reporting.
function inventory:utilization()
    local usable = self:usableSlots()
    if #usable == 0 then return 1 end
    local used = 0
    for _, slot in ipairs(usable) do
        if self.turtle.getItemCount(slot) > 0 then used = used + 1 end
    end
    return used / #usable
end

--- Merge partial stacks of the same item into fewer slots, freeing up
--- space without losing any items.
function inventory:consolidate()
    local usable = self:usableSlots()
    for i = 1, #usable do
        local slotA = usable[i]
        local detailA = self.turtle.getItemDetail(slotA)
        if detailA then
            for j = i + 1, #usable do
                local slotB = usable[j]
                local detailB = self.turtle.getItemDetail(slotB)
                if detailB and detailB.name == detailA.name then
                    self.turtle.select(slotB)
                    self.turtle.transferTo(slotA)
                end
            end
        end
    end
end

--- Drop any items matching the configured discard/junk filter,
--- freeing space without needing a storage trip. Drops in front by
--- default; direction can be overridden.
function inventory:discardJunk(direction)
    direction = direction or "forward"
    local dropFn = self.turtle["drop" .. ({ forward = "", up = "Up", down = "Down" })[direction]]
    local dropped = 0
    for _, slot in ipairs(self:usableSlots()) do
        local detail = self.turtle.getItemDetail(slot)
        if detail and self.discardBlocks[detail.name] then
            self.turtle.select(slot)
            local ok = dropFn()
            if ok then dropped = dropped + 1 end
        end
    end
    return dropped
end

--- Unload every non-reserved item into the inventory the turtle is
--- currently facing (or above/below, per `direction`). The caller is
--- responsible for having navigated to the configured unload point
--- first. Returns true on full success; false + classified error if
--- storage is missing or fills up partway through (state prior to
--- the failure is left intact -- items already dropped are gone,
--- items still undroppable remain in the turtle's inventory, so no
--- items are lost, and the caller can retry or report the exact
--- remaining fill level).
function inventory:unload(direction)
    direction = direction or "forward"
    local suffix = ({ forward = "", up = "Up", down = "Down" })[direction]
    local detectFn = self.turtle["detect" .. suffix]
    local dropFn = self.turtle["drop" .. suffix]

    if not detectFn() then
        return false, errors.make(errors.CONFIGURATION_ERROR, "no_storage_present")
    end

    for _, slot in ipairs(self:usableSlots()) do
        if self.turtle.getItemCount(slot) > 0 then
            self.turtle.select(slot)
            local ok, err = dropFn()
            if not ok then
                return false, errors.make(errors.RESOURCE_EXHAUSTED, "storage_full:" .. tostring(err))
            end
        end
    end
    return true
end

return inventory
