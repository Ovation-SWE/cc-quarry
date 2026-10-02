-- Worker bootstrap. Auto-run by CC:Tweaked on every boot (a file
-- named "startup" or "startup.lua" in the computer's root directory).
-- Deliberately tiny: all real logic lives in worker.lua + lib/*.lua,
-- which are unit-tested (see tests/). This file's only job is to
-- start that program reliably and fail loudly (never silently) if it
-- cannot.

-- Must use shell.run, not dofile: CC:Tweaked's dofile() always loads with
-- the raw global environment (see bios.lua), which does not have
-- require/package on it -- those only exist in the fresh per-program
-- environment the shell builds for each program it runs. worker.lua needs
-- require() for lib/*.lua, so it must be launched the same way any other
-- shell program is.
local ok = shell.run("worker.lua")
if not ok then
    print("The worker has stopped. Check the error above, then reboot")
    print("once it is resolved (see docs/TROUBLESHOOTING.md).")
end
