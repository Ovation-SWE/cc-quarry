--- Structured logging with normal/verbose/debug levels, terminal
--- output gated by level, and an optional rotating log file.
--
-- Every log call accepts a short message plus a `fields` table; the
-- fields most relevant to debugging a quarry (jobId, workerId, state,
-- coordinate, operation, error, retryCount) are always emitted in a
-- fixed order so log lines are easy to scan and grep.

local logging = {}
logging.__index = logging

local RANK = { error = 1, warn = 2, info = 3, verbose = 4, debug = 5 }
local THRESHOLD = { normal = 2, verbose = 4, debug = 5 }
local FIELD_ORDER = {
    "jobId", "workerId", "state", "x", "y", "z", "operation", "error", "retryCount", "attempt",
}

--- deps = {
--   fs = <fs API>,           -- defaults to global fs; nil disables file logging
--   path = <log file path>,  -- nil disables file logging
--   level = "normal"|"verbose"|"debug",
--   clock = function() -> ms,  -- defaults to os.epoch("utc") if available, else os.clock()
--   print = function(line),    -- defaults to global print
--   maxBytes = 100000,         -- rotate to path..".old" past this size
-- }
function logging.new(deps)
    deps = deps or {}
    local self = setmetatable({}, logging)
    self.fs = deps.fs or (type(fs) == "table" and fs or nil)
    self.path = deps.path
    self.level = deps.level or "normal"
    self.clock = deps.clock or function()
        if type(os) == "table" and os.epoch then return os.epoch("utc") end
        return math.floor(os.clock() * 1000)
    end
    self.print = deps.print or print
    self.maxBytes = deps.maxBytes or 100000
    return self
end

function logging:setLevel(level)
    assert(THRESHOLD[level], "unknown log level: " .. tostring(level))
    self.level = level
end

function logging:_rotateIfNeeded()
    if not (self.fs and self.path) then return end
    if not self.fs.exists(self.path) then return end
    local ok, size = pcall(self.fs.getSize, self.path)
    if ok and size and size > self.maxBytes then
        local oldPath = self.path .. ".old"
        if self.fs.exists(oldPath) then pcall(self.fs.delete, oldPath) end
        pcall(self.fs.move, self.path, oldPath)
    end
end

function logging:_format(level, msg, fields)
    local parts = { "[" .. tostring(self.clock()) .. "]", "[" .. level:upper() .. "]", msg }
    fields = fields or {}
    for _, key in ipairs(FIELD_ORDER) do
        if fields[key] ~= nil then
            parts[#parts + 1] = key .. "=" .. tostring(fields[key])
        end
    end
    for key, value in pairs(fields) do
        local known = false
        for _, k in ipairs(FIELD_ORDER) do if k == key then known = true break end end
        if not known then
            parts[#parts + 1] = key .. "=" .. tostring(value)
        end
    end
    return table.concat(parts, " ")
end

function logging:_emit(level, msg, fields)
    if RANK[level] > THRESHOLD[self.level] then
        -- Still write important levels (error/warn) to the log file
        -- even when terminal output is suppressed at this level, so
        -- postmortem diagnosis doesn't depend on having been in
        -- verbose/debug mode at the time of the failure.
        if not (self.fs and self.path and RANK[level] <= THRESHOLD.verbose) then
            return
        end
    end

    local line = self:_format(level, msg, fields)

    if RANK[level] <= THRESHOLD[self.level] then
        self.print(line)
    end

    if self.fs and self.path then
        self:_rotateIfNeeded()
        local handle = self.fs.open(self.path, "a")
        if handle then
            handle.writeLine(line)
            handle.close()
        end
    end
end

function logging:error(msg, fields) self:_emit("error", msg, fields) end
function logging:warn(msg, fields) self:_emit("warn", msg, fields) end
function logging:info(msg, fields) self:_emit("info", msg, fields) end
function logging:verbose(msg, fields) self:_emit("verbose", msg, fields) end
function logging:debug(msg, fields) self:_emit("debug", msg, fields) end

return logging
