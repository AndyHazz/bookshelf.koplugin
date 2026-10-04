-- bookshelf_theme_pack.lua
-- Theme packs: an ornament pack's theme/ subfolder, and which pack's parts are
-- BORROWED right now.
--
--   <pack>/theme/wallpaper.<ext>            + .full / .dark / .full.dark variants
--   <pack>/theme/plank.middle.png           + plank.left.png / plank.right.png
--   <pack>/theme/plank.<name>.middle.png    a NAMED plank (+ .left / .right):
--                                           a pack may hold several, e.g. a
--                                           pack of wood shelves
--   <pack>/theme/colours.json               {"day": {name: "#RRGGBB"}, "night": {...}}
--   <pack>/theme/theme.json                 makes it a THEME PACK: {"name",
--                                           "description", "shelf": "light" |
--                                           "dark", "plank": a plank's name}
--
-- In a subfolder on purpose: the ornament scan is one level deep and png/svg
-- only (bookshelf_ornaments.listAll), so 5.2.x installs a theme pack as a plain
-- ornament pack and never mistakes wallpaper.png for an ornament.
--
-- BORROWING. A theme never writes the reader's own settings. Three keys say
-- which pack is lent to what; everything that paints asks here first and
-- falls back to the reader's own choice. Turning a part off deletes one key,
-- and the reader's settings are exactly as they left them however long the
-- theme was on (maintainer's ruling: borrow, not apply).
--
-- Wallpaper and colours switch separately (a reader may want a pack's picture
-- and keep their own colours, especially on black-and-white screens). The
-- plank design goes with the ornaments: it follows the pack's on/off and has
-- its own entry in the ornament off-set; one plank shows at a time.
local logger = require("logger")
local ok_i, I18n = pcall(require, "lib/bookshelf_i18n")
local _ = (ok_i and I18n and I18n.gettext) or function(x) return x end
local ok_u, FUtil = pcall(require, "ffi/util")
local T = (ok_u and FUtil and FUtil.template) or function(f, ...)
    local args = { ... }
    return (f:gsub("%%(%d)", function(i) return tostring(args[tonumber(i)]) end))
end

local M = {}

M.SUBDIR            = "theme"
M.COLOURS_SETTING   = "theme_colours_pack"
M.PLANK_SETTING     = "theme_plank_pack"
-- The BUILT-IN wood plank (v5.3): "oak" (on), false (off), or unset. Shipped
-- in the plugin (assets/planks/oak), toggled from the plank colour dialog.
-- UNSET means the default: on, unless the reader has picked a plank colour of
-- their own (day or night), which they keep -- so an upgrade gives the oak to
-- everyone who never touched the plank, as a new install does (maintainer).
-- A pack's plank overrides it; switching pack planks off falls back to it,
-- and with it off the shelf has its coloured plank.
M.WOOD_SETTING      = "plank_wood"
M.SCAN_TTL          = 15
M.MANIFEST          = "theme.json"
M._clock            = os.time

M.WALL_EXTS = { png = true, jpg = true, jpeg = true, webp = true, bmp = true, gif = true }
local VARIANT = { ["wallpaper"] = "base", ["wallpaper.full"] = "full",
                  ["wallpaper.dark"] = "dark", ["wallpaper.full.dark"] = "full_dark" }

-- The names a pack author writes in colours.json, and the settings they lend.
M.COLOUR_NAMES = {
    ["text"]                 = "ink_color",
    ["progress bar"]         = "progress_fill",
    ["progress track"]       = "progress_track",
    ["bookmark"]             = "bookmark_color",
    ["finished bookmark"]    = "complete_bookmark_color",
    ["favourite star"]       = "favorite_star_color",
    ["favourite heart"]      = "favorite_heart_color",
    ["badge text"]           = "badge_fg",
    ["badge background"]     = "badge_bg",
    ["menu bar"]             = "chrome_bg",
    ["module card"]          = "module_bg",
    ["module border"]        = "module_border",
    ["cover border"]         = "border_color",
    ["selection"]            = "selection_color",
    ["cover shadow"]         = "card_shadow_color",
    ["plank"]                = "spine_plank_color",
    ["folder label"]         = "folder_overlay_bg",
    ["folder text"]          = "folder_overlay_fg",
    ["selected shelf"]       = "chip_selected_bg",
    ["selected shelf text"]  = "chip_selected_fg",
    ["page"]                 = "wallpaper_bg",
}

-- Seams for the tests.
M._store, M._lfs, M._decode, M._orn = nil, nil, nil, nil

local function store()
    if M._store then return M._store end
    local ok, S = pcall(require, "lib/bookshelf_settings_store")
    return ok and S or nil
end
local function read(k)
    local s = store()
    if not s then return nil end
    return s.read(k)            -- false survives: theme_plank_pack = false is "none"
end
local function save(k, v)
    local s = store(); if not s then return end
    -- Deferred with the ornaments while the browser is open (Orn.beginDeferred).
    local O = M._orn or package.loaded["lib/bookshelf_ornaments"]
    if O and O._defer and s.saveDeferred then s.saveDeferred(k, v) return end
    s.save(k, v); if s.flush then pcall(s.flush) end
end
local function fs() return M._lfs or require("libs/libkoreader-lfs") end
local function orn() return M._orn or require("lib/bookshelf_ornaments") end
local function decode(text)
    if M._decode then return M._decode(text) end
    return require("rapidjson").decode(text)
end

local function listDir(d)
    local out = {}
    local ok = pcall(function()
        for name in fs().dir(d) do
            if name:sub(1, 1) ~= "." and fs().attributes(d .. "/" .. name, "mode") == "file" then
                out[#out + 1] = name
            end
        end
    end)
    if not ok then return {} end
    table.sort(out)
    return out
end

local function parseColours(path, pack)
    local f = io.open(path, "rb"); if not f then return nil end
    local text = f:read("*a"); f:close()
    local ok, doc = pcall(decode, text)
    if not ok or type(doc) ~= "table" then
        logger.warn("[bookshelf] theme colours.json could not be read:", pack)
        return nil
    end
    local out, any = { day = {}, night = {} }, false
    for _i, look in ipairs({ "day", "night" }) do
        local set = doc[look]
        if type(set) == "table" then
            for name, hex in pairs(set) do
                local key = type(name) == "string" and M.COLOUR_NAMES[name:lower()]
                if key and type(hex) == "string" and hex:match("^#%x%x%x%x%x%x$") then
                    out[look][key] = hex:upper(); any = true
                else
                    logger.warn("[bookshelf] theme colour skipped:", pack, look, tostring(name), tostring(hex))
                end
            end
        end
    end
    return any and out or nil
end

-- parseManifest(path, pack) -> theme.json's fields (any of them nil). A file
-- that cannot be read is logged and gives {}: the pack is still a theme pack,
-- listed by its folder name, so a typo cannot hide a pack someone paid for.
local function parseManifest(path, pack)
    local f = io.open(path, "rb"); if not f then return {} end
    local text = f:read("*a"); f:close()
    local ok, doc = pcall(decode, text)
    if not ok or type(doc) ~= "table" then
        logger.warn("[bookshelf] theme.json could not be read:", pack)
        return {}
    end
    local function str(k)
        local v = doc[k]
        return (type(v) == "string" and v ~= "") and v or nil
    end
    local shelf = str("shelf")
    if shelf ~= "light" and shelf ~= "dark" then shelf = nil end
    return { name = str("name"), description = str("description"), shelf = shelf, plank = str("plank") }
end

-- _plankPart(file) -> name, part for "plank[.<name>].<middle|left|right>.png"
-- (name "" for the unnamed plank), or nil.
function M._plankPart(file)
    local stem = file:match("^(.+)%.[Pp][Nn][Gg]$")
    if not stem or stem:sub(1, 6):lower() ~= "plank." then return nil end
    local rest = stem:sub(7)
    local name, part = rest:match("^(.*)%.([^%.]+)$")
    if not name then name, part = "", rest end
    part = part:lower()
    if part ~= "middle" and part ~= "left" and part ~= "right" then return nil end
    return name, part
end

-- theme(pack) -> what the pack's theme/ holds (fields nil when absent).
M._cache = {}
function M.theme(pack)
    local now = M._clock()
    local hit = M._cache[pack]
    if hit and M.SCAN_TTL > 0 and (now - hit.at) < M.SCAN_TTL then return hit.v end
    -- The pack's own folder, in whichever ornaments folder holds it (the
    -- new one first: Orn.packDir). A stub without packDir has one folder.
    local O = orn()
    local pdir = (O.packDir and O.packDir(pack))
                 or (O.dir() and (O.dir() .. "/" .. pack)) or nil
    local tdir = pdir and (pdir .. "/" .. M.SUBDIR) or nil
    -- exists: the pack folder is there, checked once per scan rather than on
    -- every colour read (a stat is dear on a Kindle's FUSE storage).
    local v = { dir = tdir, planks = {},
                exists = pdir and fs().attributes(pdir, "mode") == "directory" or false }
    if tdir and fs().attributes(tdir, "mode") == "directory" then
        local names = listDir(tdir)
        local w = {}
        local planks = {}          -- by name ("" = the unnamed plank)
        for _i, n in ipairs(names) do
            local stem, ext = n:match("^(.-)%.([^%.]+)$")
            local lstem = stem and stem:lower()
            if lstem and M.WALL_EXTS[ext:lower()] and VARIANT[lstem] and not w[VARIANT[lstem]] then
                w[VARIANT[lstem]] = n
            elseif M._plankPart(n) then
                local name, part = M._plankPart(n)
                planks[name] = planks[name] or {}
                planks[name][part] = tdir .. "/" .. n
            elseif n:lower() == "colours.json" then v.colours = parseColours(tdir .. "/" .. n, pack)
            elseif n:lower() == M.MANIFEST then v.manifest = parseManifest(tdir .. "/" .. n, pack)
            end
        end
        if w.base then v.wallpaper = w end
        v.planks = {}
        for name, pl in pairs(planks) do
            if pl.middle then
                pl.pack = pack
                pl.name = name ~= "" and name or nil
                pl.id = pack .. "/" .. M.SUBDIR .. "/plank" .. (pl.name and ("." .. name) or "")
                v.planks[#v.planks + 1] = pl
            end
        end
        table.sort(v.planks, function(a, b)
            if (a.name == nil) ~= (b.name == nil) then return a.name == nil end
            return (a.name or ""):lower() < (b.name or ""):lower()
        end)
    end
    M._cache[pack] = { at = now, v = v }
    return v
end

function M.invalidate() M._cache = {}; M._plank_memo = nil end
-- forgetChoice(): after a switch, work out which plank shows again, without
-- re-listing every pack's theme folder the way invalidate() does.
function M.forgetChoice() M._plank_memo = nil end

-- ── THE SHELF ON SCREEN ─────────────────────────────────────────────────
-- Any shelf may wear its own theme (tab.theme: unset = the library's,
-- "none" = no theme pack, else a pack's folder; tab.theme_look: unset or
-- auto/light/dark). The widget names the shelf before each build
-- (setShelf); the lookups below answer from that shelf's pack where it has
-- the part, else as before. Nothing is written: a change of look only bumps
-- the settings generation, so the caches keyed on it are rebuilt.
M._shelf = nil
M._shelf_key = "lib"
M._tab = nil      -- seam: fn(id) -> tab record

local function tabFor(id)
    if id == nil then return nil end
    if M._tab then return M._tab(id) end
    local ok, TabModel = pcall(require, "lib/bookshelf_tab_model")
    if not ok or not TabModel then return nil end
    local ok2, tab = pcall(TabModel.getById, id)
    return ok2 and tab or nil
end

-- shelfChoiceFor(id) -> nil | "none" | a pack's folder: the tab's own choice.
function M.shelfChoiceFor(id)
    local tab = tabFor(id)
    local v = tab and tab.theme
    return (type(v) == "string" and v ~= "") and v or nil
end

-- shelfLookFor(id) -> nil (follow) | "auto" | "light" | "dark".
function M.shelfLookFor(id)
    local tab = tabFor(id)
    local v = tab and tab.theme_look
    if v == "auto" or v == "light" or v == "dark" then return v end
    return nil
end

-- shelfPackFor(id) -> nil (the library's), "none", or a pack that exists. A
-- pack that has gone reads as the library's; the tab keeps its name, so it
-- comes back with the folder.
function M.shelfPackFor(id)
    local v = M.shelfChoiceFor(id)
    if v == nil or v == "none" then return v end
    if M.theme(v).exists then return v end
    return nil
end

function M.shelfPack() return M.shelfPackFor(M._shelf) end

-- shelfKey() -> what the shelf on screen looks like, as a cache key.
function M.shelfKey()
    local sp = M.shelfPack()
    local look = M.shelfLookFor(M._shelf)
    local k = (sp == nil and "lib") or (sp == "none" and "none") or ("pack:" .. sp)
    if look then k = k .. "|" .. look end
    return k
end

-- setShelf(id) -> true when the shelf on screen now looks different.
function M.setShelf(id)
    M._shelf = id
    local key = M.shelfKey()
    if key == M._shelf_key then return false end
    M._shelf_key = key
    local s = store()
    if s and s.bump then s.bump() end
    return true
end

-- themePacks() -> the installed theme packs (a theme/theme.json), for the
-- Shelf theme menu: { pack, name, description, shelf, plank }, by name. A
-- pack switched off is listed too: choosing it switches it on.
function M.themePacks()
    local _all, packs = orn().listAll()
    local out = {}
    for _i, p in ipairs(packs or {}) do
        local m = M.theme(p).manifest
        if m then
            out[#out + 1] = { pack = p, name = m.name or p, description = m.description,
                              shelf = m.shelf, plank = m.plank }
        end
    end
    table.sort(out, function(a, b) return a.name:lower() < b.name:lower() end)
    return out
end

-- displayName(pack) -> what menus call a theme: its manifest's name, else
-- its folder's. Every pack is a theme since 5.4 (maintainer, 2026-10-03).
function M.displayName(pack)
    local m = pack and M.theme(pack).manifest
    return (m and m.name) or pack
end

-- allThemes() -> every pack as a theme: theme packs (a theme.json) by name,
-- then the others by folder, marked ornaments_only. Switched-off packs too.
function M.allThemes()
    local _all, packs = orn().listAll()
    local full, plain = {}, {}
    for _i, p in ipairs(packs or {}) do
        local m = M.theme(p).manifest
        if m then
            full[#full + 1] = { pack = p, name = m.name or p, description = m.description,
                                ornaments_only = false }
        else
            plain[#plain + 1] = { pack = p, name = p, ornaments_only = true }
        end
    end
    local function byName(a, b) return a.name:lower() < b.name:lower() end
    table.sort(full, byName); table.sort(plain, byName)
    for _i, e in ipairs(plain) do full[#full + 1] = e end
    return full
end

-- rescan(): forget the theme folders' scan, so a pack copied in or deleted
-- since the last look (or a theme.json added to one) is seen now, not after
-- the scan TTL. The Shelf theme menu calls it each time it opens. Not the
-- ornaments list's: listAll already sees a pack folder come or go (its key is
-- the folders' mtimes and names), and dropping it re-read every ornament file
-- and gave Orn.list() a new identity, which threw away every page's saved
-- ornament layout (review).
function M.rescan()
    M.invalidate()
end

-- wallpaperFile(w, is_full, is_dark) -> file name, and whether it is a dark
-- variant (shown as drawn: the reader's invert-at-night does not apply).
function M.wallpaperFile(w, is_full, is_dark)
    if not w then return nil end
    local order
    if is_full and is_dark then order = { "full_dark", "full", "dark", "base" }
    elseif is_full then order = { "full", "base" }
    elseif is_dark then order = { "dark", "base" }
    else order = { "base" } end
    for _i, k in ipairs(order) do
        if w[k] then return w[k], (k == "dark" or k == "full_dark") end
    end
    return nil
end

-- A borrowed part whose pack or file has gone: clear the key, fall back.
-- A pack that is switched off lends nothing, but keeps the key, so switching
-- it back on brings its part back; a pack (or part) that is gone clears it.
local function activeFor(key, part)
    local pack = read(key)
    if type(pack) ~= "string" or pack == "" then return nil end
    local th = M.theme(pack)
    if not (th.exists and th[part]) then save(key, nil); return nil end
    if orn().isPackOff(pack) then return nil end
    return pack
end

function M.activeColoursPack() return activeFor(M.COLOURS_SETTING, "colours") end
function M.setColoursPack(pack) save(M.COLOURS_SETTING, pack) end

-- colourThemes() -> the packs with a colours.json, for the Color theme row.
function M.colourThemes()
    local _all, packs = orn().listAll()
    local out = {}
    for _i, p in ipairs(packs or {}) do
        if M.theme(p).colours then out[#out + 1] = p end
    end
    return out
end

-- The plugin's root (one level up from lib/), for the built-in plank's files;
-- the idiom Wallpaper.seedSource uses. A seam for the tests.
M._plugin_root = nil
local function pluginRoot()
    if M._plugin_root then return M._plugin_root end
    local src = debug.getinfo(1, "S").source or ""
    local dir = src:match("^@(.*)/lib/[^/]*$")
    return dir or "."
end

-- builtinPlank() -> the shipped Oak plank's record, or nil if its files are
-- missing (a source checkout that lost them).
function M.builtinPlank()
    local d = pluginRoot() .. "/assets/planks/oak"
    local function f(part)
        local path = d .. "/plank." .. part .. ".png"
        return fs().attributes(path, "mode") == "file" and path or nil
    end
    local middle = f("middle")
    if not middle then return nil end
    return { id = "builtin:oak", name = "Oak", builtin = true,
             middle = middle, left = f("left"), right = f("right") }
end

-- plankLabel(p) -> what menus call a plank: its name, or its pack's.
function M.plankLabel(p) return p and (p.name or p.pack) or nil end

-- activePlank() -> the plank design on show ({id, pack, name, middle, left,
-- right}; the built-in Oak has builtin = true and no pack), or nil for the
-- coloured plank. A pack's plank first, then the built-in wood if it is on. The chosen one if it still qualifies, else the first there
-- is: a plank shows by default, like ornaments do, when its pack is on.
--
-- Cached for the scan TTL: it is asked on every shelf build, a page turn bumps
-- the settings generation, and answering means listing the ornaments folder.
-- A switch (setPlankOn, invalidate) drops the answer at once.
--
-- theme_plank_pack = false means "none": switching the SHOWN plank off must
-- not hand the shelf to the next plank that happens to be on too. Otherwise it
-- holds the chosen plank's id.
M._plank_memo = nil
function M.activePlank()
    if not M.designsOn() then return nil end
    return M.chosenPlank()
end

-- chosenPlank() -> the plank design the reader has chosen (a pack's, or the
-- built-in Oak), whether or not designs are switched on: what Performance
-- tweaks names.
--
-- The shelf on screen: its pack's plank when it has one; on No theme pack the
-- reader's own choice (from before any library theme); else the library's.
-- The memo is per shelf look.
function M.chosenPlank()
    local now = M._clock()
    local key = M.shelfKey()
    local memo = M._plank_memo
    if memo and memo.key == key and M.SCAN_TTL > 0 and (now - memo.at) < M.SCAN_TTL then
        return memo.v
    end
    local v
    local sp = M.shelfPack()
    if sp ~= nil and sp ~= "none" and #(M.theme(sp).planks or {}) > 0 then
        v = M.themePlank(sp)
    else
        local c = M.plankChoice(sp == "none" and M.ownRead or nil)
        if c == "oak" then v = M.builtinPlank()
        elseif c ~= "colour" then v = M._packPlank(c) end
    end
    M._plank_memo = { at = now, v = v, key = key }
    return v
end

-- Plank designs on or off (Settings > Advanced > Performance tweaks): a
-- design costs a black and white Kindle ~35ms on each spine-shelf tap (its
-- shadow is blended onto the screen), and Oak is on by default, so it gets a
-- switch there (maintainer). Off draws Bookshelf's own plank colour. It never
-- stops a reader choosing a plank: choosing one switches designs back on.
M.DESIGNS_OFF_SETTING = "plank_designs_off"
function M.designsOn() return read(M.DESIGNS_OFF_SETTING) ~= true end
function M.setDesignsOn(on)
    save(M.DESIGNS_OFF_SETTING, (not on) and true or nil)
    M._plank_memo = nil
end

-- The plank is ONE choice (theme_plank_pack): a pack plank's id, "oak", or
-- false for the plain colour. Unset: Oak on a fresh install, the reader's own
-- colour if they ever set one (plank_wood = false, or a plank colour), so an
-- upgrade never changes a shelf. A pack's plank is never chosen by installing
-- its pack: only by the plank picker or Apply pack theme (maintainer).

-- _packPlank(id) -> that pack plank, when its pack is on and it is there.
function M._packPlank(id)
    local O = orn()
    local _all, packs = O.listAll()
    for _i, p in ipairs(packs or {}) do
        if not O.isPackOff(p) then
            for _j, pl in ipairs(M.theme(p).planks or {}) do
                if pl.id == id then return pl end
            end
        end
    end
    return nil
end

local function fallbackChoice(rd)
    rd = rd or read
    local wood = rd(M.WOOD_SETTING)
    if wood == "oak" then return "oak" end
    if wood == false then return "colour" end
    if rd("spine_plank_color") ~= nil or rd("spine_plank_color_night") ~= nil then
        return "colour"
    end
    return "oak"
end

-- plankChoice() -> "colour" | "oak" | a pack plank's id: what shows (a pack
-- plank whose pack is off or gone reads as the fallback, and comes back when
-- the pack is on again).
--
-- rd reads the settings (M.ownRead for a shelf on No theme pack); default
-- the settings as they are.
function M.plankChoice(rd)
    rd = rd or read
    local v = rd(M.PLANK_SETTING)
    if v == false then return "colour" end
    if v == "oak" then return "oak" end
    if type(v) == "string" and M._packPlank(v) then return v end
    return fallbackChoice(rd)
end

-- choosePlank(choice): the reader's pick. Choosing a design shows it, even
-- with designs off (Performance tweaks); choosing the colour does not touch
-- that switch.
function M.choosePlank(choice)
    -- Not `and false or choice`: false is falsy, so that saved the word.
    local v = choice
    if choice == "colour" then v = false end
    save(M.PLANK_SETTING, v)
    save(M.WOOD_SETTING, nil)          -- folded into the one choice
    if choice ~= "colour" and not M.designsOn() then M.setDesignsOn(true) end
    M._plank_memo = nil
end

-- plankRowLabel() -> what the Shelf plank row and Performance tweaks name:
-- "Oak", "Walnut (Planks pack)", or nil for the plain colour (the caller shows the
-- colour's value).
function M.plankRowLabel()
    local c = M.plankChoice()
    if c == "colour" then return nil end
    local p
    if c == "oak" then p = M.builtinPlank() else p = M._packPlank(c) end
    if not p then return nil end
    if p.pack and p.name then return T(_("%1 (%2 pack)"), p.name, p.pack) end
    return M.plankLabel(p)
end

-- plankOptions() -> the plank picker's entries, in order: the colour, Oak,
-- then each pack's planks (packs A-Z; a pack that is off is listed, marked).
function M.plankOptions()
    local O = orn()
    local out = { { kind = "colour" }, { kind = "oak", plank = M.builtinPlank() } }
    local _all, packs = O.listAll()
    local sorted = {}
    for _i, p in ipairs(packs or {}) do sorted[#sorted + 1] = p end
    table.sort(sorted)
    for _i, p in ipairs(sorted) do
        local pls = {}
        for _j, pl in ipairs(M.theme(p).planks or {}) do pls[#pls + 1] = pl end
        table.sort(pls, function(a, b) return (a.name or "") < (b.name or "") end)
        for _j, pl in ipairs(pls) do
            out[#out + 1] = { kind = "pack", pack = p, plank = pl, pack_off = O.isPackOff(p) or nil }
        end
    end
    return out
end

-- ── Choosing a theme pack ────────────────────────────────────────────────
-- A theme pack (themePacks) is the whole look, chosen in the Shelf theme
-- menu. Choosing one sets each part it has (GROUPS, the shelf's light or dark
-- when its manifest says), switches its ornament pack on and every other
-- pack off (loose ornaments are in no pack, so stay as they are), and gives
-- back to the reader anything it does not set that an earlier theme still
-- holds. The record (APPLIED_SETTING) keeps, per setting, the value from
-- before the first theme beside what the theme left: a group still as the
-- theme left it is "held"; one the reader has changed since is theirs, and is
-- kept when the theme is turned off (No theme pack, clearTheme).
M.APPLIED_SETTING = "theme_applied"
M.SHELF_SETTING   = "shelf_theme"          -- CoverProgress.THEME_SETTING
local GROUPS = {
    plank     = { M.PLANK_SETTING, M.WOOD_SETTING, M.DESIGNS_OFF_SETTING },
    wallpaper = { "wallpaper_default", "wallpaper_default_own" },
    colours   = { M.COLOURS_SETTING },
    shelf     = { M.SHELF_SETTING },
}
-- A saved nil, which a settings table cannot hold as a value.
local NIL_MARK = "\0nil"
local function enc(v) if v == nil then return NIL_MARK end return v end
local function dec(v) if v == NIL_MARK then return nil end return v end

local function packList()
    local _all, packs = orn().listAll()
    return packs or {}
end

-- packExists(pack): from the theme scan, which the scan TTL caches and the
-- Shelf theme menu's rescan refreshes. Not listAll: every menu row's mark asks
-- currentTheme, and a listAll is every root and every pack folder (review).
local function packExists(pack)
    return pack ~= nil and M.theme(pack).exists == true
end

-- held(s, keys) -> the theme set this group and EVERY setting of it is still
-- what it left: changing any one (Plank designs off in Performance tweaks)
-- makes the group the reader's (review).
local function held(s, keys)
    for _i, k in ipairs(keys) do
        local a = s.applied[k]
        if a == nil or read(k) ~= dec(a) then return false end
    end
    return true
end

-- packHeld(s, p) -> pack p is switched as the theme left it. Per pack: one
-- switch in the collection is the reader's, the others stay the theme's
-- (review: one switch released them all, and No theme pack left the rest
-- off). A record without packs_applied (the old Apply's) holds none.
local function packHeld(s, p)
    if type(s.packs_applied) ~= "table" then return false end
    return (orn().isPackOff(p) == true) == (s.packs_applied[p] == true)
end

-- deferred(fn): fn's settings writes as one flush (each setPackOff and each
-- part was a full write), unless a caller already defers them (the Ornament
-- collection open), whose own end flushes.
local function deferred(fn)
    local O = orn()
    local own = O.beginDeferred ~= nil and not O._defer
    if own then O.beginDeferred() end
    local ok, r = pcall(fn)
    if own then O.endDeferred() end
    if not ok then error(r, 0) end
    return r
end

-- record() -> the chosen theme's record, or nil (none, or its pack is gone).
local function record()
    local s = read(M.APPLIED_SETTING)
    if type(s) ~= "table" or type(s.before) ~= "table" or type(s.applied) ~= "table" then return nil end
    if not packExists(s.pack) then return nil end
    return s
end

-- ownRead(k) -> the reader's own value of k: the value from before the
-- library theme when the theme still holds k as it left it, else k itself.
-- What a shelf on No theme pack shows.
function M.ownRead(k)
    local s = record()
    if s and s.applied[k] ~= nil and read(k) == dec(s.applied[k]) then
        return dec(s.before[k])
    end
    return read(k)
end

-- currentTheme() -> the theme pack in use (its folder name), or nil. It stays
-- named while the reader changes its parts: only No theme pack, another
-- theme, or the pack going ends it.
function M.currentTheme()
    local s = record()
    return s and s.pack or nil
end

-- restore(s, keys): a group back to what it was before the first theme.
local function restore(s, keys)
    for _i, k in ipairs(keys) do save(k, dec(s.before[k])); s.applied[k] = nil end
end

-- clearTheme(): No theme pack. Each group the theme still holds goes back to
-- the reader's own (unset values unset); one they changed is left as it is;
-- the packs, if still as the theme switched them, as they were before.
function M.clearTheme()
    deferred(function()
        local s = record()
        if s then
            for _g, keys in pairs(GROUPS) do
                if held(s, keys) then restore(s, keys) end
            end
            local before = type(s.packs_before) == "table" and s.packs_before or {}
            for _i, p in ipairs(packList()) do
                if packHeld(s, p) then orn().setPackOff(p, before[p] == true) end
            end
        end
        save(M.APPLIED_SETTING, nil)
        M._plank_memo = nil
    end)
end

-- themePlank(pack) -> the plank a theme uses: its manifest's, by name (any
-- case), else its first by name; nil when it has none.
function M.themePlank(pack)
    local th = M.theme(pack)
    local planks = th.planks or {}
    local want = th.manifest and th.manifest.plank
    if want then
        for _i, pl in ipairs(planks) do
            if pl.name and pl.name:lower() == want:lower() then return pl end
        end
    end
    return planks[1]
end

-- chooseTheme(pack) -> true, or false when the pack's folder is gone (then
-- nothing changes). Any pack: one without a theme.json lends what it has
-- (its ornaments, perhaps a plank) and the rest stays the reader's.
function M.chooseTheme(pack)
    local th = M.theme(pack)
    if not th.exists then return false end
    return deferred(function()
    local s = record() or { before = {}, applied = {} }
    s.pack = pack
    -- What is there now is the reader's own, unless a theme still holds it:
    -- then the value from before the first theme stands.
    for _g, keys in pairs(GROUPS) do
        if not held(s, keys) then
            for _i, k in ipairs(keys) do s.before[k] = enc(read(k)); s.applied[k] = nil end
        end
    end
    -- The same per pack: one the theme still has as it left it keeps its
    -- state from before; one the reader switched (or a new one) is theirs now.
    local old_before = type(s.packs_before) == "table" and s.packs_before or {}
    local packs_before = {}
    for _i, p in ipairs(packList()) do
        if packHeld(s, p) then packs_before[p] = old_before[p] or nil
        elseif orn().isPackOff(p) then packs_before[p] = true end
    end
    s.packs_before = packs_before
    -- Its ornaments on, every other pack's off. First: a pack that is off
    -- lends nothing, so its plank would not be found.
    for _i, p in ipairs(packList()) do orn().setPackOff(p, p ~= pack) end
    local plank = M.themePlank(pack)
    local shelf = th.manifest and th.manifest.shelf
    local sets = { wallpaper = th.wallpaper ~= nil, colours = th.colours ~= nil,
                   plank = plank ~= nil, shelf = shelf ~= nil }
    -- What this theme does not set and an earlier one still holds: the
    -- reader's own again, not the earlier theme's (Halloween over Ukiyo-e
    -- kept Ukiyo-e's plank, PW5).
    for g, keys in pairs(GROUPS) do
        if not sets[g] and held(s, keys) then restore(s, keys) end
    end
    if sets.wallpaper then
        M.chooseWallpaper("wallpaper_default", M.NAME_PREFIX .. pack .. "\1" .. th.wallpaper.base)
    end
    if sets.colours then M.setColoursPack(pack) end
    if sets.plank then M.choosePlank(plank.id) end
    if sets.shelf then save(M.SHELF_SETTING, shelf) end
    for g, keys in pairs(GROUPS) do
        if sets[g] then
            for _i, k in ipairs(keys) do s.applied[k] = enc(read(k)) end
        end
    end
    local applied_packs = {}
    for _i, p in ipairs(packList()) do
        if orn().isPackOff(p) then applied_packs[p] = true end
    end
    s.packs_applied = applied_packs
    s.switched_on = nil                         -- the old Apply's, now the packs group's job
    save(M.APPLIED_SETTING, s)
    M._plank_memo = nil
    return true
    end)
end

-- invertHex("#RRGGBB") -> its negative, same shape. What
-- bookshelf_color.invertValue does for a hex value; kept here because a pack
-- only ever lends "#RRGGBB" and this module must load without Blitbuffer.
function M.invertHex(hex)
    local r, g, b = hex:match("^#(%x%x)(%x%x)(%x%x)$")
    if not r then return hex end
    return string.format("#%02X%02X%02X", 255 - tonumber(r, 16),
                         255 - tonumber(g, 16), 255 - tonumber(b, 16))
end

-- colourOverride(key, dark) -> the borrowed colour for that setting in the
-- STORED convention of its slot, or nil. Night slots hold colours pre-inverted
-- for a frame that will flip (see bookshelf_color.invertValue); the plank is
-- the one exception, kept in display space in both.
--
-- The shelf on screen: its pack's colours when it has them; none on No theme
-- pack; else the library's.
function M.colourOverride(key, dark)
    local sp = M.shelfPack()
    if sp == "none" then return nil end
    local pack
    if sp ~= nil and M.theme(sp).colours then pack = sp
    else pack = M.activeColoursPack() end
    if not pack then return nil end
    local c = M.theme(pack).colours
    local set = c and (dark and c.night or c.day)
    local hex = set and set[key]
    if not hex then return nil end
    if dark and key ~= "spine_plank_color" then hex = M.invertHex(hex) end
    return { hex = hex }
end

-- A borrowed wallpaper travels under a NAME, like every other wallpaper, so
-- Wallpaper.bg's cache and the widget's plumbing need no second path. The
-- prefix cannot collide with a file name (it carries a control character) and
-- Wallpaper.pathFor hands names carrying it to wallpaperPath.
M.NAME_PREFIX = "theme-pack\1"

function M.isPackName(name)
    return type(name) == "string" and name:sub(1, #M.NAME_PREFIX) == M.NAME_PREFIX
end

-- wallpaperEntries() -> every pack's wallpaper as a choice for the wallpaper
-- picker ({name, label, pack, path}; a pack that is off is listed, marked).
-- The name is the base file's: the view's variant is picked at paint time.
function M.wallpaperEntries()
    local O = orn()
    local _all, packs = O.listAll()
    local out = {}
    for _i, p in ipairs(packs or {}) do
        local th = M.theme(p)
        local file = th.wallpaper and th.wallpaper.base
        if file then
            out[#out + 1] = { name = M.NAME_PREFIX .. p .. "\1" .. file, label = p, pack = p,
                              path = th.dir .. "/" .. file, pack_off = O.isPackOff(p) or nil }
        end
    end
    return out
end

-- variantName(name, is_full, is_dark) -> for a pack wallpaper's name, that
-- pack's wallpaper for this view (full screen, dark), or nil when its pack is
-- off or gone; any other name is returned as it is.
function M.variantName(name, is_full, is_dark)
    if not M.isPackName(name) then return name end
    local pack = name:sub(#M.NAME_PREFIX + 1):match("^([^\1]+)\1")
    local th = pack and M.theme(pack)
    if not (th and th.exists and th.wallpaper) or orn().isPackOff(pack) then return nil end
    local file = M.wallpaperFile(th.wallpaper, is_full, is_dark)
    return file and (M.NAME_PREFIX .. pack .. "\1" .. file) or nil
end

-- chooseWallpaper(key, name): store a wallpaper choice (wallpaper_default or
-- wallpaper_full). A pack's replacing the reader's own remembers theirs in
-- <key>_own, which the shelf shows again if the pack goes or is switched off;
-- choosing one of their own forgets it.
function M.chooseWallpaper(key, name)
    local cur = read(key)
    if M.isPackName(name) then
        if cur ~= nil and not M.isPackName(cur) then save(key .. "_own", cur) end
    else
        save(key .. "_own", nil)
    end
    save(key, name)
end

-- shownWallpaper(is_full, is_dark) -> the wallpaper name the shelf shows in
-- this view. Full screen: None stays None; its own choice wins, a pack's as
-- that pack's variant, else the reader's own from before it; with neither,
-- whatever the default shows ("Same as default"). The default: its choice, a
-- pack's as its variant for this view, else the reader's own from before it.
--
-- The shelf on screen: its pack's wallpaper when it has one (full screen None
-- stays None); on No theme pack the reader's own, never a pack's; else as
-- above.
function M.shownWallpaper(is_full, is_dark)
    local sp = M.shelfPack()
    if sp ~= nil and sp ~= "none" then
        local th = M.theme(sp)
        if th.wallpaper then
            if is_full and read("wallpaper_full") == false then return nil end
            local file = M.wallpaperFile(th.wallpaper, is_full, is_dark)
            if file then return M.NAME_PREFIX .. sp .. "\1" .. file end
        end
    end
    local own_only = (sp == "none")
    local function layer(key, full_view)
        local v = read(key)
        if not M.isPackName(v) then
            return (type(v) == "string" and v ~= "") and v or nil
        end
        if not own_only then
            local shown = M.variantName(v, full_view, is_dark)
            if shown then return shown end
        end
        local own = read(key .. "_own")
        return (type(own) == "string" and own ~= "" and not M.isPackName(own)) and own or nil
    end
    if is_full then
        local fv = read("wallpaper_full")
        if fv == false then return nil end
        local n = layer("wallpaper_full", true)
        if n then return n end
    end
    return layer("wallpaper_default", is_full)
end

-- shelfLookOf(id) -> "auto" | "light" | "dark" for that shelf: its own
-- choice; else its pack's manifest when it says; on No theme pack the
-- reader's own; else the setting (which a library theme may hold).
function M.shelfLookOf(id)
    local own = M.shelfLookFor(id)
    if own then return own end
    local sp = M.shelfPackFor(id)
    local v
    if sp == "none" then
        v = M.ownRead(M.SHELF_SETTING)
    elseif sp ~= nil then
        local m = M.theme(sp).manifest
        v = (m and m.shelf) or read(M.SHELF_SETTING)
    else
        v = read(M.SHELF_SETTING)
    end
    if v == "light" or v == "dark" then return v end
    return "auto"
end

-- shelfLook() -> the same for the shelf on screen.
function M.shelfLook() return M.shelfLookOf(M._shelf) end

-- migrate(): the 5.3 betas "lent" a pack's wallpaper over the reader's own
-- (theme_wallpaper_pack); it is now an ordinary choice. Moved once.
function M.migrate()
    local pack = read("theme_wallpaper_pack")
    if type(pack) ~= "string" then return end
    for _i, e in ipairs(M.wallpaperEntries()) do
        if e.pack == pack then M.chooseWallpaper("wallpaper_default", e.name) end
    end
    save("theme_wallpaper_pack", nil)
end

function M.wallpaperPath(rest)
    local pack, file = tostring(rest):match("^([^\1]+)\1([^\1]+)$")
    if not pack then return nil end
    for _i, part in ipairs({ pack, file }) do
        if part:find("/", 1, true) or part:find("\\", 1, true) or part == "." or part == ".." then
            return nil
        end
    end
    local th = M.theme(pack)
    local path = th.dir and (th.dir .. "/" .. file) or nil
    if path and fs().attributes(path, "mode") == "file" then return path end
    return nil
end

function M.isDarkName(name)
    if type(name) ~= "string" then return false end
    local file = name:match("\1([^\1]+)$")
    local stem = file and file:match("^(.-)%.[^%.]+$")
    stem = stem and stem:lower()
    return stem == "wallpaper.dark" or stem == "wallpaper.full.dark"
end

return M
