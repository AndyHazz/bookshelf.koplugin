-- lib/bookshelf_opds_catalogs.lua
-- Write side of the OPDS catalogue list: add / edit / delete, persisting to the
-- SAME <settings>/opds.lua the stock opds.koplugin uses, so the stock plugin is
-- optional and, when present, stays in sync. The read side stays in
-- bookshelf_opds_source.lua (its "never write" contract is preserved); this is
-- the only writer. Records keep stock's shape:
--   { title, url, username?, password?, raw_names?, sync? }

local OpdsSource = require("lib/bookshelf_opds_source")

local M = {}

-- Last-resort mirror of stock's default_servers, used only when the live probe
-- finds no opds module (very old KOReader). Keep in step with stock.
local FALLBACK_DEFAULTS = {
    { title = "Project Gutenberg",     url = "https://m.gutenberg.org/ebooks.opds/?format=opds" },
    { title = "Standard Ebooks",       url = "https://standardebooks.org/feeds/opds" },
    { title = "ManyBooks",             url = "http://manybooks.net/opds/index.php" },
    { title = "Internet Archive",      url = "https://bookserver.archive.org/" },
    { title = "textos.info (Spanish)", url = "https://www.textos.info/catalogo.atom" },
    { title = "Gallica (French)",      url = "https://gallica.bnf.fr/opds" },
}

-- Prepend http:// when there is no scheme (matches stock).
function M.normaliseUrl(s)
    if type(s) ~= "string" then return s end
    if s:match("^%a+://") then return s end
    return "http://" .. s
end

-- Flat copy of a server list; only the six known fields, so no foreign keys
-- leak into what we persist.
local function copyServers(list)
    local out = {}
    for _i, s in ipairs(list or {}) do
        if type(s) == "table" then
            out[#out + 1] = {
                title = s.title, url = s.url,
                username = s.username, password = s.password,
                raw_names = s.raw_names, sync = s.sync,
            }
        end
    end
    return out
end
M._copyServers = copyServers  -- reused by later tasks/tests

-- Stock retains default_servers even when disabled: pluginloader dofiles every
-- plugin's main.lua at boot and keeps the module in enabled_plugins /
-- disabled_plugins. Probe both for the opds module (default_servers + a
-- settings_file ending opds.lua). pl seam injectable for tests.
function M.defaults(pl)
    if pl == nil then
        pl = package.loaded["pluginloader"]
        if pl == nil then
            local ok, m = pcall(require, "pluginloader")
            pl = ok and m or nil
        end
    end
    local function scan(list)
        if type(list) ~= "table" then return nil end
        for _i, m in ipairs(list) do
            local ok, hit = pcall(function()
                local sf = m.settings_file
                if type(m.default_servers) == "table"
                        and type(sf) == "string" and sf:match("opds%.lua$") then
                    return m.default_servers
                end
                return nil
            end)
            if ok and hit then return hit end
        end
        return nil
    end
    if type(pl) == "table" then
        local d = scan(pl.enabled_plugins) or scan(pl.disabled_plugins)
        if d then return d end
    end
    return FALLBACK_DEFAULTS
end

-- The effective catalogue list (raw stock-shaped records): live stock table if
-- loaded, else the file, else the defaults baseline. Always a fresh copy the
-- caller may mutate freely.
function M.list()
    local live = OpdsSource._liveServers and OpdsSource._liveServers() or nil
    if type(live) == "table" and #live > 0 then return copyServers(live) end
    local file = OpdsSource._fileServers and OpdsSource._fileServers() or nil
    if type(file) == "table" and #file > 0 then return copyServers(file) end
    return copyServers(M.defaults())
end

-- Persist the servers list to opds.lua. Writes ONLY the servers key (LuaSettings
-- loads the whole file, so settings/downloads/pending_syncs survive), flushes
-- immediately, then - if a live stock instance is loaded - refills its servers
-- table IN PLACE and flags it updated, so a later stock flush writes the same
-- data instead of clobbering ours.
function M.persist(list)
    local path = OpdsSource._settingsPath and OpdsSource._settingsPath() or nil
    if not path then return false end
    local ok_ls, LuaSettings = pcall(require, "luasettings")
    if not ok_ls or not LuaSettings then return false end
    local store = LuaSettings:open(path)
    store:saveSetting("servers", copyServers(list))
    store:flush()

    local inst = OpdsSource.liveInstance and OpdsSource.liveInstance() or nil
    if type(inst) == "table" and type(inst.servers) == "table" then
        local t = inst.servers
        for i = #t, 1, -1 do t[i] = nil end
        for _i, srv in ipairs(copyServers(list)) do t[#t + 1] = srv end
        inst.updated = true
    end
    return true
end

return M
