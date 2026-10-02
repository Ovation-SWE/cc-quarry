-- Tests for lib/state_machine.lua
-- Run with: lua tests/test_state_machine.lua   (from the quarry/ directory)

package.path = "./lib/?.lua;" .. package.path
local state_machine = require("state_machine")

local failures = 0
local checks = 0
local function check(cond, msg)
    checks = checks + 1
    if not cond then
        failures = failures + 1
        print("FAIL: " .. msg)
    end
end

-- 1. Enter hook fires for the initial state
do
    local entered = {}
    local sm = state_machine.new({
        initial = "BOOT",
        states = {
            BOOT = { enter = function() entered[#entered + 1] = "BOOT" end },
            MINING = {},
        },
    })
    check(sm:getState() == "BOOT", "initial state is BOOT")
    check(#entered == 1 and entered[1] == "BOOT", "enter hook fires once for initial state")
end

-- 2. Transition runs exit(old) then enter(new), in that order
do
    local order = {}
    local sm = state_machine.new({
        initial = "A",
        states = {
            A = { exit = function() order[#order + 1] = "exit A" end },
            B = { enter = function() order[#order + 1] = "enter B" end },
        },
    })
    sm:transition("B", "go")
    check(sm:getState() == "B", "state updated to B")
    check(#order == 2 and order[1] == "exit A" and order[2] == "enter B",
        "exit(old) runs before enter(new)")
end

-- 3. Hooks receive shared context, from/to state, and event
do
    local ctx = { counter = 0 }
    local seenEnter, seenExit
    local sm = state_machine.new({
        initial = "IDLE",
        context = ctx,
        states = {
            IDLE = { exit = function(c, to, event) seenExit = { to = to, event = event }; c.counter = c.counter + 1 end },
            RUN = { enter = function(c, from, event) seenEnter = { from = from, event = event }; c.counter = c.counter + 10 end },
        },
    })
    sm:transition("RUN", "start_job")
    check(seenExit.to == "RUN" and seenExit.event == "start_job", "exit hook sees destination state and event")
    check(seenEnter.from == "IDLE" and seenEnter.event == "start_job", "enter hook sees origin state and event")
    check(ctx.counter == 11, "hooks mutate shared context as expected")
end

-- 4. Transitioning to an unknown state fails loudly rather than
--    silently entering an undefined/inconsistent state.
do
    local sm = state_machine.new({ initial = "A", states = { A = {} } })
    local ok = pcall(function() sm:transition("NONEXISTENT", "oops") end)
    check(ok == false, "transitioning to an undeclared state raises an error")
    check(sm:getState() == "A", "current state unchanged after a rejected transition")
end

-- 5. States without hooks are safe no-ops (not every state needs both)
do
    local sm = state_machine.new({
        initial = "A",
        states = { A = {}, B = {} },
    })
    local ok = pcall(function() sm:transition("B", "e") end)
    check(ok, "transition succeeds even when neither state defines hooks")
end

print(string.format("\n%d checks, %d failures", checks, failures))
if failures > 0 then os.exit(1) end
