--- Pure message-envelope construction and validation for the
--- "quarry.v1" application protocol carried over rednet.
--
-- rednet.send() only reports whether transmission was attempted, not
-- whether the recipient actually received or processed the message
-- (see tweaked.cc/module/rednet.html). Every message that requires
-- guaranteed delivery is therefore acknowledged at the application
-- level by lib/comms.lua, which builds on top of this module.

local protocol = {}

protocol.VERSION = 1
protocol.NAME = "quarry.v1"

protocol.TYPES = {
    REGISTER = "register",
    JOB_ASSIGN = "job_assign",
    START = "start",
    HEARTBEAT = "heartbeat",
    STATUS = "status",
    COMPLETE = "complete",
    PAUSE = "pause",
    RESUME = "resume",
    CANCEL = "cancel",
    ESTOP = "estop",
    ACK = "ack",
}

--- Build a message envelope. `fields` must include type, jobId,
--- workerId, sequence; `payload` and `ackFor` (for ACK messages) are
--- optional.
function protocol.build(fields)
    assert(fields.type, "message requires a type")
    assert(fields.sequence, "message requires a sequence number")
    return {
        type = fields.type,
        protocolVersion = protocol.VERSION,
        jobId = fields.jobId,
        workerId = fields.workerId,
        sequence = fields.sequence,
        ackFor = fields.ackFor,
        payload = fields.payload,
    }
end

--- Validate an incoming envelope against `expected = { jobId = ... }`.
--- expected.jobId may be nil to accept messages regardless of job
--- (used before a job exists, e.g. worker registration).
--- Returns true, or false + a short reason string.
function protocol.validate(msg, expected)
    expected = expected or {}
    if type(msg) ~= "table" then return false, "not_a_table" end
    if type(msg.type) ~= "string" then return false, "missing_type" end
    if msg.protocolVersion ~= protocol.VERSION then
        return false, "protocol_version_mismatch"
    end
    if type(msg.sequence) ~= "number" then return false, "missing_sequence" end
    if expected.jobId ~= nil and msg.jobId ~= expected.jobId then
        return false, "stale_or_unrelated_job"
    end
    if expected.workerId ~= nil and msg.workerId ~= expected.workerId then
        return false, "worker_id_mismatch"
    end
    return true
end

return protocol
