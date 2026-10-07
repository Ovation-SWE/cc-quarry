-- Deterministic in-memory world + turtle simulator used by the test
-- suite in place of a real Minecraft/CC:Tweaked instance. Implements
-- just enough of the documented turtle.* behavior (movement, digging,
-- placing, fuel, inventory, gravity for falling blocks, liquids) to
-- exercise lib/navigation.lua, lib/mining.lua, lib/fuel.lua and
-- lib/inventory.lua realistically.

local DIRVEC = {
    [0] = { x = 0, z = -1 }, -- north
    [1] = { x = 1, z = 0 },  -- east
    [2] = { x = 0, z = 1 },  -- south
    [3] = { x = -1, z = 0 }, -- west
}

local LIQUIDS = { ["minecraft:water"] = true, ["minecraft:lava"] = true }
local FALLING = { ["minecraft:sand"] = true, ["minecraft:gravel"] = true, ["minecraft:red_sand"] = true }
local FUEL_VALUES = { ["minecraft:coal"] = 80, ["minecraft:charcoal"] = 80, ["minecraft:lava_bucket"] = 1000 }

local World = {}
World.__index = World

function World.new(opts)
    opts = opts or {}
    local self = setmetatable({}, World)
    self.blocks = {}
    self.pos = { x = opts.x or 0, y = opts.y or 0, z = opts.z or 0 }
    self.facing = opts.facing or 0
    self.fuel = opts.fuel or 1000
    self.fuelLimit = opts.fuelLimit or 20000
    self.inventory = {}
    self.selected = 1
    self.digLog = {}
    self.depotStock = opts.depotStock -- { name = "minecraft:coal", count = N } | nil
    return self
end

local function key(x, y, z) return x .. "," .. y .. "," .. z end

function World:setBlock(x, y, z, name, opts)
    if name == nil then
        self.blocks[key(x, y, z)] = nil
    else
        self.blocks[key(x, y, z)] = { name = name, protected = opts and opts.protected }
    end
end

function World:fillBox(x0, x1, y0, y1, z0, z1, name)
    for x = x0, x1 do
        for y = y0, y1 do
            for z = z0, z1 do
                self:setBlock(x, y, z, name)
            end
        end
    end
end

function World:getBlock(x, y, z)
    return self.blocks[key(x, y, z)]
end

function World:setInventorySlot(slot, name, count)
    self.inventory[slot] = { name = name, count = count }
end

local function targetFor(self, kind)
    if kind == "up" then
        return self.pos.x, self.pos.y + 1, self.pos.z
    elseif kind == "down" then
        return self.pos.x, self.pos.y - 1, self.pos.z
    else
        local v = DIRVEC[self.facing]
        return self.pos.x + v.x, self.pos.y, self.pos.z + v.z
    end
end

--- Remove the block at (x,y,z) and cascade exactly one falling block
--- down into it if the block above is a falling type. Mirrors real
--- Minecraft closely enough for testing repeated-dig cascade logic:
--- each dig() call drains exactly one "unit" of a gravel/sand stack.
local function removeAndCascade(self, x, y, z)
    self:setBlock(x, y, z, nil)
    local above = self:getBlock(x, y + 1, z)
    if above and FALLING[above.name] then
        self:setBlock(x, y, z, above.name)
        self:setBlock(x, y + 1, z, nil)
    end
end

--- Real turtle.dig() auto-collects the block's drop into inventory
--- (first matching partial stack, else first empty slot; if neither
--- exists the item is lost, same as a full-inventory drop in vanilla).
local function collectItem(self, name)
    for slot = 1, 16 do
        local item = self.inventory[slot]
        if item and item.name == name and item.count < 64 then
            item.count = item.count + 1
            return
        end
    end
    for slot = 1, 16 do
        if not self.inventory[slot] then
            self.inventory[slot] = { name = name, count = 1 }
            return
        end
    end
    -- inventory full: item lost, matching vanilla drop-on-full-inventory
end

--- Real turtle.suck() pulls from the inventory/container the turtle
--- is facing (or the ground). This mock models only the container
--- case, via the depot-stock fixture World.new({depotStock=...})
--- passed at construction -- there is no real adjacent-chest/block
--- model here, just a fixed pile of items the turtle can draw from
--- until it's exhausted. Returns false once depotStock is nil/empty,
--- matching real turtle.suck()'s "nothing there" behavior.
local function doSuck(self, count)
    local stock = self.depotStock
    if not stock or stock.count <= 0 then
        return false, "No items to take"
    end
    count = math.min(count or 64, stock.count)
    for _ = 1, count do collectItem(self, stock.name) end
    stock.count = stock.count - count
    return true
end

local function doDig(self, kind)
    local x, y, z = targetFor(self, kind)
    local block = self:getBlock(x, y, z)
    self.digLog[#self.digLog + 1] = { x = x, y = y, z = z }
    if not block then
        return false, "Nothing to dig here"
    end
    if LIQUIDS[block.name] then
        return false, "Nothing to dig here"
    end
    if block.protected then
        return false, "Cannot break unbreakable block"
    end
    local minedName = block.name
    removeAndCascade(self, x, y, z)
    collectItem(self, minedName)
    return true
end

local function doDetect(self, kind)
    local x, y, z = targetFor(self, kind)
    local block = self:getBlock(x, y, z)
    if not block then return false end
    if LIQUIDS[block.name] then return false end
    return true
end

local function doInspect(self, kind)
    local x, y, z = targetFor(self, kind)
    local block = self:getBlock(x, y, z)
    if not block then return false, "No block to inspect" end
    return true, { name = block.name }
end

local function doMove(self, kind)
    if self.fuel <= 0 then
        return false, "Out of fuel"
    end
    local x, y, z = targetFor(self, kind)
    local block = self:getBlock(x, y, z)
    if block and not LIQUIDS[block.name] then
        return false, "Movement obstructed"
    end
    self.pos.x, self.pos.y, self.pos.z = x, y, z
    self.fuel = self.fuel - 1
    return true
end

local function doPlace(self, kind)
    local item = self.inventory[self.selected]
    if not item or item.count <= 0 then
        return false, "No items to place"
    end
    local x, y, z = targetFor(self, kind)
    local block = self:getBlock(x, y, z)
    if block and not LIQUIDS[block.name] then
        return false, "Cannot place block here"
    end
    self:setBlock(x, y, z, item.name)
    item.count = item.count - 1
    if item.count <= 0 then self.inventory[self.selected] = nil end
    return true
end

--- Returns a table implementing the subset of the `turtle` API this
--- project depends on, backed by this World instance.
function World:turtleAPI()
    local api = {}

    api.forward = function() return doMove(self, "forward") end
    api.back = function()
        if self.fuel <= 0 then return false, "Out of fuel" end
        local v = DIRVEC[self.facing]
        local x, y, z = self.pos.x - v.x, self.pos.y, self.pos.z - v.z
        local block = self:getBlock(x, y, z)
        if block and not LIQUIDS[block.name] then return false, "Movement obstructed" end
        self.pos.x, self.pos.z = x, z
        self.fuel = self.fuel - 1
        return true
    end
    api.up = function() return doMove(self, "up") end
    api.down = function() return doMove(self, "down") end

    api.turnLeft = function() self.facing = (self.facing - 1) % 4; return true end
    api.turnRight = function() self.facing = (self.facing + 1) % 4; return true end

    api.dig = function() return doDig(self, "forward") end
    api.digUp = function() return doDig(self, "up") end
    api.digDown = function() return doDig(self, "down") end

    api.detect = function() return doDetect(self, "forward") end
    api.detectUp = function() return doDetect(self, "up") end
    api.detectDown = function() return doDetect(self, "down") end

    api.inspect = function() return doInspect(self, "forward") end
    api.inspectUp = function() return doInspect(self, "up") end
    api.inspectDown = function() return doInspect(self, "down") end

    api.place = function() return doPlace(self, "forward") end
    api.placeUp = function() return doPlace(self, "up") end
    api.placeDown = function() return doPlace(self, "down") end

    api.select = function(slot) self.selected = slot; return true end
    api.getSelectedSlot = function() return self.selected end
    api.getItemCount = function(slot)
        local item = self.inventory[slot or self.selected]
        return item and item.count or 0
    end
    api.getItemSpace = function(slot)
        local item = self.inventory[slot or self.selected]
        if not item then return 64 end
        return 64 - item.count
    end
    api.getItemDetail = function(slot)
        local item = self.inventory[slot or self.selected]
        if not item then return nil end
        return { name = item.name, count = item.count }
    end
    api.transferTo = function(slot, count)
        local from = self.inventory[self.selected]
        if not from then return false end
        count = count or from.count
        local to = self.inventory[slot]
        if to and to.name ~= from.name then return false end
        if not to then
            self.inventory[slot] = { name = from.name, count = 0 }
            to = self.inventory[slot]
        end
        local moved = math.min(count, from.count, 64 - to.count)
        to.count = to.count + moved
        from.count = from.count - moved
        if from.count <= 0 then self.inventory[self.selected] = nil end
        return true
    end

    api.drop = function(count)
        local item = self.inventory[self.selected]
        if not item then return false, "No items to drop" end
        count = count or item.count
        item.count = item.count - math.min(count, item.count)
        if item.count <= 0 then self.inventory[self.selected] = nil end
        return true
    end
    api.dropUp = api.drop
    api.dropDown = api.drop

    api.suck = function(count) return doSuck(self, count) end
    api.suckUp = api.suck
    api.suckDown = api.suck

    api.getFuelLevel = function() return self.fuel end
    api.getFuelLimit = function() return self.fuelLimit end
    api.refuel = function(count)
        local item = self.inventory[self.selected]
        if not item then return false, "No items to combust" end
        local perItem = FUEL_VALUES[item.name]
        if not perItem then return false, "Items not combustible" end
        count = count or item.count
        count = math.min(count, item.count)
        self.fuel = math.min(self.fuelLimit, self.fuel + perItem * count)
        item.count = item.count - count
        if item.count <= 0 then self.inventory[self.selected] = nil end
        return true
    end

    return api
end

return World
