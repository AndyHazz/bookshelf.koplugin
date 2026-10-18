-- bookshelf_module_cache.lua
--
-- Small disposable state the micro-module surfaces keep across restarts: each
-- card's fitted size, the Shelf size tally, the Reading goal figures. Losing
-- any of it costs one re-fit or one recount, nothing more.
--
-- It lives in its own file in the cache directory, NOT in the main settings
-- file, and writes are coalesced. Store.save rewrites the whole settings file
-- on every call; with these keys there, a full-screen micro-modules open on a
-- PW5 spent ~275ms writing settings.lua twice because the day's new quote
-- needed a fresh fit. Here a save only changes memory, and one flush of the
-- small file follows FLUSH_DELAY_S later, outside whatever drew the screen.
--
--   local Cache = require("lib/bookshelf_module_cache")
--   Cache.read(key) / Cache.save(key, value) / Cache.flush()

local M = {}

local FLUSH_DELAY_S = 3

local _store
local function store()
    if not _store then
        local Paths = require("lib/bookshelf_paths")
        _store = require("lib/bookshelf_file_store").new(Paths.cacheFile("module_cache.lua"))
    end
    return _store
end

function M.read(key)
    local ok, v = pcall(function() return store().read(key) end)
    return ok and v or nil
end

local _flush_cb
function M.flush()
    if _flush_cb then
        pcall(function() require("ui/uimanager"):unschedule(_flush_cb) end)
        _flush_cb = nil
    end
    if _store then pcall(_store.flush) end
end

function M.save(key, value)
    if not pcall(function() store().saveDeferred(key, value) end) then return end
    if _flush_cb then return end
    local ok, UIManager = pcall(require, "ui/uimanager")
    if ok and UIManager and UIManager.scheduleIn then
        _flush_cb = function()
            _flush_cb = nil
            if _store then pcall(_store.flush) end
        end
        UIManager:scheduleIn(FLUSH_DELAY_S, _flush_cb)
    else
        pcall(_store.flush)
    end
end

-- Test seam: point the cache at a stand-in store.
function M._setStore(s) _store, _flush_cb = s, nil end

return M
