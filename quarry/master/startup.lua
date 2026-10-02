-- Master bootstrap. Auto-run by CC:Tweaked on every boot. Kept tiny
-- for the same reasons as worker/startup.lua: all real logic lives in
-- gui.lua/master.lua + lib/*.lua.
--
-- Launches the Basalt2 GUI (gui.lua) when it's installed and this
-- terminal can actually drive it (color + mouse -- see gui.lua's
-- header comment); otherwise falls back to the text UI (master.lua).
-- Run `gui` or `master` directly at any time to switch manually.

-- Must use shell.run, not dofile: see worker/startup.lua for why (CC:Tweaked's
-- dofile() loads with the raw global environment, which lacks require/package).
local useGui = fs.exists("basalt.lua") and fs.exists("gui.lua") and term.isColour()
local ok = shell.run(useGui and "gui.lua" or "master.lua")
if not ok then
    local fallback = useGui and "'gui' or 'master'" or "'master'"
    print("Fix the issue above, then run " .. fallback .. " or reboot to retry.")
end
