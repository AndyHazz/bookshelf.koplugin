-- lib/bookshelf_opds_source.lua
-- Read-only bridge to the stock opds.koplugin catalogue list, so OPDS chips
-- reuse the servers (and credentials) the user already configured there -
-- one source of truth, no duplicate management UI (kobo_source risk profile:
-- plugin-owned file, so validate everything and degrade to "no servers").
--
-- The file is a LuaSettings chunk (`return { servers = {...} }`). It is read
-- with a pcall'd loadfile, never LuaSettings:open - LuaSettings could be
-- induced to WRITE, and this bridge must stay read-only.

local M = {}

function M._settingsPath()
    local ok, DataStorage = pcall(require, "datastorage")
    if not ok or not DataStorage then return nil end
    return DataStorage:getSettingsDir() .. "/opds.lua"
end

-- djb2, hex-encoded, 8 chars: stable chip-source id for a server URL.
-- Bit-free implementation (Lua 5.1 has no integer ops): keep the value in
-- [0, 2^32) with modulo after each step.
function M.serverKey(url)
    local h = 5381
    for i = 1, #url do
        h = (h * 33 + url:byte(i)) % 4294967296
    end
    return string.format("%08x", h)
end

function M.servers()
    local path = M._settingsPath()
    if not path then return {} end
    local chunk = loadfile(path)
    if not chunk then return {} end
    local ok, data = pcall(chunk)
    if not ok or type(data) ~= "table" or type(data.servers) ~= "table" then
        return {}
    end
    local out = {}
    for _i, s in ipairs(data.servers) do
        if type(s) == "table"
                and type(s.title) == "string" and s.title ~= ""
                and type(s.url) == "string" and s.url ~= "" then
            out[#out + 1] = {
                key      = M.serverKey(s.url),
                title    = s.title,
                url      = s.url,
                username = type(s.username) == "string" and s.username or nil,
                password = type(s.password) == "string" and s.password or nil,
            }
        end
    end
    return out
end

function M.getServer(key)
    for _i, s in ipairs(M.servers()) do
        if s.key == key then return s end
    end
    return nil
end

function M.isAvailable()
    return #M.servers() > 0
end

return M
