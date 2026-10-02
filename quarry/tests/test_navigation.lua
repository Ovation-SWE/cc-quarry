-- Tests for lib/navigation.lua against the deterministic mock world.
-- Run with: lua tests/test_navigation.lua   (from the quarry/ directory)

package.path = "./lib/?.lua;./tests/mocks/?.lua;" .. package.path
local navigation = require("navigation")
local directions = require("directions")
local errors = require("errors")
local World = require("world")

local failures = 0
local checks = 0
local function check(cond, msg)
    checks = checks + 1
    if not cond then
        failures = failures + 1
        print("FAIL: " .. msg)
    end
end

local function noSleep() end

-- 1. Basic forward movement updates position correctly for all facings
for facing = 0, 3 do
    local w = World.new({ x = 0, y = 0, z = 0, facing = facing })
    local nav = navigation.new({ turtle = w:turtleAPI(), sleep = noSleep }, { x = 0, y = 0, z = 0, facing = facing })
    local ok = nav:forward()
    check(ok, "forward() succeeds facing " .. directions.name(facing))
    local dx, dz = directions.vector(facing)
    check(nav.x == dx and nav.z == dz, "position updates correctly facing " .. directions.name(facing))
end

-- 2. turnLeft/turnRight update facing and are inverse of each other
do
    local w = World.new({})
    local nav = navigation.new({ turtle = w:turtleAPI(), sleep = noSleep })
    nav:turnRight()
    check(nav.facing == directions.EAST, "turnRight from north goes to east")
    nav:turnLeft()
    check(nav.facing == directions.NORTH, "turnLeft undoes turnRight")
end

-- 3. face() picks shortest path
do
    local w = World.new({})
    local nav = navigation.new({ turtle = w:turtleAPI(), sleep = noSleep })
    nav:face(directions.WEST) -- north -> west is one turnLeft
    check(nav.facing == directions.WEST, "face(WEST) from NORTH lands on WEST")
end

-- 4. Movement blocked by a solid block fails without an obstacleHandler
do
    local w = World.new({ x = 0, y = 0, z = 0, facing = directions.EAST })
    w:setBlock(1, 0, 0, "minecraft:stone")
    local nav = navigation.new({ turtle = w:turtleAPI(), sleep = noSleep, maxMoveRetries = 3 })
    local ok, err = nav:forward()
    check(ok == false, "forward() fails when blocked with no obstacleHandler")
    check(errors.kindOf(err) == errors.BLOCKED, "blocked movement classified as BLOCKED")
    check(nav.x == 0, "position unchanged after failed move")
end

-- 5. obstacleHandler is consulted and, once it clears the block, movement succeeds
do
    local w = World.new({ x = 0, y = 0, z = 0, facing = directions.EAST })
    w:setBlock(1, 0, 0, "minecraft:dirt")
    local cleared = false
    local handler = function(kind)
        check(kind == "forward", "obstacleHandler receives correct kind")
        w:setBlock(1, 0, 0, nil)
        cleared = true
        return true
    end
    local nav = navigation.new({ turtle = w:turtleAPI(), sleep = noSleep, obstacleHandler = handler },
        { x = 0, y = 0, z = 0, facing = directions.EAST })
    local ok = nav:forward()
    check(ok, "forward() succeeds after obstacleHandler clears the block")
    check(cleared, "obstacleHandler was actually invoked")
    check(nav.x == 1, "position updated after obstacle cleared")
end

-- 6. Out of fuel is classified as RESOURCE_EXHAUSTED and never partially applied
do
    local w = World.new({ x = 0, y = 0, z = 0, facing = directions.EAST, fuel = 0 })
    local nav = navigation.new({ turtle = w:turtleAPI(), sleep = noSleep })
    local ok, err = nav:forward()
    check(ok == false, "forward() fails with zero fuel")
    check(errors.kindOf(err) == errors.RESOURCE_EXHAUSTED, "no-fuel classified as RESOURCE_EXHAUSTED")
    check(nav.x == 0, "position unchanged when out of fuel")
end

-- 7. moveTo executes multi-axis travel and stops immediately on failure
do
    local w = World.new({ x = 0, y = 0, z = 0, facing = directions.NORTH })
    w:setBlock(3, 0, 5, "minecraft:stone") -- block path along Z at x=3
    local nav = navigation.new({ turtle = w:turtleAPI(), sleep = noSleep, maxMoveRetries = 2 })
    local ok = nav:moveTo(3, 0, 10)
    check(ok == false, "moveTo aborts when a leg is blocked")
    check(nav.x == 3, "moveTo made partial progress on X before failing")
    check(nav.z < 10, "moveTo did not silently continue past the blocked leg")
end

-- 8. moveTo succeeds end-to-end on an open path, respecting axis order
do
    local w = World.new({ x = 0, y = 0, z = 0, facing = directions.NORTH })
    local nav = navigation.new({ turtle = w:turtleAPI(), sleep = noSleep })
    local ok = nav:moveTo(2, 3, -2)
    check(ok, "moveTo succeeds on an open path")
    check(nav.x == 2 and nav.y == 3 and nav.z == -2, "final position matches requested target")
end

-- 9. Position marked untrusted refuses further movement (fail-safe)
do
    local w = World.new({})
    local nav = navigation.new({ turtle = w:turtleAPI(), sleep = noSleep })
    nav:markUntrusted("gps_mismatch")
    local ok, err = nav:forward()
    check(ok == false, "movement refused while position is untrusted")
    check(errors.kindOf(err) == errors.FATAL, "untrusted-position movement attempt classified FATAL")
end

-- 10. setPosition explicitly restores trust
do
    local w = World.new({})
    local nav = navigation.new({ turtle = w:turtleAPI(), sleep = noSleep })
    nav:markUntrusted("test")
    check(nav:isTrusted() == false, "isTrusted() false after markUntrusted")
    nav:setPosition(5, 5, 5, directions.SOUTH)
    check(nav:isTrusted() == true, "isTrusted() true after explicit setPosition")
    check(nav.x == 5 and nav.facing == directions.SOUTH, "setPosition applies coordinates and facing")
end

-- 11. serialize/restore round-trip
do
    local w = World.new({})
    local nav = navigation.new({ turtle = w:turtleAPI(), sleep = noSleep }, { x = 7, y = 8, z = 9, facing = directions.SOUTH })
    local state = nav:serialize()
    local nav2 = navigation.new({ turtle = w:turtleAPI(), sleep = noSleep }, state)
    check(nav2.x == 7 and nav2.y == 8 and nav2.z == 9 and nav2.facing == directions.SOUTH,
        "navigation state round-trips through serialize/restore")
end

-- 12. Bounded retries: obstacleHandler that never clears the block does not hang
do
    local w = World.new({ x = 0, y = 0, z = 0, facing = directions.EAST })
    w:setBlock(1, 0, 0, "minecraft:bedrock", { protected = true })
    local calls = 0
    local handler = function() calls = calls + 1; return false, "PROTECTED" end
    local nav = navigation.new({ turtle = w:turtleAPI(), sleep = noSleep, obstacleHandler = handler, maxMoveRetries = 4 })
    local ok, err = nav:forward()
    check(ok == false, "forward() eventually gives up against a permanent obstacle")
    check(calls == 1, "obstacleHandler consulted exactly once before giving up (handler itself signals no-retry)")
    check(errors.kindOf(err) == errors.BLOCKED, "permanent obstacle classified BLOCKED")
end

print(string.format("\n%d checks, %d failures", checks, failures))
if failures > 0 then os.exit(1) end
