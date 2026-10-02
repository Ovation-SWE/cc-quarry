-- Minimal fs API mock backed by a real directory on disk, so
-- lib/persistence.lua's atomic-write behavior is exercised against
-- genuine file I/O semantics rather than an in-memory approximation.
-- The caller supplies an existing, empty directory as `root`.

local M = {}

function M.new(root)
    local api = {}

    local function full(path) return root .. "/" .. path end

    api.exists = function(path)
        local f = io.open(full(path), "rb")
        if f then f:close(); return true end
        return false
    end

    api.open = function(path, mode)
        local f, err = io.open(full(path), mode .. "b")
        if not f then return nil, err end
        local handle = {}
        handle.write = function(s) f:write(s) end
        handle.writeLine = function(s) f:write(s, "\n") end
        handle.readAll = function() return f:read("a") end
        handle.readLine = function() return f:read("l") end
        handle.close = function() f:close() end
        return handle
    end

    api.delete = function(path) os.remove(full(path)) end

    api.move = function(from, to) os.rename(full(from), full(to)) end

    api.copy = function(from, to)
        local src = io.open(full(from), "rb")
        if not src then return end
        local data = src:read("a")
        src:close()
        local dst = io.open(full(to), "wb")
        dst:write(data)
        dst:close()
    end

    return api
end

return M
