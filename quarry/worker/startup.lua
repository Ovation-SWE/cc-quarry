-- Worker bootstrap. Auto-run by CC:Tweaked on every boot (a file
-- named "startup" or "startup.lua" in the computer's root directory).
-- Deliberately tiny: all real logic lives in worker.lua + lib/*.lua,
-- which are unit-tested (see tests/). This file's only job is to
-- start that program reliably and fail loudly (never silently) if it
-- cannot.

local ok, err = pcall(dofile, "worker.lua")
if not ok then
    print("worker.lua exited with an error:")
    print(tostring(err))
    print("The worker has stopped. Check the error above, then reboot")
    print("once it is resolved (see docs/TROUBLESHOOTING.md).")
end
