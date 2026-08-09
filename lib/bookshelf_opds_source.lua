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

-- Validate + map a raw server list (the stock plugin's own shape,
-- { title, url, username?, password? }) into our chip-source records. Shared
-- by both the live and the file paths so the two can never disagree on which
-- entries survive or how their keys are derived.
local function mapServers(list)
    local out = {}
    if type(list) ~= "table" then return out end
    for _i, s in ipairs(list) do
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

-- The raw server list off disk (loadfile the LuaSettings chunk), or nil when it
-- can't be read. Pcall'd loadfile, never LuaSettings:open - this bridge stays
-- read-only.
function M._fileServers()
    local path = M._settingsPath()
    if not path then return nil end
    local chunk = loadfile(path)
    if not chunk then return nil end
    local ok, data = pcall(chunk)
    if not ok or type(data) ~= "table" or type(data.servers) ~= "table" then
        return nil
    end
    return data.servers
end

-- M.liveInstance() -> module | nil
-- The live stock opds plugin instance (module carrying a `.servers` table and a
-- `.settings_file` ending "opds.lua"), reached via FileManager.instance then
-- ReaderUI.instance. READ-ONLY here; the catalogues writer mutates .servers in
-- place. Returns nil when no such instance is loaded. A seam of its own so
-- tests can stub it.
function M.liveInstance()
    local function probe(m, seen)
        if type(m) ~= "table" or seen[m] then return nil end
        seen[m] = true
        local ok, hit = pcall(function()
            local sf = m.settings_file
            if type(m.servers) == "table" and type(sf) == "string"
                    and sf:match("opds%.lua$") then
                return m
            end
            return nil
        end)
        return ok and hit or nil
    end
    local function findIn(ui)
        if type(ui) ~= "table" then return nil end
        local seen = {}
        for _i, m in ipairs(ui) do
            local s = probe(m, seen); if s then return s end
        end
        for _k, m in pairs(ui) do
            local s = probe(m, seen); if s then return s end
        end
        return nil
    end

    local candidates = {}
    local fm = package.loaded["apps/filemanager/filemanager"]
    if type(fm) == "table" and fm.instance then candidates[#candidates + 1] = fm.instance end
    local rd = package.loaded["apps/reader/readerui"]
    if type(rd) == "table" and rd.instance then candidates[#candidates + 1] = rd.instance end

    for _i, ui in ipairs(candidates) do
        local ok, inst = pcall(findIn, ui)
        if ok and inst then return inst end
    end
    return nil
end

-- M._liveServers() -> list | nil
--
-- The stock OPDS plugin edits its in-memory `self.servers` table the moment the
-- user saves in its editor, and only writes opds.lua back at a flush boundary
-- (its onFlushSettings). Reading the FILE therefore shows a stale catalogue
-- list until that flush lands, so PREFER the plugin's live table when its
-- instance is loaded.
--
-- Reached via the active UI the same way kobo_source / plugin_scan reach theirs
-- (FileManager.instance, else ReaderUI.instance). The plugin registers as a
-- module on that UI, but its field name ("opds") is not something to hardcode
-- against - feature-detect instead: the one module carrying BOTH a `.servers`
-- table AND a `.settings_file` string ending in "opds.lua" is it. READ-ONLY:
-- the table is only read, never written.
--
-- Returns nil (not {}) when no such live instance is found - crucially, the
-- stock plugin's `.servers` is nil until its own lazy loadSettings runs, so a
-- freshly booted session with the plugin present but never opened still falls
-- through to the file. A seam of its own so tests can stub it. Delegates to
-- liveInstance().
function M._liveServers()
    local inst = M.liveInstance()
    return inst and inst.servers or nil
end

function M.servers()
    -- Live in-memory list first (fresh across an unflushed editor save), the
    -- file only when there is no live instance to read - or when the one we
    -- found is empty, which on a lazily-initialised plugin means "not loaded
    -- yet", not "the user has zero servers".
    local live = M._liveServers()
    local raw = (type(live) == "table" and #live > 0) and live or M._fileServers()
    return mapServers(raw)
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
