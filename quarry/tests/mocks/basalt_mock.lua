-- Minimal stand-in for the Basalt2 GUI library, covering exactly the
-- surface master/gui.lua uses (addLabel/addInput/addButton/
-- addCheckbox/addTabControl/addTab/addFrame/addTextBox/addTable,
-- plus the on<Event>(fn) callback-registration convention). There is
-- no real rendering: every widget is a plain table whose properties
-- (text, checked, background, visible, ...) are just fields, and
-- on<Event>(fn) stores the callback for a test to invoke directly.
--
-- This cannot verify Basalt's *real* API (see docs/TROUBLESHOOTING.md
-- and the research notes in master/gui.lua's header for the real
-- API's gotchas) -- it only verifies that gui.lua's own logic (config
-- parsing, deploy/start/pause/etc. against lib/*.lua) is correct,
-- using the same kind of fake widget tree a real Basalt frame would
-- hand back.

local M = {}

local Widget = {}
Widget.__index = function(t, key)
    local handler = rawget(Widget, key)
    if handler then return handler end
    local eventName = key:match("^on(%u.*)$")
    if eventName then
        eventName = eventName:sub(1, 1):lower() .. eventName:sub(2)
        return function(self, fn)
            self._handlers[eventName] = fn
            return self
        end
    end
    return nil
end

local function newWidget(kind, props)
    local w = setmetatable({ _kind = kind, _handlers = {}, _children = {} }, Widget)
    for k, v in pairs(props or {}) do w[k] = v end
    return w
end

local ADD_METHODS = {
    "Label", "Input", "Button", "Checkbox", "Dropdown", "Switch",
    "Frame", "TextBox", "ProgressBar", "List",
}
for _, name in ipairs(ADD_METHODS) do
    Widget["add" .. name] = function(self, props)
        local child = newWidget(name, props)
        table.insert(self._children, child)
        return child
    end
end

function Widget:addTable(props)
    local child = newWidget("Table", props)
    child._data = {}
    function child:setData(rows) self._data = rows end
    function child:getData() return self._data end
    table.insert(self._children, child)
    return child
end

function Widget:addTabControl(props)
    local child = newWidget("TabControl", props)
    child._tabs = {}
    child.addTab = function(_self, title)
        local tab = newWidget("Tab", { title = title })
        table.insert(child._tabs, tab)
        return tab
    end
    table.insert(self._children, child)
    return child
end

function Widget:getSize()
    return self.width or 51, self.height or 19
end

function M.new(opts)
    opts = opts or {}
    local mainFrame = newWidget("Frame", { width = opts.width or 51, height = opts.height or 19 })
    local basalt = {}
    function basalt.getMainFrame() return mainFrame end
    function basalt.run() end
    function basalt.stop() end
    function basalt.update() end
    return basalt
end

return M
