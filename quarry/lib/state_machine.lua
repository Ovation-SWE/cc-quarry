--- Minimal generic finite-state-machine helper. Keeps worker.lua from
--- accumulating scattered boolean flags: every state transition runs
--- exactly one exit hook (old state) and one enter hook (new state),
--- in that order, and the current state is always a single named
--- value rather than an implicit combination of flags.

local state_machine = {}
state_machine.__index = state_machine

--- spec = {
--   states = { NAME = { enter = function(ctx, fromState, event) end,
--                        exit  = function(ctx, toState, event) end }, ... },
--   initial = "NAME",
--   context = <table passed to every enter/exit hook>,
--   log = <logger, optional>,
-- }
function state_machine.new(spec)
    assert(spec and spec.states and spec.initial, "state_machine.new requires states and initial")
    local self = setmetatable({}, state_machine)
    self.states = spec.states
    self.context = spec.context or {}
    self.log = spec.log
    self.current = nil
    self.history = {}
    self:transition(spec.initial, "init")
    return self
end

function state_machine:getState()
    return self.current
end

function state_machine:is(name)
    return self.current == name
end

function state_machine:transition(newState, event)
    assert(self.states[newState], "unknown state: " .. tostring(newState))
    local old = self.current
    local oldSpec = old and self.states[old]
    if oldSpec and oldSpec.exit then
        oldSpec.exit(self.context, newState, event)
    end

    if self.log then
        self.log:info("state transition", { from = old or "(none)", state = newState, operation = event })
    end
    self.history[#self.history + 1] = { from = old, to = newState, event = event }
    if #self.history > 50 then table.remove(self.history, 1) end

    self.current = newState
    local newSpec = self.states[newState]
    if newSpec.enter then
        newSpec.enter(self.context, old, event)
    end
end

return state_machine
