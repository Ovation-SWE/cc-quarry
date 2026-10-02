--- Reliable messaging on top of rednet + lib/protocol.lua.
--
-- Provides what bare rednet does not: application-level
-- acknowledgements, bounded retries with backoff, duplicate-message
-- detection, stale-job rejection, and a single receive path shared
-- between "waiting for a specific ack" and "handling whatever comes
-- in" (an unrelated message received while waiting for an ack is
-- buffered, not dropped, so the caller's normal message loop still
-- sees it).
--
-- Dependency-injected rednet API + sleep function for testability
-- (see tests/mocks/rednet_bus.lua for the in-memory network used by
-- the test suite).

local protocol = require("protocol")
local errors = require("errors")

local comms = {}
comms.__index = comms

local SEEN_WINDOW = 64 -- per-sender duplicate-detection window

--- deps = {
--   rednet = <rednet API>,      -- defaults to global `rednet`
--   selfId = <number>,          -- os.getComputerID()
--   jobId = <string|nil>,       -- nil accepts messages regardless of job
--   sleep = function(seconds),  -- defaults to global sleep
--   log = <logger, optional>,
--   pollInterval = <seconds>,   -- default 0.5
-- }
function comms.new(deps)
    deps = deps or {}
    local self = setmetatable({}, comms)
    self.rednet = deps.rednet or rednet
    self.selfId = deps.selfId
    self.jobId = deps.jobId
    self.sleep = deps.sleep or sleep
    self.log = deps.log
    self.pollInterval = deps.pollInterval or 0.5
    self.sequence = 0
    self.inbox = {}
    self.seen = {} -- [senderId] = { order = {seq,...}, set = {[seq]=true} }
    return self
end

function comms:setJobId(jobId)
    self.jobId = jobId
end

function comms:nextSequence()
    self.sequence = self.sequence + 1
    return self.sequence
end

--- True if (from, msg.sequence) has already been processed. Marks it
--- seen as a side effect. Keeps only the most recent SEEN_WINDOW
--- sequence numbers per sender, which is more than enough headroom
--- for retry storms without growing unbounded over a long job.
function comms:isDuplicate(from, seq)
    local bucket = self.seen[from]
    if not bucket then
        bucket = { order = {}, set = {} }
        self.seen[from] = bucket
    end
    if bucket.set[seq] then
        return true
    end
    bucket.set[seq] = true
    table.insert(bucket.order, seq)
    if #bucket.order > SEEN_WINDOW then
        local oldest = table.remove(bucket.order, 1)
        bucket.set[oldest] = nil
    end
    return false
end

--- Pull one validated, non-duplicate message, waiting up to
--- `timeoutSlice` seconds. Returns from, msg (both nil on timeout /
--- rejection). Invalid envelopes (wrong protocol version, stale/
--- unrelated job) and duplicates are logged and silently discarded
--- here -- callers never see them, so ordinary message-handling code
--- cannot accidentally act on a stale or replayed message.
function comms:pull(timeoutSlice)
    if #self.inbox > 0 then
        local item = table.remove(self.inbox, 1)
        return item.from, item.msg
    end
    local from, msg = self.rednet.receive(protocol.NAME, timeoutSlice)
    if from == nil then return nil end

    local ok, reason = protocol.validate(msg, { jobId = self.jobId })
    if not ok then
        if self.log then
            self.log:warn("rejected message", { from = from, reason = reason, msgType = msg and msg.type })
        end
        return nil
    end

    if self:isDuplicate(from, msg.sequence) then
        if self.log then
            self.log:verbose("dropped duplicate message", { from = from, sequence = msg.sequence })
        end
        return nil
    end

    return from, msg
end

--- Wait up to `totalTimeout` seconds for a message satisfying
--- matchFn(from, msg). Non-matching messages are preserved in the
--- inbox for the next ordinary pull() rather than discarded.
function comms:waitFor(matchFn, totalTimeout)
    local maxPolls = math.max(1, math.ceil(totalTimeout / self.pollInterval))
    -- Rejected messages are stashed locally during the scan, NOT
    -- pushed into self.inbox mid-loop: pull() checks self.inbox
    -- before calling receive(), so an early push would just make the
    -- next poll immediately re-read the same rejected message instead
    -- of advancing to the next one waiting in the real queue.
    local stash = {}
    local result
    for _ = 1, maxPolls do
        local from, msg = self:pull(self.pollInterval)
        if msg then
            if matchFn(from, msg) then
                result = { from = from, msg = msg }
                break
            end
            stash[#stash + 1] = { from = from, msg = msg }
        end
    end
    for i = #stash, 1, -1 do
        table.insert(self.inbox, 1, stash[i])
    end
    if result then return result.from, result.msg end
    return nil
end

function comms:sendAck(recipient, originalMsg)
    local ack = protocol.build({
        type = protocol.TYPES.ACK,
        jobId = originalMsg.jobId,
        workerId = self.selfId,
        sequence = self:nextSequence(),
        ackFor = originalMsg.sequence,
    })
    self.rednet.send(recipient, ack, protocol.NAME)
end

--- Send `msgType` to `recipient` and retry with backoff until an
--- application-level ACK referencing this message's sequence number
--- is received, or maxRetries is exhausted. This is the only way
--- this codebase should send anything that must provably arrive --
--- raw rednet.send() success is not treated as delivery confirmation.
function comms:sendReliable(recipient, msgType, payload, opts)
    opts = opts or {}
    local maxRetries = opts.maxRetries or 5
    local ackTimeout = opts.ackTimeout or 2
    local backoff = opts.initialBackoff or 0.5
    local maxBackoff = opts.maxBackoff or 8

    local seq = self:nextSequence()
    local msg = protocol.build({
        type = msgType, jobId = self.jobId, workerId = self.selfId, sequence = seq, payload = payload,
    })

    for attempt = 1, maxRetries do
        self.rednet.send(recipient, msg, protocol.NAME)
        local _, reply = self:waitFor(function(from, m)
            return from == recipient and m.type == protocol.TYPES.ACK and m.ackFor == seq
        end, ackTimeout)
        if reply then
            return true
        end
        if self.log then
            self.log:warn("no ack, retrying", { attempt = attempt, recipient = recipient, msgType = msgType })
        end
        if attempt < maxRetries and self.sleep then
            self.sleep(backoff)
            backoff = math.min(backoff * 2, maxBackoff)
        end
    end
    return false, errors.make(errors.TRANSIENT, "ack_timeout_after_" .. maxRetries .. "_retries")
end

--- Fire-and-forget broadcast (no ack expected; used for things like
--- worker discovery pings where any number of replies is valid).
--- Returns the sequence number used, so a caller that wants to match
--- a specific reply (e.g. registration) can do so precisely.
function comms:broadcast(msgType, payload)
    local seq = self:nextSequence()
    local msg = protocol.build({
        type = msgType, jobId = self.jobId, workerId = self.selfId, sequence = seq, payload = payload,
    })
    self.rednet.broadcast(msg, protocol.NAME)
    return seq
end

--- Fire-and-forget unicast (no ack expected/awaited). Used for
--- high-frequency, self-superseding messages like heartbeats, where
--- a single lost message is harmless because the next one follows
--- shortly -- retrying with sendReliable would only add latency and
--- risk stalling the caller's main loop over a missed reply.
function comms:sendFireAndForget(recipient, msgType, payload)
    local seq = self:nextSequence()
    local msg = protocol.build({
        type = msgType, jobId = self.jobId, workerId = self.selfId, sequence = seq, payload = payload,
    })
    self.rednet.send(recipient, msg, protocol.NAME)
    return seq
end

return comms
