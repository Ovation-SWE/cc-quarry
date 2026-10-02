--- Shared failure classification used across all worker subsystems.
-- Every fallible operation in this codebase returns either:
--   true, ...                      on success
--   false, "<KIND>:<detail>"       on failure
-- so callers can make retry/stop decisions based on `kind` alone,
-- without string-matching engine-specific error text.

local errors = {}

errors.TRANSIENT = "TRANSIENT"                 -- worth an immediate bounded retry
errors.RECOVERABLE = "RECOVERABLE"             -- needs a state change to fix (e.g. refuel), then retry
errors.BLOCKED = "BLOCKED"                     -- an obstacle that retrying won't clear
errors.RESOURCE_EXHAUSTED = "RESOURCE_EXHAUSTED" -- fuel/inventory/storage exhausted
errors.CONFIGURATION_ERROR = "CONFIGURATION_ERROR" -- bad job/config, cannot proceed
errors.FATAL = "FATAL"                         -- unrecoverable; stop and report

function errors.make(kind, detail)
    return kind .. ":" .. tostring(detail)
end

function errors.kindOf(err)
    if type(err) ~= "string" then return nil end
    return err:match("^([%u_]+):")
end

function errors.detailOf(err)
    if type(err) ~= "string" then return err end
    local detail = err:match("^[%u_]+:(.*)$")
    return detail or err
end

return errors
