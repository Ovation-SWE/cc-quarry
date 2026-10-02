--- Crash-safe persistence for worker/master state.
--
-- Writes go to a `.tmp` file first, then the previous good copy (if
-- any) is preserved as `.bak` before the tmp file replaces the real
-- path. This means a crash/power-loss/reboot at any point during a
-- save can only ever leave behind: the old good file untouched, OR
-- the old file renamed to `.bak` with a complete new file in place --
-- never a half-written primary file. load() falls back to `.bak`
-- automatically if the primary is missing or fails to deserialize.

local errors = require("errors")

local persistence = {}
persistence.__index = persistence

--- deps = {
--   fs = <fs API>,                    -- defaults to global `fs`
--   serialize = function(t) -> string,   -- defaults to textutils.serialize
--   unserialize = function(s) -> table,  -- defaults to textutils.unserialize
-- }
function persistence.new(deps)
    deps = deps or {}
    local self = setmetatable({}, persistence)
    self.fs = deps.fs or fs
    self.serialize = deps.serialize or (textutils and textutils.serialize)
    self.unserialize = deps.unserialize or (textutils and textutils.unserialize)
    return self
end

function persistence:save(path, data)
    local ok, serialized = pcall(self.serialize, data)
    if not ok then
        return false, errors.make(errors.FATAL, "serialize_failed:" .. tostring(serialized))
    end

    local tmpPath = path .. ".tmp"
    local handle, openErr = self.fs.open(tmpPath, "w")
    if not handle then
        return false, errors.make(errors.RECOVERABLE, "open_tmp_failed:" .. tostring(openErr))
    end
    handle.write(serialized)
    handle.close()

    if self.fs.exists(path) then
        local bakPath = path .. ".bak"
        if self.fs.exists(bakPath) then self.fs.delete(bakPath) end
        self.fs.copy(path, bakPath)
        self.fs.delete(path)
    end
    self.fs.move(tmpPath, path)
    return true
end

function persistence:_loadFile(path)
    if not self.fs.exists(path) then
        return nil, "not_found"
    end
    local handle, openErr = self.fs.open(path, "r")
    if not handle then
        return nil, "open_failed:" .. tostring(openErr)
    end
    local content = handle.readAll()
    handle.close()
    local ok, data = pcall(self.unserialize, content)
    if not ok or data == nil then
        return nil, "corrupt_or_empty"
    end
    return data
end

--- Load `path`, transparently falling back to `path..".bak"` if the
--- primary is missing or corrupt (e.g. a reboot happened mid-write
--- before this module existed, or external corruption). Returns
--- data, "primary"|"backup" on success, or nil, errString on total
--- failure (both copies missing/corrupt).
function persistence:load(path)
    local data, err = self:_loadFile(path)
    if data then return data, "primary" end

    local backupData, backupErr = self:_loadFile(path .. ".bak")
    if backupData then return backupData, "backup" end

    return nil, errors.make(errors.RECOVERABLE, "no_valid_state:" .. tostring(err) .. "/" .. tostring(backupErr))
end

return persistence
