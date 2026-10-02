--- Coordinate-based navigation engine for quarry turtles.
--
-- Position is tracked purely by dead reckoning: { x, y, z, facing }.
-- CC:Tweaked turtles have no compass, so `facing` only ever changes
-- through turnLeft()/turnRight() calls this module itself issues, and
-- `x/y/z` only change after a movement call *reports success*. GPS is
-- deliberately not consulted inside this module -- lib/gpsnav.lua
-- handles reconciling dead-reckoned position against gps.locate(),
-- and only calls nav:setPosition() when it has verified the fix is
-- trustworthy. This module never "corrects" itself silently.
--
-- Dependency-injected turtle API + sleep function so this module is
-- fully unit-testable against a mock world (see tests/mocks/world.lua)
-- without a running Minecraft instance.

local directions = require("directions")
local errors = require("errors")

local navigation = {}
navigation.__index = navigation

local DEFAULTS = {
    maxMoveRetries = 6,
    maxTurnRetries = 3,
    retryDelay = 0.5,
}

--- deps = {
--    turtle = <turtle API table>,
--    sleep = function(seconds) ... end,               -- defaults to global sleep
--    obstacleHandler = function(kind) -> boolean ... , -- kind: "forward"|"up"|"down"
--                                                       -- returns true if the path is now clear
--    maxMoveRetries, maxTurnRetries, retryDelay,
-- }
function navigation.new(deps, initial)
    assert(deps and deps.turtle, "navigation.new requires deps.turtle")
    local self = setmetatable({}, navigation)
    self.turtle = deps.turtle
    self.sleep = deps.sleep or sleep
    self.obstacleHandler = deps.obstacleHandler
    self.maxMoveRetries = deps.maxMoveRetries or DEFAULTS.maxMoveRetries
    self.maxTurnRetries = deps.maxTurnRetries or DEFAULTS.maxTurnRetries
    self.retryDelay = deps.retryDelay or DEFAULTS.retryDelay

    initial = initial or {}
    self.x = initial.x or 0
    self.y = initial.y or 0
    self.z = initial.z or 0
    self.facing = initial.facing or directions.NORTH
    self.trusted = initial.trusted
    if self.trusted == nil then self.trusted = true end
    self.untrustedReason = initial.untrustedReason

    return self
end

function navigation:getPosition()
    return self.x, self.y, self.z, self.facing
end

function navigation:isTrusted()
    return self.trusted
end

--- Explicit, deliberate override of the tracked position. Only ever
--- called by lib/gpsnav.lua after it has verified a GPS fix is
--- consistent (or by the operator-confirmed initial calibration).
--- Never called implicitly as a side effect of a normal move.
function navigation:setPosition(x, y, z, facing)
    self.x, self.y, self.z = x, y, z
    if facing ~= nil then self.facing = facing end
    self.trusted = true
    self.untrustedReason = nil
end

--- Mark the current position as no longer trustworthy. Once
--- untrusted, mining/movement callers must stop rather than guess.
function navigation:markUntrusted(reason)
    self.trusted = false
    self.untrustedReason = reason
end

function navigation:serialize()
    return {
        x = self.x, y = self.y, z = self.z, facing = self.facing,
        trusted = self.trusted, untrustedReason = self.untrustedReason,
    }
end

local function fuelAvailable(turtleApi)
    local level = turtleApi.getFuelLevel()
    if level == "unlimited" then return true end
    return level > 0
end

--- Internal: perform one primitive movement (forward/back/up/down)
--- with bounded retry + obstacle-clearing.
function navigation:_move(kind)
    if not self.trusted then
        return false, errors.make(errors.FATAL, "position_untrusted:" .. tostring(self.untrustedReason))
    end
    if not fuelAvailable(self.turtle) then
        return false, errors.make(errors.RESOURCE_EXHAUSTED, "no_fuel")
    end

    local moveFn = self.turtle[kind]
    local attempts = 0
    while attempts < self.maxMoveRetries do
        attempts = attempts + 1
        local ok, err = moveFn()
        if ok then
            self:_applyDelta(kind)
            return true
        end

        if err == "Out of fuel" then
            return false, errors.make(errors.RESOURCE_EXHAUSTED, "no_fuel")
        end

        if (kind == "forward" or kind == "up" or kind == "down") and self.obstacleHandler then
            local cleared, clearErr = self.obstacleHandler(kind)
            if not cleared then
                return false, errors.make(errors.BLOCKED, clearErr or err or "obstacle_not_cleared")
            end
            -- obstacle cleared; loop around and retry the move immediately
        else
            if self.sleep then self.sleep(self.retryDelay) end
        end
    end
    return false, errors.make(errors.BLOCKED, "max_move_retries_exceeded")
end

function navigation:_applyDelta(kind)
    if kind == "up" then
        self.y = self.y + 1
    elseif kind == "down" then
        self.y = self.y - 1
    elseif kind == "forward" or kind == "back" then
        local dx, dz = directions.vector(self.facing)
        if kind == "back" then dx, dz = -dx, -dz end
        self.x = self.x + dx
        self.z = self.z + dz
    end
end

function navigation:forward() return self:_move("forward") end
function navigation:back() return self:_move("back") end
function navigation:up() return self:_move("up") end
function navigation:down() return self:_move("down") end

function navigation:turnLeft()
    local attempts = 0
    while attempts < self.maxTurnRetries do
        attempts = attempts + 1
        local ok, err = self.turtle.turnLeft()
        if ok then
            self.facing = directions.left(self.facing)
            return true
        end
        if self.sleep then self.sleep(self.retryDelay) end
        if attempts == self.maxTurnRetries then
            return false, errors.make(errors.FATAL, err or "turn_left_failed")
        end
    end
end

function navigation:turnRight()
    local attempts = 0
    while attempts < self.maxTurnRetries do
        attempts = attempts + 1
        local ok, err = self.turtle.turnRight()
        if ok then
            self.facing = directions.right(self.facing)
            return true
        end
        if self.sleep then self.sleep(self.retryDelay) end
        if attempts == self.maxTurnRetries then
            return false, errors.make(errors.FATAL, err or "turn_right_failed")
        end
    end
end

--- Rotate to face `target` (0-3) via the shortest turn sequence.
function navigation:face(target)
    local turns = directions.turnsRight(self.facing, target)
    if turns == 0 then return true end
    if turns == 3 then
        return self:turnLeft()
    end
    for _ = 1, turns do
        local ok, err = self:turnRight()
        if not ok then return false, err end
    end
    return true
end

--- Move along the X axis to targetX, one block at a time.
function navigation:moveX(targetX)
    while self.x ~= targetX do
        local target = (targetX > self.x) and directions.EAST or directions.WEST
        local ok, err = self:face(target)
        if not ok then return false, err end
        ok, err = self:forward()
        if not ok then return false, err end
    end
    return true
end

--- Move along the Z axis to targetZ, one block at a time.
function navigation:moveZ(targetZ)
    while self.z ~= targetZ do
        local target = (targetZ > self.z) and directions.SOUTH or directions.NORTH
        local ok, err = self:face(target)
        if not ok then return false, err end
        ok, err = self:forward()
        if not ok then return false, err end
    end
    return true
end

--- Move along the Y axis to targetY, one block at a time.
function navigation:moveY(targetY)
    while self.y ~= targetY do
        local ok, err
        if targetY > self.y then
            ok, err = self:up()
        else
            ok, err = self:down()
        end
        if not ok then return false, err end
    end
    return true
end

--- Move to an absolute (x, y, z), axis by axis in a configurable
--- order (default: Y then X then Z). Aborts immediately (without
--- guessing) if any leg fails; the caller can inspect nav:getPosition()
--- to see exactly how far it got.
function navigation:moveTo(x, y, z, order)
    order = order or { "y", "x", "z" }
    local targets = { x = x, y = y, z = z }
    local fns = { x = self.moveX, y = self.moveY, z = self.moveZ }
    for _, axis in ipairs(order) do
        local ok, err = fns[axis](self, targets[axis])
        if not ok then return false, err end
    end
    return true
end

--- Manhattan distance to (x, y, z), including turn overhead ignored
--- (turns don't cost fuel). Used by lib/fuel.lua for budget checks.
function navigation:distanceTo(x, y, z)
    return math.abs(self.x - x) + math.abs(self.y - y) + math.abs(self.z - z)
end

return navigation
