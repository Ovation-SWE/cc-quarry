-- Tests for lib/protocol.lua and lib/comms.lua: acks, retries,
-- duplicate/stale/delayed/lost message handling.
-- Run with: lua tests/test_protocol.lua   (from the quarry/ directory)

package.path = "./lib/?.lua;./tests/mocks/?.lua;" .. package.path
local protocol = require("protocol")
local comms = require("comms")
local errors = require("errors")
local Bus = require("rednet_bus")

local failures = 0
local checks = 0
local function check(cond, msg)
    checks = checks + 1
    if not cond then
        failures = failures + 1
        print("FAIL: " .. msg)
    end
end

local function noSleep() end

-- 1. protocol.validate: version, job, worker checks
do
    local msg = { type = "job_assign", protocolVersion = 1, jobId = "job-1", workerId = 3, sequence = 1 }
    check(select(1, protocol.validate(msg, { jobId = "job-1" })) == true, "valid message accepted")
    check(select(1, protocol.validate(msg, { jobId = "job-2" })) == false, "wrong jobId rejected")
    local _, reason = protocol.validate(msg, { jobId = "job-2" })
    check(reason == "stale_or_unrelated_job", "wrong jobId reason is stale_or_unrelated_job")

    local badVersion = { type = "job_assign", protocolVersion = 99, jobId = "job-1", sequence = 1 }
    check(select(1, protocol.validate(badVersion, { jobId = "job-1" })) == false, "wrong protocol version rejected")
end

-- 2. Basic reliable send/ack roundtrip, driven by a scripted rednet
--    stub standing in for "the worker acked it". comms:sendReliable()
--    runs synchronously to completion (no coroutine yields inside),
--    so a two-sided Bus simulation can't interleave send/ack mid-call
--    without the sender's own retry loop already having moved on;
--    scripting the stub's receive() directly is the faithful way to
--    unit-test the retry/ack-matching logic in isolation.
do
    local lastSent = nil
    local rednetStub = {
        send = function(_recipient, msg, _proto) lastSent = msg; return true end,
        receive = function(_protoFilter, _timeout)
            if not lastSent then return nil end
            local ack = protocol.build({
                type = protocol.TYPES.ACK, jobId = lastSent.jobId, workerId = 2,
                sequence = 99999, ackFor = lastSent.sequence,
            })
            lastSent = nil
            return 2, ack, protocol.NAME
        end,
    }
    local master = comms.new({ rednet = rednetStub, selfId = 1, jobId = "job-1", sleep = noSleep })
    local ok = master:sendReliable(2, protocol.TYPES.JOB_ASSIGN, { hello = "world" }, { maxRetries = 3, ackTimeout = 1 })
    check(ok == true, "sendReliable succeeds once a matching ack is available")
end

-- 3. Retry until success: ack only becomes available after a couple of retries
do
    local lastSeq = nil
    local receiveCalls = 0
    local rednetStub = {
        send = function(_recipient, msg, _proto) lastSeq = msg.sequence; return true end,
        receive = function(_protoFilter, _timeout)
            receiveCalls = receiveCalls + 1
            if receiveCalls >= 3 and lastSeq then
                local ack = protocol.build({
                    type = protocol.TYPES.ACK, jobId = "job-1", workerId = 2, sequence = 1, ackFor = lastSeq,
                })
                return 2, ack, protocol.NAME
            end
            return nil
        end,
    }
    local master = comms.new({ rednet = rednetStub, selfId = 1, jobId = "job-1", sleep = noSleep })
    local ok = master:sendReliable(2, protocol.TYPES.HEARTBEAT, {}, { maxRetries = 5, ackTimeout = 0.2, initialBackoff = 0 })
    check(ok == true, "sendReliable eventually succeeds after retries")
    check(receiveCalls >= 3, "took multiple polls before the ack was available (" .. receiveCalls .. ")")
end

-- 4. Permanently unreachable recipient: fails with TRANSIENT after exhausting retries
do
    local bus = Bus.new()
    bus:setDropTo(2, true)
    local master = comms.new({ rednet = bus:node(1), selfId = 1, jobId = "job-1", sleep = noSleep })
    local ok, err = master:sendReliable(2, protocol.TYPES.CANCEL, {}, { maxRetries = 3, ackTimeout = 0.1, initialBackoff = 0 })
    check(ok == false, "sendReliable fails when recipient is unreachable")
    check(errors.kindOf(err) == errors.TRANSIENT, "unreachable-recipient failure classified TRANSIENT")
end

-- 5. Duplicate message detection: a re-delivered message is dropped, not double-processed
do
    local bus = Bus.new()
    local worker = comms.new({ rednet = bus:node(2), selfId = 2, jobId = "job-1", sleep = noSleep })
    local msg = protocol.build({ type = protocol.TYPES.PAUSE, jobId = "job-1", workerId = 2, sequence = 42 })
    bus:node(2).injectRaw(1, msg)
    bus:node(2).injectRaw(1, msg) -- exact re-delivery (e.g. sender's retry after a lost ack)

    local _, firstMsg = worker:pull(0.1)
    check(firstMsg ~= nil, "first delivery of the message is received")
    local _, secondMsg = worker:pull(0.1)
    check(secondMsg == nil, "duplicate delivery (same sender+sequence) is silently dropped")
end

-- 6. Stale job rejection: a message for a different/old job is dropped, not acted on
do
    local bus = Bus.new()
    local worker = comms.new({ rednet = bus:node(2), selfId = 2, jobId = "job-current", sleep = noSleep })
    local staleMsg = protocol.build({ type = protocol.TYPES.JOB_ASSIGN, jobId = "job-old", workerId = 2, sequence = 1 })
    bus:node(2).injectRaw(1, staleMsg)
    local _, msg = worker:pull(0.1)
    check(msg == nil, "message for a stale/different jobId is rejected")
end

-- 7. Unrelated message received while waiting for an ack is buffered, not lost
do
    local bus = Bus.new()
    local master = comms.new({ rednet = bus:node(1), selfId = 1, jobId = "job-1", sleep = noSleep })

    -- Queue an unrelated STATUS message from worker 5, then an ACK from worker 2.
    local statusMsg = protocol.build({ type = protocol.TYPES.STATUS, jobId = "job-1", workerId = 5, sequence = 1, payload = { state = "MINING" } })
    bus:node(1).injectRaw(5, statusMsg)
    local ackMsg = protocol.build({ type = protocol.TYPES.ACK, jobId = "job-1", workerId = 2, sequence = 7, ackFor = 1 })
    bus:node(1).injectRaw(2, ackMsg)

    local _, reply = master:waitFor(function(f, m) return f == 2 and m.type == protocol.TYPES.ACK and m.ackFor == 1 end, 1)
    check(reply ~= nil, "matching ack found even though an unrelated message arrived first")

    -- The unrelated status message must still be retrievable afterward.
    local _, pulledMsg = master:pull(0.1)
    check(pulledMsg ~= nil and pulledMsg.type == protocol.TYPES.STATUS, "unrelated message preserved in inbox, not dropped")
end

print(string.format("\n%d checks, %d failures", checks, failures))
if failures > 0 then os.exit(1) end
