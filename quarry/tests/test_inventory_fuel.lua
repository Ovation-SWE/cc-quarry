-- Tests for lib/fuel.lua and lib/inventory.lua against the mock world.
-- Run with: lua tests/test_inventory_fuel.lua   (from the quarry/ directory)

package.path = "./lib/?.lua;./tests/mocks/?.lua;" .. package.path
local fuel = require("fuel")
local inventory = require("inventory")
local errors = require("errors")
local World = require("world")
local directions = require("directions")

local failures = 0
local checks = 0
local function check(cond, msg)
    checks = checks + 1
    if not cond then
        failures = failures + 1
        print("FAIL: " .. msg)
    end
end

-- ===== fuel =====

-- 1. hasEnoughFor respects reserve
do
    local w = World.new({ fuel = 100 })
    local f = fuel.new({ turtle = w:turtleAPI(), reserve = 20 })
    check(f:hasEnoughFor(79) == true, "79 blocks + default reserve(20) fits in 100 fuel")
    check(f:hasEnoughFor(81) == false, "81 blocks + reserve(20) does not fit in 100 fuel")
end

-- 2. canAffordRoundTrip requires distance there + back + reserve
do
    local w = World.new({ fuel = 50 })
    local f = fuel.new({ turtle = w:turtleAPI(), reserve = 5 })
    check(f:canAffordRoundTrip(20, 20) == true, "20 there + 20 back + 5 reserve = 45 <= 50")
    check(f:canAffordRoundTrip(23, 23) == false, "23 there + 23 back + 5 reserve = 51 > 50")
end

-- 3. Unlimited fuel always passes checks
do
    local w = World.new({})
    w.fuel = "unlimited"
    local f = fuel.new({ turtle = w:turtleAPI(), reserve = 1000 })
    check(f:isUnlimited() == true, "unlimited fuel detected")
    check(f:hasEnoughFor(999999) == true, "unlimited fuel always sufficient")
end

-- 4. autoRefuel consumes only combustible items, stops once target reached
do
    local w = World.new({ fuel = 0 })
    w:setInventorySlot(1, "minecraft:coal", 5)   -- 80 each = 400 available
    w:setInventorySlot(2, "minecraft:diamond", 5) -- not combustible
    local f = fuel.new({ turtle = w:turtleAPI(), reserve = 0 })
    local ok, err = f:autoRefuel(150)
    check(ok, "autoRefuel reaches target level: " .. tostring(err))
    check(w.fuel >= 150, "fuel level reached target")
    check(w.inventory[2].count == 5, "non-combustible item slot untouched")
end

-- 5. autoRefuel fails cleanly (RESOURCE_EXHAUSTED) when no fuel items are available
do
    local w = World.new({ fuel = 0 })
    w:setInventorySlot(3, "minecraft:diamond", 10)
    local f = fuel.new({ turtle = w:turtleAPI() })
    local ok, err = f:autoRefuel(100)
    check(ok == false, "autoRefuel fails with no combustible items")
    check(errors.kindOf(err) == errors.RESOURCE_EXHAUSTED, "no-fuel-items classified RESOURCE_EXHAUSTED")
end

-- 6. ensure() no-ops when already sufficient (does not waste fuel items)
do
    local w = World.new({ fuel = 500 })
    w:setInventorySlot(1, "minecraft:coal", 5)
    local f = fuel.new({ turtle = w:turtleAPI() })
    local ok = f:ensure(100)
    check(ok, "ensure() succeeds when already above target")
    check(w.inventory[1].count == 5, "ensure() did not consume fuel items when unnecessary")
end

-- 6b. collectFromDepot sucks from a zero-fuel tank (suck costs no fuel)
-- and tops up via autoRefuel, exactly the depot/staging-pad workflow
-- in docs/SETUP.md.
do
    local w = World.new({ fuel = 0, depotStock = { name = "minecraft:coal", count = 10 } }) -- 800 fuel available
    local f = fuel.new({ turtle = w:turtleAPI() })
    local ok, err = f:collectFromDepot(150)
    check(ok, "collectFromDepot reaches target level from an empty tank: " .. tostring(err))
    check(w.fuel >= 150, "fuel level reached target after sucking+refueling")
    check(w.depotStock.count < 10, "depot stock was actually drawn down")
end

-- 6c. collectFromDepot fails cleanly when the depot is empty/absent
do
    local w = World.new({ fuel = 0 }) -- no depotStock at all
    local f = fuel.new({ turtle = w:turtleAPI() })
    local ok, err = f:collectFromDepot(100)
    check(ok == false, "collectFromDepot fails when there's nothing to suck")
    check(errors.kindOf(err) == errors.RESOURCE_EXHAUSTED, "empty depot classified RESOURCE_EXHAUSTED (via autoRefuel)")
end

-- 6d. collectFromDepot is a no-op success on unlimited fuel (never sucks needlessly)
do
    local w = World.new({ depotStock = { name = "minecraft:coal", count = 10 } })
    w.fuel = "unlimited"
    local f = fuel.new({ turtle = w:turtleAPI() })
    local ok = f:collectFromDepot(999999)
    check(ok, "collectFromDepot no-ops successfully on unlimited fuel")
    check(w.depotStock.count == 10, "unlimited fuel never bothers sucking from the depot")
end

-- ===== inventory =====

-- 7. isFull / freeSlotCount respect reserved slots
do
    local w = World.new({})
    for i = 1, 16 do w:setInventorySlot(i, "minecraft:cobblestone", 64) end
    w.inventory[16] = nil -- one free usable slot
    local inv = inventory.new({ turtle = w:turtleAPI(), reservedSlots = { [15] = true } })
    check(inv:isFull() == false, "not full: slot 16 is free")
    check(inv:freeSlotCount() == 1, "exactly one free usable slot (15 is reserved, excluded)")
end

do
    local w = World.new({})
    for i = 1, 16 do w:setInventorySlot(i, "minecraft:cobblestone", 64) end
    local inv = inventory.new({ turtle = w:turtleAPI(), reservedSlots = { [16] = true } })
    check(inv:isFull() == true, "full: every usable slot occupied (slot 16 reserved & ignored)")
end

-- 8. consolidate merges partial stacks
do
    local w = World.new({})
    w:setInventorySlot(1, "minecraft:cobblestone", 10)
    w:setInventorySlot(2, "minecraft:cobblestone", 10)
    w:setInventorySlot(3, "minecraft:dirt", 5)
    local inv = inventory.new({ turtle = w:turtleAPI() })
    inv:consolidate()
    check(w.inventory[1].count == 20, "consolidate merges matching stacks into the earlier slot")
    check(w.inventory[2] == nil, "emptied source slot is cleared")
    check(w.inventory[3].count == 5, "non-matching stack left alone")
end

-- 9. discardJunk drops only configured junk blocks
do
    local w = World.new({ x = 0, y = 0, z = 0, facing = directions.SOUTH })
    w:setInventorySlot(1, "minecraft:cobblestone", 64)
    w:setInventorySlot(2, "minecraft:diamond_ore", 1)
    local inv = inventory.new({ turtle = w:turtleAPI(), discardBlocks = { ["minecraft:cobblestone"] = true } })
    local dropped = inv:discardJunk("forward")
    check(dropped == 1, "exactly one junk stack discarded")
    check(w.inventory[1] == nil, "cobblestone slot emptied")
    check(w.inventory[2].count == 1, "valuable item never discarded")
end

-- 10. unload fails safely when no storage is present (never drops items into the void)
do
    local w = World.new({ x = 0, y = 0, z = 0, facing = directions.SOUTH })
    w:setInventorySlot(1, "minecraft:cobblestone", 64)
    local inv = inventory.new({ turtle = w:turtleAPI() })
    local ok, err = inv:unload("forward")
    check(ok == false, "unload fails when no storage block is present")
    check(errors.kindOf(err) == errors.CONFIGURATION_ERROR, "missing storage classified CONFIGURATION_ERROR")
    check(w.inventory[1].count == 64, "items not lost when storage is missing")
end

-- 11. unload succeeds into a present storage block, draining all usable slots
do
    local w = World.new({ x = 0, y = 0, z = 0, facing = directions.SOUTH })
    w:setBlock(0, 0, 1, "minecraft:chest")
    w:setInventorySlot(1, "minecraft:cobblestone", 64)
    w:setInventorySlot(2, "minecraft:dirt", 32)
    local inv = inventory.new({ turtle = w:turtleAPI(), reservedSlots = { [16] = true } })
    w:setInventorySlot(16, "minecraft:diamond_pickaxe", 1)
    local ok, err = inv:unload("forward")
    check(ok, "unload succeeds when storage is present: " .. tostring(err))
    check(w.inventory[1] == nil and w.inventory[2] == nil, "usable slots drained")
    check(w.inventory[16] ~= nil, "reserved slot (equipment) never unloaded")
end

-- 12. unload reports storage-full without losing already-placed items or crashing
do
    local w = World.new({ x = 0, y = 0, z = 0, facing = directions.SOUTH })
    w:setBlock(0, 0, 1, "minecraft:chest")
    w:setInventorySlot(1, "minecraft:cobblestone", 64)
    w:setInventorySlot(2, "minecraft:dirt", 32)
    local inv = inventory.new({ turtle = w:turtleAPI() })
    -- simulate a chest that rejects drops after the first item (full storage)
    local turtleApi = w:turtleAPI()
    local realDrop = turtleApi.drop
    local dropsAllowed = 1
    turtleApi.drop = function(...)
        if dropsAllowed <= 0 then return false, "No space for items" end
        dropsAllowed = dropsAllowed - 1
        return realDrop(...)
    end
    inv.turtle = turtleApi
    local ok, err = inv:unload("forward")
    check(ok == false, "unload reports failure when storage fills up mid-unload")
    check(errors.kindOf(err) == errors.RESOURCE_EXHAUSTED, "storage-full classified RESOURCE_EXHAUSTED")
    check(w.inventory[1] == nil, "first stack (that succeeded) is not lost")
    check(w.inventory[2] ~= nil, "second stack (that failed) remains in turtle inventory, not lost")
end

print(string.format("\n%d checks, %d failures", checks, failures))
if failures > 0 then os.exit(1) end
