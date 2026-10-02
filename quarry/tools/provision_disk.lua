--- Worker deployment station helper. Run this on ANY computer that
--- has a disk drive peripheral attached (this can be the master
--- computer itself, or a separate dedicated provisioning computer --
--- it does not need a modem or to be part of the quarry network at
--- all) and this computer's own filesystem must already contain the
--- full `lib/`, `worker/startup.lua`, and `worker/worker.lua` files
--- (i.e. it has a full copy of this repository).
--
-- This is the realistic, CC:Tweaked-supported answer to "how do many
-- worker turtles get their bootstrap code without the master writing
-- files into them over the network": a disk drive + floppy disk is a
-- real, documented peripheral (see tweaked.cc/peripheral/drive.html)
-- whose contents any computer can read/write via the ordinary fs API
-- once mounted, and whose mount path is retrieved via
-- drive.getMountPath() rather than assumed to be a fixed "disk/" --
-- multiple drives get distinct mount points ("disk", "disk1", ...).
--
-- Usage: insert a blank (or reusable) floppy disk, then run this
-- program. It writes lib/*, worker.lua, startup.lua, and a small
-- install.lua onto the disk. Carry the disk to a new turtle, insert
-- it (the turtle needs its own disk drive peripheral, or be placed
-- adjacent to a shared one on a wired network), and run `disk/install`
-- once. See docs/SETUP.md for the full worker provisioning procedure.

local drive = peripheral.find("drive")
if not drive then
    print("No disk drive peripheral found. Attach one (any side) and try again.")
    return
end

if not drive.isDiskPresent() then
    print("Insert a floppy disk into the drive, then run this program again.")
    return
end

local mountPath = drive.getMountPath()
if not mountPath then
    -- isDiskPresent() can be true for a non-data disk (e.g. a music
    -- record); only a data disk has a mount path.
    print("The inserted disk has no usable data storage (is it a music disk?).")
    return
end

print("Writing worker bootstrap files to " .. mountPath .. " ...")

if not fs.isDir("lib") or not fs.exists("worker/worker.lua") or not fs.exists("worker/startup.lua") then
    print("This computer does not have a full copy of the quarry repository")
    print("(expected lib/, worker/worker.lua, worker/startup.lua here). Copy")
    print("the repository onto this computer first -- see docs/SETUP.md.")
    return
end

if fs.exists(mountPath .. "/lib") then fs.delete(mountPath .. "/lib") end
fs.copy("lib", mountPath .. "/lib")
fs.copy("worker/worker.lua", mountPath .. "/worker.lua")
fs.copy("worker/startup.lua", mountPath .. "/bootstrap_startup.lua")

-- install.lua: the tiny program a fresh turtle runs (as `disk/install`)
-- to copy everything from the disk onto its own root filesystem. It
-- is deliberately simple enough to type by hand if a disk is ever
-- unavailable and pastebin/http access is the only alternative.
local installScript = [[
print("Installing quarry worker bootstrap from disk...")
if fs.exists("lib") then fs.delete("lib") end
fs.copy("disk/lib", "lib")
fs.copy("disk/worker.lua", "worker.lua")
fs.copy("disk/bootstrap_startup.lua", "startup.lua")
print("Done. Reboot this turtle to start the worker program.")
]]
local h = fs.open(mountPath .. "/install.lua", "w")
h.write(installScript)
h.close()

print("Done. Disk contents:")
for _, name in ipairs(fs.list(mountPath)) do
    print("  " .. name)
end
print("")
print("Carry this disk to each new worker turtle, insert it, and run:")
print("  disk/install")
print("then reboot the turtle.")
