-- Tests for lib/gpsnav.lua: GPS reconciliation and facing calibration.
-- Run with: lua tests/test_gpsnav.lua   (from the quarry/ directory)

package.path = "./lib/?.lua;./tests/mocks/?.lua;" .. package.path
local navigation = require("navigation")
local gpsnav = require("gpsnav")
local directions = require("directions")
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

-- 1. GPS unavailable is treated as a normal (non-fatal) condition
do
    local w = World.new({})
    local nav = navigation.new({ turtle = w:turtleAPI(), sleep = noSleep })
    local gpsApi = { locate = function() return nil end }
    local gn = gpsnav.new({ gps = gpsApi, nav = nav })
    local ok, reason = gn:reconcile()
    check(ok == false, "reconcile() reports failure when GPS is unavailable")
    check(reason == "gps_unavailable", "reason is gps_unavailable, not an error")
    check(nav:isTrusted() == true, "dead-reckoned position remains trusted when GPS is simply absent")
end

-- 2. Consistent GPS fix confirms trust without altering position
do
    local w = World.new({})
    local nav = navigation.new({ turtle = w:turtleAPI(), sleep = noSleep }, { x = 5, y = 10, z = -3 })
    local gpsApi = { locate = function() return 5, 10, -3 end }
    local gn = gpsnav.new({ gps = gpsApi, nav = nav })
    local ok = gn:reconcile()
    check(ok == true, "matching GPS fix reconciles successfully")
    check(nav:isTrusted() == true, "position remains trusted")
    check(nav.x == 5 and nav.y == 10 and nav.z == -3, "position unchanged by a consistent fix")
end

-- 3. Mismatched GPS fix marks the navigator untrusted (fail-safe, no guessing)
do
    local w = World.new({})
    local nav = navigation.new({ turtle = w:turtleAPI(), sleep = noSleep }, { x = 0, y = 0, z = 0 })
    local gpsApi = { locate = function() return 100, 0, 0 end } -- wildly different
    local gn = gpsnav.new({ gps = gpsApi, nav = nav })
    local ok, reason = gn:reconcile()
    check(ok == false, "mismatched GPS fix reported as failure")
    check(reason == "gps_mismatch", "reason is gps_mismatch")
    check(nav:isTrusted() == false, "navigator marked untrusted on mismatch")
end

-- 4. Facing calibration correctly infers facing from an observed GPS delta
for facing = 0, 3 do
    local w = World.new({ x = 10, y = 5, z = 10, facing = facing })
    local nav = navigation.new({ turtle = w:turtleAPI(), sleep = noSleep }, { x = 10, y = 5, z = 10, facing = nil })
    local gpsApi = { locate = function() return w.pos.x, w.pos.y, w.pos.z end }
    local gn = gpsnav.new({ gps = gpsApi, nav = nav })
    local ok, inferredFacing = gn:calibrateFacing(w:turtleAPI())
    check(ok == true, "calibration succeeds facing " .. directions.name(facing))
    check(inferredFacing == facing, "calibration correctly infers facing " .. directions.name(facing))
    check(nav.facing == facing, "nav facing updated to match physical orientation")
end

-- 5. Calibration move blocked: fails without corrupting position
do
    local w = World.new({ x = 0, y = 0, z = 0, facing = directions.SOUTH })
    w:setBlock(0, 0, 1, "minecraft:stone")
    local nav = navigation.new({ turtle = w:turtleAPI(), sleep = noSleep }, { x = 0, y = 0, z = 0 })
    local gpsApi = { locate = function() return w.pos.x, w.pos.y, w.pos.z end }
    local gn = gpsnav.new({ gps = gpsApi, nav = nav })
    local ok, reason = gn:calibrateFacing(w:turtleAPI())
    check(ok == false, "calibration fails when the forward move is blocked")
    check(reason:find("calibration_move_blocked") ~= nil, "reason explains the blocked calibration move")
    check(nav:isTrusted() == true, "blocked calibration does not itself mark position untrusted (no move occurred)")
end

print(string.format("\n%d checks, %d failures", checks, failures))
if failures > 0 then os.exit(1) end
