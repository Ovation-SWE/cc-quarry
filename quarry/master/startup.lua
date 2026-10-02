-- Master bootstrap. Auto-run by CC:Tweaked on every boot. Kept tiny
-- for the same reasons as worker/startup.lua: all real logic lives in
-- master.lua + lib/*.lua.

local ok, err = pcall(dofile, "master.lua")
if not ok then
    print("master.lua exited with an error:")
    print(tostring(err))
    print("Fix the issue above, then run 'master' or reboot to retry.")
end
