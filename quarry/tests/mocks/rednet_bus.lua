-- Deterministic in-memory rednet substitute for testing lib/comms.lua
-- without a real wireless modem. Each node's `receive` never actually
-- blocks (it returns nil immediately if its queue is empty,
-- regardless of the requested timeout) which keeps tests fast; this
-- is safe because lib/comms.lua's retry/backoff loop is driven by a
-- *poll count* (ceil(timeout / pollInterval)), not wall-clock time,
-- so a non-blocking mock still exercises the same code paths.

local Bus = {}
Bus.__index = Bus

function Bus.new()
    return setmetatable({ queues = {}, dropAll = false, dropTo = {} }, Bus)
end

function Bus:_ensureQueue(id)
    self.queues[id] = self.queues[id] or {}
    return self.queues[id]
end

--- Simulate total network loss to a specific recipient (messages sent
--- to it vanish, as if out of wireless range).
function Bus:setDropTo(id, drop)
    self.dropTo[id] = drop
end

function Bus:node(id)
    local bus = self
    self:_ensureQueue(id)
    local n = {}

    n.send = function(recipient, message, protocolName)
        if bus.dropAll or bus.dropTo[recipient] then
            return true -- rednet.send() "success" never guarantees receipt
        end
        local q = bus:_ensureQueue(recipient)
        table.insert(q, { from = id, message = message, protocol = protocolName })
        return true
    end

    n.broadcast = function(message, protocolName)
        for rid, _ in pairs(bus.queues) do
            if rid ~= id and not bus.dropTo[rid] and not bus.dropAll then
                table.insert(bus:_ensureQueue(rid), { from = id, message = message, protocol = protocolName })
            end
        end
    end

    n.receive = function(protocolFilter, _timeout)
        local q = bus:_ensureQueue(id)
        for i, item in ipairs(q) do
            if not protocolFilter or item.protocol == protocolFilter then
                table.remove(q, i)
                return item.from, item.message, item.protocol
            end
        end
        return nil
    end

    -- inject a raw message directly into a node's queue, bypassing
    -- send(), to simulate duplicate/delayed/out-of-order delivery.
    n.injectRaw = function(from, message, protocolName)
        table.insert(bus:_ensureQueue(id), { from = from, message = message, protocol = protocolName or "quarry.v1" })
    end

    n.queueLength = function() return #bus:_ensureQueue(id) end

    n.open = function() end
    n.close = function() end
    n.isOpen = function() return true end

    return n
end

return Bus
