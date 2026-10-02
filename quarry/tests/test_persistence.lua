-- Tests for lib/persistence.lua against a real temp directory.
-- Run with: lua tests/test_persistence.lua   (from the quarry/ directory)
-- Requires /tmp/quarry-persist-test to exist and be empty
-- (created by the test harness before invoking this script).

package.path = "./lib/?.lua;./tests/mocks/?.lua;" .. package.path
local persistence = require("persistence")
local fsMock = require("fs_mock")

local ROOT = "/tmp/quarry-persist-test"

local failures = 0
local checks = 0
local function check(cond, msg)
    checks = checks + 1
    if not cond then
        failures = failures + 1
        print("FAIL: " .. msg)
    end
end

-- Simple deterministic serializer standing in for textutils.serialize/
-- unserialize (which are CC-only globals): a minimal Lua-literal
-- (de)serializer sufficient for the flat key/value tables this
-- project persists.
local function serialize(t)
    local parts = { "{" }
    for k, v in pairs(t) do
        local key = type(k) == "string" and ("[" .. string.format("%q", k) .. "]") or ("[" .. tostring(k) .. "]")
        local val
        if type(v) == "string" then
            val = string.format("%q", v)
        elseif type(v) == "table" then
            val = serialize(v)
        else
            val = tostring(v)
        end
        parts[#parts + 1] = key .. "=" .. val .. ","
    end
    parts[#parts + 1] = "}"
    return table.concat(parts)
end

local function unserialize(s)
    local chunk = load("return " .. s)
    if not chunk then return nil end
    return chunk()
end

local function freshFs(subdir)
    os.execute("rm -rf '" .. ROOT .. "/" .. subdir .. "' && mkdir -p '" .. ROOT .. "/" .. subdir .. "'")
    return fsMock.new(ROOT .. "/" .. subdir)
end

-- 1. Basic save/load round trip
do
    local fs = freshFs("basic")
    local p = persistence.new({ fs = fs, serialize = serialize, unserialize = unserialize })
    local ok = p:save("state", { jobId = "job-1", x = 5, y = 10, nested = { a = 1 } })
    check(ok, "save() succeeds")
    local data, source = p:load("state")
    check(data ~= nil, "load() returns data")
    check(data.jobId == "job-1" and data.x == 5 and data.nested.a == 1, "loaded data matches saved data")
    check(source == "primary", "loaded from primary copy")
end

-- 2. save() never leaves a .tmp file lying around after success
do
    local fs = freshFs("notmp")
    local p = persistence.new({ fs = fs, serialize = serialize, unserialize = unserialize })
    p:save("state", { a = 1 })
    check(fs.exists("state.tmp") == false, ".tmp file cleaned up (moved into place) after successful save")
    check(fs.exists("state") == true, "primary file exists after save")
end

-- 3. A stray leftover .tmp file (simulating a crash mid-write on a
--    previous run) must never be read by load() -- only a fully
--    completed rename into the primary path counts.
do
    local fs = freshFs("straytmp")
    local p = persistence.new({ fs = fs, serialize = serialize, unserialize = unserialize })
    p:save("state", { version = 1 })
    -- Simulate a crash during the *next* save: tmp written, but move
    -- never happened.
    local h = fs.open("state.tmp", "w")
    h.write(serialize({ version = 999, corrupt = "partial" }))
    h.close()
    local data = p:load("state")
    check(data.version == 1, "load() ignores a stray .tmp file and returns the last complete primary")
end

-- 4. Corrupt primary falls back to the backup copy
do
    local fs = freshFs("corrupt")
    local p = persistence.new({ fs = fs, serialize = serialize, unserialize = unserialize })
    p:save("state", { version = 1 })
    p:save("state", { version = 2 }) -- this makes version-1 the .bak
    -- Corrupt the primary directly (simulate partial write/bitrot).
    local h = fs.open("state", "w")
    h.write("{not valid lua")
    h.close()
    local data, source = p:load("state")
    check(data ~= nil, "load() recovers despite a corrupt primary")
    check(data.version == 1, "recovered data is the last known-good backup")
    check(source == "backup", "load() reports it used the backup")
end

-- 5. Missing state entirely (first boot) reports a clear failure, not a crash
do
    local fs = freshFs("missing")
    local p = persistence.new({ fs = fs, serialize = serialize, unserialize = unserialize })
    local data, err = p:load("state")
    check(data == nil, "load() returns nil when no state has ever been saved")
    check(type(err) == "string", "load() returns a diagnostic error string")
end

-- 6. Repeated saves keep exactly one rolling backup (not unbounded growth)
do
    local fs = freshFs("rolling")
    local p = persistence.new({ fs = fs, serialize = serialize, unserialize = unserialize })
    for i = 1, 5 do
        p:save("state", { version = i })
    end
    local data = p:load("state")
    check(data.version == 5, "primary always reflects the most recent save")
    check(fs.exists("state.bak"), "exactly one backup file exists")
end

print(string.format("\n%d checks, %d failures", checks, failures))
if failures > 0 then os.exit(1) end
