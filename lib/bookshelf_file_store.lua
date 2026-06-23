-- bookshelf_file_store.lua
--
-- Factory for a small key/value store backed by its OWN settings file under
-- <datadir>/settings/, separate from the main bookshelf.lua. Used for large
-- values that shouldn't ride along in bookshelf.lua and get rewritten on every
-- preference save (LuaSettings:flush serialises the whole table): the
-- micro-module data file and the Hardcover link cache.
--
--   local store = require("lib/bookshelf_file_store").new("bookshelf_x.lua")
--   store.read(key, default) / store.save(key, v) / store.delete(key)
--   store.saveDeferred(key, v)  -- in-memory only; pair with store.flush()
--
-- The file is opened lazily on first access, so requiring this costs nothing
-- until a key is actually touched.

local M = {}

function M.new(filename)
    local DataStorage = require("datastorage")
    local LuaSettings = require("luasettings")
    local path = DataStorage:getSettingsDir() .. "/" .. filename

    local settings
    local function open()
        settings = settings or LuaSettings:open(path)
        return settings
    end

    local store = {}

    function store.read(key, default)
        local v = open():readSetting(key)
        if v == nil then return default end
        return v
    end

    function store.save(key, value)
        local s = open()
        s:saveSetting(key, value)
        s:flush()
    end

    -- In-memory write only (no flush); the caller flushes once at the end.
    function store.saveDeferred(key, value)
        open():saveSetting(key, value)
    end

    function store.delete(key)
        local s = open()
        s:delSetting(key)
        s:flush()
    end

    function store.flush()
        if settings then settings:flush() end
    end

    function store.path() return path end

    return store
end

return M
