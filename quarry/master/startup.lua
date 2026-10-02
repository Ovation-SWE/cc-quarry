-- Master bootstrap. Auto-run by CC:Tweaked on every boot. Kept tiny
-- for the same reasons as worker/startup.lua: all real logic lives in
-- master.lua + lib/*.lua.

-- Must use shell.run, not dofile: see worker/startup.lua for why (CC:Tweaked's
-- dofile() loads with the raw global environment, which lacks require/package).
local ok = shell.run("master.lua")
if not ok then
    print("Fix the issue above, then run 'master' or reboot to retry.")
end
