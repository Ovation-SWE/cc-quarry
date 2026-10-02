--- GPS reconciliation for lib/navigation.lua.
--
-- CC:Tweaked turtles have no compass; gps.locate() reports position
-- only, never facing (see tweaked.cc/module/gps.html). This module:
--
--   1. Never trusts a GPS fix blindly: reconcile() compares it
--      against the navigator's dead-reckoned position and only
--      accepts it if consistent (or explicitly re-derives facing via
--      a controlled calibration move -- see calibrateFacing()).
--   2. Treats "GPS unavailable" (no constellation in range, timeout,
--      wireless range issues) as a normal, expected condition, not an
--      error: the worker simply keeps relying on dead reckoning and
--      tries again later.
--   3. Treats a *mismatch* between GPS and dead reckoning as serious:
--      it marks the navigator's position untrusted, which makes
--      lib/mining.lua and lib/navigation.lua refuse to continue
--      until the operator/master resolves it. We never "split the
--      difference" or guess which source is right.
--
-- A working gps.locate() requires an operator-provided GPS host
-- constellation (at least 4 fixed computers broadcasting on the GPS
-- channel per tweaked.cc/guide/gps_setup.html) -- this module cannot
-- create that infrastructure, only consume it defensively.

local directions = require("directions")

local gpsnav = {}
gpsnav.__index = gpsnav

--- deps = {
--   gps = <gps API>,      -- defaults to global `gps`
--   nav = <navigation instance>,
--   log = <logger, optional>,
--   timeout = <seconds>,  -- default 2, per gps.locate's own default
--   tolerance = <blocks>, -- default 0 (exact match required)
-- }
function gpsnav.new(deps)
    assert(deps and deps.nav, "gpsnav.new requires deps.nav")
    local self = setmetatable({}, gpsnav)
    self.gps = deps.gps or gps
    self.nav = deps.nav
    self.log = deps.log
    self.timeout = deps.timeout or 2
    self.tolerance = deps.tolerance or 0
    return self
end

--- Raw GPS fix, or nil if unavailable/timed out. Never throws.
function gpsnav:locateRaw()
    local ok, x, y, z = pcall(self.gps.locate, self.timeout)
    if not ok or x == nil then
        return nil
    end
    return x, y, z
end

--- Compare a GPS fix against the navigator's dead-reckoned position.
--- Returns:
--   true                          -- consistent (or GPS unavailable; not an error)
--   false, "gps_unavailable"      -- no fix could be obtained this time
--   false, "gps_mismatch"         -- fix disagrees with dead reckoning; nav marked untrusted
function gpsnav:reconcile()
    local x, y, z = self:locateRaw()
    if not x then
        if self.log then self.log:verbose("gps unavailable, continuing on dead reckoning") end
        return false, "gps_unavailable"
    end

    local ex, ey, ez = self.nav:getPosition()
    local dx = math.abs(x - ex)
    local dy = math.abs(y - ey)
    local dz = math.abs(z - ez)

    if dx <= self.tolerance and dy <= self.tolerance and dz <= self.tolerance then
        return true
    end

    if self.log then
        self.log:error("gps position mismatch", {
            x = ex, y = ey, z = ez,
            error = string.format("gps reported (%d,%d,%d), expected (%d,%d,%d)",
                math.floor(x + 0.5), math.floor(y + 0.5), math.floor(z + 0.5), ex, ey, ez),
        })
    end
    self.nav:markUntrusted("gps_mismatch")
    return false, "gps_mismatch"
end

--- Determine facing by taking a GPS fix, performing one raw forward
--- move via `turtleApi` directly (bypassing nav's facing-based delta
--- application, since facing isn't known yet), taking a second fix,
--- and inferring facing from the observed (dx, dz). On success,
--- atomically corrects both position and facing via nav:setPosition.
--- Intended for first-boot calibration once the operator has
--- physically placed/oriented the turtle at the job's starting cell.
function gpsnav:calibrateFacing(turtleApi)
    local x1, _, z1 = self:locateRaw()
    if not x1 then return false, "gps_unavailable" end

    local ok, err = turtleApi.forward()
    if not ok then
        return false, "calibration_move_blocked:" .. tostring(err)
    end

    local x2, y2, z2 = self:locateRaw()
    if not x2 then
        self.nav:markUntrusted("gps_lost_during_calibration")
        return false, "gps_unavailable_after_move"
    end

    local dx, dz = x2 - x1, z2 - z1
    local facing = directions.fromDelta(dx, dz)
    if not facing then
        self.nav:markUntrusted("non_cardinal_calibration_delta")
        return false, "non_cardinal_movement_delta"
    end

    self.nav:setPosition(math.floor(x2 + 0.5), math.floor(y2 + 0.5), math.floor(z2 + 0.5), facing)
    return true, facing
end

return gpsnav
