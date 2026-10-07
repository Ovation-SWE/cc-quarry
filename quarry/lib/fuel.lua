--- Defensive fuel management: budget checks before committing to a
--- trip, and automatic refueling from configured inventory slots.
--
-- CC:Tweaked turtles consume exactly 1 fuel per block moved (forward/
-- back/up/down); turning is free. turtle.getFuelLevel() can return
-- the string "unlimited" if the server has unlimited fuel enabled --
-- every check here treats that as "always sufficient" rather than
-- doing arithmetic on a string.

local errors = require("errors")

local fuel = {}
fuel.__index = fuel

--- deps = {
--   turtle = <turtle API>,
--   refuelSlots = { 1, 2, ... } | nil,  -- nil = try every slot
--   reserve = <number>,                 -- fuel that must always remain unspent
--   log = <logger, optional>,
-- }
function fuel.new(deps)
    assert(deps and deps.turtle, "fuel.new requires deps.turtle")
    local self = setmetatable({}, fuel)
    self.turtle = deps.turtle
    self.refuelSlots = deps.refuelSlots
    self.reserve = deps.reserve or 0
    self.log = deps.log
    return self
end

function fuel:level()
    return self.turtle.getFuelLevel()
end

function fuel:isUnlimited()
    return self:level() == "unlimited"
end

--- True if `distance` blocks of movement can be completed while still
--- keeping at least `extraReserve` (defaults to self.reserve) fuel
--- in the tank afterward.
function fuel:hasEnoughFor(distance, extraReserve)
    if self:isUnlimited() then return true end
    extraReserve = extraReserve or self.reserve
    return self:level() >= (distance + extraReserve)
end

--- Budget check for a full round trip: distance there, plus distance
--- back to a safe/return point, plus the configured reserve. This is
--- the check that must pass *before* a worker commits to entering a
--- region it might not be able to leave.
function fuel:canAffordRoundTrip(distanceThere, distanceBack)
    return self:hasEnoughFor(distanceThere + distanceBack, self.reserve)
end

--- Attempt to consume combustible items from the configured slots
--- until `targetLevel` is reached (or unlimited, or no more fuel items
--- are found). Returns true if targetLevel was reached, false + a
--- classified error otherwise. Never assumes a specific fuel item.
function fuel:autoRefuel(targetLevel)
    if self:isUnlimited() then return true end
    if self:level() >= targetLevel then return true end

    local prevSlot = self.turtle.getSelectedSlot()
    local slots = self.refuelSlots
    if not slots then
        slots = {}
        for i = 1, 16 do slots[i] = i end
    end

    for _, slot in ipairs(slots) do
        if self:level() >= targetLevel then break end
        local count = self.turtle.getItemCount(slot)
        if count > 0 then
            self.turtle.select(slot)
            local ok = self.turtle.refuel()
            if not ok and self.log then
                self.log:verbose("refuel attempt on slot had no combustible item", { slot = slot })
            end
        end
    end
    self.turtle.select(prevSlot)

    if self:level() >= targetLevel then
        return true
    end
    return false, errors.make(errors.RESOURCE_EXHAUSTED, "insufficient_fuel_items")
end

--- Pull items from whatever the turtle is facing (a depot chest, by
--- convention -- see docs/SETUP.md) via turtle.suck(), then burn
--- whatever was collected via autoRefuel(). turtle.suck() is an
--- inventory operation, not movement, so it costs no fuel: this works
--- even from an empty tank, which is what lets a worker be placed at
--- a depot with zero pre-loaded fuel. Bounded by maxAttempts (default
--- 64) so an empty/absent depot can never hang the worker. Returns
--- true once targetLevel is reached; false + autoRefuel's classified
--- error if the depot ran out of suckable combustible items first.
function fuel:collectFromDepot(targetLevel, maxAttempts)
    if self:isUnlimited() then return true end
    maxAttempts = maxAttempts or 64
    for _ = 1, maxAttempts do
        if self:level() >= targetLevel then break end
        local sucked = self.turtle.suck()
        if not sucked then break end
    end
    return self:autoRefuel(targetLevel)
end

--- Ensure at least `needed` fuel is available (including reserve),
--- auto-refueling if necessary. This is the function callers should
--- use before any multi-block movement.
function fuel:ensure(needed)
    if self:isUnlimited() then return true end
    if self:level() >= needed then return true end
    local ok, err = self:autoRefuel(needed)
    if not ok then return false, err end
    return true
end

return fuel
