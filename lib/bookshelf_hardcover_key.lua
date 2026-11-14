-- bookshelf_hardcover_key.lua
-- Where Bookshelf finds a Hardcover API key for its own client
-- (lib/bookshelf_hardcover_client).
--
-- In order: a key the reader gave Bookshelf itself, else one a sync plugin
-- already holds. A plugin's key is read from that plugin's own file every
-- session and never copied: Hardcover keys expire, and a silent copy would
-- go stale the day the reader renews theirs in the plugin. Keeping a copy
-- (so the key outlives the plugin) is something the reader asks for.
--
-- The plugins' files are READ AS TEXT and matched, never run: they are Lua
-- files in someone else's folder.
--
-- Bookshelf's own key is in a file of its own, not in the settings file
-- readers attach to bug reports. It is scrambled so it does not read at a
-- glance; that is NOT encryption. A device has no keystore, so any key to
-- decrypt with would sit in the file next door, and whoever can read one can
-- read the other.
--
-- A sync plugin's SIGN-IN tokens are not keys and are never used: they
-- expire within hours, and Hardcover gives them none of other readers'
-- reviews.

local M = {}

local OWN_FILE = "hardcover_key"
local MAGIC = "bs1:"

local _memo        -- nil = not looked yet; { token =, source = } (token may be nil)

local function readAll(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    return type(s) == "string" and s or nil
end

-- clean(text) -> the bare token, or nil. Takes a pasted "Bearer " prefix and
-- stray whitespace off. A token has no whitespace inside it.
function M.clean(text)
    if type(text) ~= "string" then return nil end
    local s = text:gsub("^%s+", ""):gsub("%s+$", "")
    s = s:gsub("^[Bb][Ee][Aa][Rr][Ee][Rr]%s+", "")
    if s == "" or s:find("%s") then return nil end
    return s
end

-- ── scrambling (see the header: not encryption) ─────────────────────────────
local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local PAD = "bookshelf.koplugin/hardcover"

local function xorByte(a, b)
    local r, p = 0, 1
    for _i = 1, 8 do
        local x, y = a % 2, b % 2
        if x ~= y then r = r + p end
        a, b, p = (a - x) / 2, (b - y) / 2, p * 2
    end
    return r
end

local function mask(s)
    local out = {}
    for i = 1, #s do
        out[i] = string.char(xorByte(s:byte(i), PAD:byte((i - 1) % #PAD + 1)))
    end
    return table.concat(out)
end

local function b64encode(s)
    local out = {}
    for i = 1, #s, 3 do
        local a, b, c = s:byte(i, i + 2)
        local n = a * 65536 + (b or 0) * 256 + (c or 0)
        local c1 = math.floor(n / 262144) % 64
        local c2 = math.floor(n / 4096) % 64
        local c3 = math.floor(n / 64) % 64
        local c4 = n % 64
        out[#out + 1] = B64:sub(c1 + 1, c1 + 1) .. B64:sub(c2 + 1, c2 + 1)
            .. (b and B64:sub(c3 + 1, c3 + 1) or "=")
            .. (c and B64:sub(c4 + 1, c4 + 1) or "=")
    end
    return table.concat(out)
end

local function b64decode(s)
    if #s % 4 ~= 0 or s:find("[^%w%+/=]") then return nil end
    local out = {}
    for i = 1, #s, 4 do
        local n, pad = 0, 0
        for j = 0, 3 do
            local ch = s:sub(i + j, i + j)
            local v
            if ch == "=" then
                v, pad = 0, pad + 1
            else
                v = B64:find(ch, 1, true)
                if not v then return nil end
                v = v - 1
            end
            n = n * 64 + v
        end
        local a = math.floor(n / 65536) % 256
        local b = math.floor(n / 256) % 256
        local c = n % 256
        out[#out + 1] = string.char(a) .. (pad < 2 and string.char(b) or "")
            .. (pad < 1 and string.char(c) or "")
    end
    return table.concat(out)
end

local function ownPath()
    return require("lib/bookshelf_paths").settingsFile(OWN_FILE)
end

local function readOwn()
    local ok, body = pcall(function() return readAll(ownPath()) end)
    if not ok or not body then return nil end
    body = body:gsub("%s+$", "")
    if body:sub(1, #MAGIC) ~= MAGIC then return nil end
    local raw = b64decode(body:sub(#MAGIC + 1))
    return raw and M.clean(mask(raw)) or nil
end

-- ── the sync plugins' own files ─────────────────────────────────────────────
local function pluginDirs()
    local dirs, seen = {}, {}
    local function add(d)
        if type(d) ~= "string" or d == "" then return end
        d = d:gsub("/+$", "")
        if not seen[d] then seen[d] = true; dirs[#dirs + 1] = d end
    end
    local ok, DataStorage = pcall(require, "datastorage")
    if ok and DataStorage then add(DataStorage:getDataDir() .. "/plugins") end
    local extra = G_reader_settings and G_reader_settings.readSetting
        and G_reader_settings:readSetting("extra_plugin_paths") or nil
    if type(extra) == "string" then
        add(extra)
    elseif type(extra) == "table" then
        for _i, d in ipairs(extra) do add(d) end
    end
    return dirs
end

local function tokenIn(text)
    return M.clean(text:match("token%s*=%s*\"([^\"]*)\"") or text:match("token%s*=%s*'([^']*)'"))
end

local PLUGINS = {
    {
        id = "hardcover",
        find = function(dirs)
            for _i, d in ipairs(dirs) do
                for _j, name in ipairs({ "hardcoverapp.koplugin", "hardcover.koplugin" }) do
                    local body = readAll(d .. "/" .. name .. "/hardcover_config.lua")
                    local tok = body and tokenIn(body)
                    if tok then return tok end
                end
            end
        end,
    },
    {
        id = "shelfsync",
        find = function(dirs)
            for _i, d in ipairs(dirs) do
                local body = readAll(d .. "/shelfsync.koplugin/shelfsync_config.lua")
                -- Its config has a section per service; only Hardcover's.
                local section = body and body:match("hardcover%s*=%s*(%b{})")
                local tok = section and tokenIn(section)
                if tok then return tok end
            end
            -- A key typed into its menu is in its settings file.
            local ok, DataStorage = pcall(require, "datastorage")
            if not ok or not DataStorage then return nil end
            local body = readAll(DataStorage:getSettingsDir() .. "/hardcoversync_settings.lua")
            return body and M.clean(body:match("%[\"api_token\"%]%s*=%s*\"([^\"]*)\"")) or nil
        end,
    },
}

local function fromPlugin()
    local dirs = pluginDirs()
    for _i, p in ipairs(PLUGINS) do
        local ok, tok = pcall(p.find, dirs)
        if ok and tok then return tok, p.id end
    end
    return nil
end

local function resolve()
    if _memo then return _memo end
    local own = readOwn()
    if own then
        _memo = { token = own, source = "own" }
    else
        local tok, id = fromPlugin()
        _memo = { token = tok, source = tok and id or nil }
    end
    return _memo
end

-- get() -> token, source ("own" | "hardcover" | "shelfsync") | nil
function M.get()
    local m = resolve()
    return m.token, m.source
end

function M.available() return resolve().token ~= nil end
function M.hasOwn() return resolve().source == "own" end

-- pluginSource() -> the id of a plugin that holds a key, or nil. Whatever
-- Bookshelf's own key is.
function M.pluginSource()
    local _tok, id = fromPlugin()
    return id
end

-- set(text) -> true, or false when the text is no token or cannot be saved.
function M.set(text)
    local tok = M.clean(text)
    if not tok then return false end
    local ok = pcall(function()
        local f = assert(io.open(ownPath(), "w"))
        f:write(MAGIC, b64encode(mask(tok)), "\n")
        f:close()
    end)
    M.invalidate()
    return ok
end

function M.clear()
    pcall(function() os.remove(ownPath()) end)
    M.invalidate()
end

-- A key is some 500 characters, more than anyone types on an e-reader. The
-- reader can put it in a text file in Bookshelf's settings folder instead.
local IMPORT_FILE = "hardcover_api_key.txt"

function M.importPath()
    return require("lib/bookshelf_paths").settingsFile(IMPORT_FILE)
end

-- importFile() -> true when the file held a key, which is now Bookshelf's
-- own; the plain file is removed. A file with no key in it is left alone.
function M.importFile()
    local ok, body = pcall(function() return readAll(M.importPath()) end)
    if not ok or not body then return false end
    if not M.set(body) then return false end
    pcall(function() os.remove(M.importPath()) end)
    return true
end

-- keepCopy() -> true when a plugin's key is now Bookshelf's own as well.
function M.keepCopy()
    local tok = fromPlugin()
    if not tok then return false end
    return M.set(tok)
end

function M.invalidate() _memo = nil end

return M
