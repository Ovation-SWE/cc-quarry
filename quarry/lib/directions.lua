--- Cardinal-direction helpers. Facing convention matches the Minecraft
--- compass / F3 debug screen: 0=north(-Z) 1=east(+X) 2=south(+Z) 3=west(-X).
--
-- CC:Tweaked turtles have no compass API: there is no function that
-- reports which way a turtle is facing. The only ground truth is
-- (a) the operator physically orienting the turtle to a known facing
-- before deployment, and (b) inferring facing from the position delta
-- of two GPS fixes taken before/after a confirmed successful forward
-- move. This module only provides the pure vector math; lib/gpsnav.lua
-- and lib/navigation.lua use it to track and validate facing.

local directions = {}

directions.NORTH = 0
directions.EAST = 1
directions.SOUTH = 2
directions.WEST = 3

local VECTORS = {
    [0] = { x = 0, z = -1 },
    [1] = { x = 1, z = 0 },
    [2] = { x = 0, z = 1 },
    [3] = { x = -1, z = 0 },
}

local NAMES = { [0] = "north", [1] = "east", [2] = "south", [3] = "west" }

function directions.vector(facing)
    local v = VECTORS[facing % 4]
    return v.x, v.z
end

function directions.left(facing)
    return (facing - 1) % 4
end

function directions.right(facing)
    return (facing + 1) % 4
end

function directions.opposite(facing)
    return (facing + 2) % 4
end

function directions.name(facing)
    return NAMES[facing % 4] or "unknown"
end

--- Number of right turns (0-3) needed to rotate from `facing` to `target`.
function directions.turnsRight(facing, target)
    return (target - facing) % 4
end

--- Infer a facing (0-3) from an observed (dx, dz) unit movement delta.
--- Returns nil if the delta doesn't match any cardinal direction
--- (e.g. diagonal movement / no movement), which must never be
--- silently guessed away by callers.
function directions.fromDelta(dx, dz)
    for facing, v in pairs(VECTORS) do
        if v.x == dx and v.z == dz then
            return facing
        end
    end
    return nil
end

return directions
