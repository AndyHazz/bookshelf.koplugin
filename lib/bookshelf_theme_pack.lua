-- bookshelf_theme_pack.lua
-- Theme packs: an ornament pack's theme/ subfolder, and which pack's parts are
-- shown on each shelf.
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
-- A theme is a LAYER over the reader's own look, never written into it: see
-- THEMES ARE LAYERS below.
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

-- ── THEMES ARE LAYERS ───────────────────────────────────────────────────
-- The reader's own look is "mine": the wallpaper (+ full screen), the plank,
-- the colours, light or dark and the ornament collection, in their own
-- settings, which only their own menus write. A theme -- a pack, or the
-- built-in Plain -- is laid over it at paint time on the shelves that use
-- it, and replaces only the parts it has (maintainer, 2026-10-07). Choosing
-- a theme writes one key (library_theme, or a shelf's tab.theme) and nothing
-- else, so going back to the reader's own is always exact.
--
--   library_theme   nil (mine) | "plain" | a pack's folder
--   tab.theme       nil (same as the library) | "mine" | "plain" | a pack
--
-- Per shelf: its own choice, else the library's, else mine. Per part: the
-- theme's when it has one, else mine. Plain's parts are fixed: no wallpaper,
-- the built-in Oak, the default colours, no ornaments; light or dark follows
-- the reader's setting, as it does for mine and for a theme whose
-- theme.json does not say.
M.LIBRARY_SETTING = "library_theme"
M.MINE  = "mine"
M.PLAIN = "plain"
M.SHELF_SETTING = "shelf_theme"          -- CoverProgress.THEME_SETTING

-- mineName() -> what menus call the reader's own look. The ONE place the
-- name lives, so it can be renamed with a one-line change (maintainer).
function M.mineName() return _("My theme") end
function M.plainName() return _("Plain") end

-- A pack folder whose name is a built-in value, in any case ("Plain",
-- "mine", "NONE"), is never a theme: stored, it could not be told from the
-- built-in. Its pieces, wallpaper and planks are still the reader's to use.
M.RESERVED = { mine = true, plain = true, none = true }
function M.isReserved(pack)
    return type(pack) == "string" and M.RESERVED[pack:lower()] == true
end

-- normalise(v) -> a stored theme choice in today's terms, or nil (none
-- stored). rc/5.4 wrote "none" for the reader's own.
local function normalise(v)
    if v == "none" then return M.MINE end
    if v == M.MINE or v == M.PLAIN then return v end
    -- A pack named like a built-in (any case) is never a theme: unset.
    if M.isReserved(v) then return nil end
    if type(v) == "string" and v ~= "" then return v end
    return nil
end

-- usable(v) -> v, or nil when it names a pack that is gone. The stored name
-- is kept, so the theme comes back with its folder.
local function usable(v)
    v = normalise(v)
    if v == nil or v == M.MINE or v == M.PLAIN then return v end
    if M.isReserved(v) then return nil end
    if M.theme(v).exists then return v end
    return nil
end

-- packOf(theme) -> the pack a resolved theme is, or nil for mine and Plain.
local function packOf(theme)
    if theme == nil or theme == M.MINE or theme == M.PLAIN then return nil end
    return theme
end
M.packOf = packOf

-- themeName(choice) -> what menus call a theme choice.
function M.themeName(choice)
    choice = normalise(choice)
    if choice == nil or choice == M.MINE then return M.mineName() end
    if choice == M.PLAIN then return M.plainName() end
    if not M.theme(choice).exists then return T(_("%1 (missing)"), choice) end
    return M.displayName(choice)
end

-- choices() -> what a library or a shelf can wear, in menu order: the
-- reader's own, Plain, then every theme ({ value, label, help }).
function M.choices()
    local out = {
        { value = M.MINE, label = M.mineName() },
        { value = M.PLAIN, label = M.plainName(),
          help = _("No wallpaper, the oak plank, the default colors and no ornaments.") },
    }
    for _i, th in ipairs(M.allThemes()) do
        out[#out + 1] = { value = th.pack, help = th.description,
                          label = th.ornaments_only and T(_("%1 (ornaments only)"), th.name) or th.name }
    end
    return out
end

-- shelfChoices(cur) -> a shelf's theme list, in menu order: Same as library
-- ({ same = true }), a missing pack the shelf still names (cur), the
-- reader's own, Plain, every theme. ONE list for Theme > Each shelf, My
-- theme's "This shelf" row and Shelf style's Theme row.
function M.shelfChoices(cur)
    local out = { { same = true, label = _("Same as library") } }
    cur = normalise(cur)
    if packOf(cur) and not M.theme(cur).exists then
        out[#out + 1] = { value = cur, label = M.themeName(cur), missing = true }
    end
    for _i, c in ipairs(M.choices()) do out[#out + 1] = c end
    return out
end

-- shelfChoiceLabel(choice) -> how menus name a shelf's own choice:
-- "Same as library (Macabre)" when it follows the library.
function M.shelfChoiceLabel(choice)
    choice = normalise(choice)
    if choice == nil then return T(_("Same as library (%1)"), M.themeName(M.libraryChoice())) end
    return M.themeName(choice)
end

-- libraryChoice() -> what the library is set to ("mine" when unset), even a
-- pack that has gone; libraryTheme() -> what it shows.
function M.libraryChoice() return normalise(read(M.LIBRARY_SETTING)) or M.MINE end
function M.libraryTheme() return usable(read(M.LIBRARY_SETTING)) or M.MINE end

function M.setLibraryTheme(choice)
    choice = normalise(choice)
    if choice == M.MINE then choice = nil end
    save(M.LIBRARY_SETTING, choice)
    M._plank_memo = nil
end

-- ── THE SHELF ON SCREEN ─────────────────────────────────────────────────
-- The widget names the shelf before each build (setShelf); the lookups below
-- answer for that shelf. Nothing is written: a change of look only bumps the
-- settings generation, so the caches keyed on it are rebuilt.
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

-- inherited(id, read) -> the first answer `read(tab)` gives walking up from
-- `id` through its shelves of shelves: a sub-shelf with no theme of its own
-- wears the one its shelf of shelves wears (and so on up), before the
-- library's. A top-level shelf is the one step.
local function inherited(id, rd)
    local seen = {}
    for _i = 1, 32 do
        if id == nil or seen[id] then return nil end
        seen[id] = true
        local tab = tabFor(id)
        if not tab then return nil end
        local v = rd(tab)
        if v ~= nil then return v end
        id = tab.parent
    end
    return nil
end

-- shelfChoiceFor(id) -> nil (same as the library) | "mine" | "plain" | a
-- pack's folder: the tab's own choice (or its shelf of shelves').
function M.shelfChoiceFor(id)
    return inherited(id, function(tab) return normalise(tab.theme) end)
end

-- ownChoice(id) -> what that shelf itself is set to: nil (same as the
-- library), "mine", "plain" or a pack (not inherited).
function M.ownChoice(id)
    local tab = tabFor(id)
    return tab and normalise(tab.theme) or nil
end

-- themeFor(id) -> the theme that shelf shows: "mine", "plain" or a pack.
function M.themeFor(id)
    return usable(M.shelfChoiceFor(id)) or M.libraryTheme()
end

-- lookOf(id) -> "auto" | "light" | "dark" for that shelf: its theme's
-- manifest when it says, else the reader's own setting.
function M.lookOf(id)
    local p = packOf(M.themeFor(id))
    local m = p and M.theme(p).manifest
    local v = (m and m.shelf) or read(M.SHELF_SETTING)
    if v == "light" or v == "dark" then return v end
    return "auto"
end

-- current() -> the shelf on screen resolved ({ theme, look }), once per
-- settings generation: colour reads ask for it per cover at paint time. A
-- tab save, a theme or pack change all bump the generation, and the shelf
-- editor's live preview (an in-memory tab override, which saves nothing)
-- bumps the tab model's overrideGen; without a generation, no memo.
M._cur = nil
local function current()
    local s = store()
    local g = s and s.generation and s.generation()
    local TM = package.loaded["lib/bookshelf_tab_model"]
    local og = type(TM) == "table" and TM.overrideGen or 0
    local c = M._cur
    if g ~= nil and c and c.g == g and c.og == og and c.id == M._shelf then return c end
    c = { g = g, og = og, id = M._shelf, theme = M.themeFor(M._shelf), look = M.lookOf(M._shelf) }
    if g ~= nil then M._cur = c end
    return c
end

-- shelfTheme() -> the theme of the shelf on screen; shelfLook() its light
-- or dark.
function M.shelfTheme() return current().theme end
function M.shelfLook() return current().look end

-- hasPieces(pack) -> the pack holds ornaments.
function M.hasPieces(pack)
    local all = orn().listAll()
    for _i, e in ipairs(all or {}) do
        if e.pack == pack then return true end
    end
    return false
end

-- brings(theme, part) -> does that theme replace the reader's own part?
-- part: "wallpaper", "plank", "colours", "page" (the colour behind the
-- wallpaper), "look" (light or dark), "ornaments". theme defaults to the
-- shelf on screen's.
function M.brings(theme, part)
    theme = theme or M.shelfTheme()
    if theme == M.MINE then return false end
    if theme == M.PLAIN then return part ~= "look" end
    local th = M.theme(theme)
    if part == "wallpaper" then return th.wallpaper ~= nil end
    if part == "plank" then return #(th.planks or {}) > 0 end
    if part == "colours" then return th.colours ~= nil end
    if part == "page" then
        local c = th.colours
        return c ~= nil and (c.day.wallpaper_bg ~= nil or c.night.wallpaper_bg ~= nil)
    end
    if part == "look" then return th.manifest ~= nil and th.manifest.shelf ~= nil end
    if part == "ornaments" then return M.hasPieces(theme) end
    return false
end

-- ornamentsFor(id) -> what that shelf deals from: "mine" (the collection,
-- loose pieces included), "plain" (nothing) or a pack (its own pieces only:
-- themes do not mix, maintainer). A theme without pieces deals the reader's.
function M.ornamentsFor(id)
    local th = M.themeFor(id)
    if th == M.PLAIN then return M.PLAIN end
    if th ~= M.MINE and M.hasPieces(th) then return th end
    return M.MINE
end

-- anyShelfTheme() -> true when an enabled shelf has a theme of its own
-- (what keeps a second wallpaper decoded, bookshelf_wallpaper.bg).
M._tabs_list = nil   -- seam: fn() -> the enabled tabs
function M.anyShelfTheme()
    local list
    if M._tabs_list then list = M._tabs_list()
    else
        local ok, TabModel = pcall(require, "lib/bookshelf_tab_model")
        local ok2, l = pcall(function() return ok and TabModel.getActive() end)
        list = ok2 and l or nil
    end
    for _i, t in ipairs(list or {}) do
        if t.enabled ~= false and normalise(t.theme) ~= nil then return true end
    end
    return false
end

-- shelfKey() -> the theme of the shelf on screen, as a cache key (the plank
-- memo, the ornament plan).
function M.shelfKey() return "t:" .. tostring(M.shelfTheme()) end

-- lookKey() -> what the shelf on screen actually shows: its wallpaper (both
-- views), colours, plank and light/dark. Two shelves with different
-- choices can look the same (a theme of ornaments only over the reader's
-- own); only a different look is worth a full-screen repaint, ~350ms on a
-- PW5. Light/dark as it RESOLVES: Auto is whatever the device shows now.
M._autoDark = nil   -- seam: fn() -> true when Auto resolves to dark
local function autoDark()
    if M._autoDark then return M._autoDark() == true end
    local ok, Sync = pcall(require, "lib/bookshelf_night_mode_sync")
    local ok_d, Device = pcall(require, "device")
    if not (ok and Sync and Sync.active and ok_d and Device and Device.screen) then return false end
    local ok2, dark = pcall(Sync.active, Device.screen)
    return ok2 and dark == true
end

function M.lookKey()
    local plank = M.activePlank()
    local look = M.shelfLook()
    if look == "auto" then look = autoDark() and "dark" or "light" end
    return table.concat({
        tostring(M.shownWallpaper(false, false)), tostring(M.shownWallpaper(true, false)),
        tostring(M.coloursSource()), tostring(plank and plank.id), look,
    }, "\2")
end

-- setShelf(id) -> true when the shelf on screen now LOOKS different: then
-- the settings generation is bumped, so the caches keyed on it rebuild.
M._look_key = nil
function M.setShelf(id)
    M._shelf = id
    M._shelf_key = M.shelfKey()
    local look = M.lookKey()
    if M._look_key == nil then
        -- The first shelf: anything read before it was read as the
        -- library's, so compare with the library's look.
        M._shelf = nil
        M._look_key = M.lookKey()
        M._shelf = id
    end
    if look == M._look_key then return false end
    M._look_key = look
    local s = store()
    if s and s.bump then s.bump() end
    return true
end

-- displayName(pack) -> what menus call a theme: its manifest's name, else
-- its folder's. Every pack is a theme since 5.4 (maintainer, 2026-10-03).
function M.displayName(pack)
    local m = pack and M.theme(pack).manifest
    return (m and m.name) or pack
end

-- allThemes() -> every pack as a theme: theme packs (a theme.json) by name,
-- then the others by folder; ornaments_only when a pack truly has nothing
-- but ornaments (no wallpaper, plank or colours). Switched-off packs too:
-- the collection's switches shape the reader's own ornaments, not themes. A
-- pack with neither a theme.json nor an ornament (a pack of planks) is not a
-- theme: its planks are in the plank picker (maintainer, 2026-10-04).
function M.allThemes()
    local all, packs = orn().listAll()
    local has_piece = {}
    for _i, e in ipairs(all or {}) do
        if e.pack then has_piece[e.pack] = true end
    end
    local full, plain = {}, {}
    for _i, p in ipairs(packs or {}) do
        local th = M.theme(p)
        local m = th.manifest
        if M.isReserved(p) then
            if not M._reserved_warned then
                M._reserved_warned = true
                logger.warn("[bookshelf] a pack folder named like a built-in theme is not listed as a theme:", p)
            end
        elseif m then
            full[#full + 1] = { pack = p, name = m.name or p, description = m.description,
                                ornaments_only = false }
        elseif has_piece[p] then
            local only = not (th.wallpaper or th.colours or #(th.planks or {}) > 0)
            plain[#plain + 1] = { pack = p, name = p, ornaments_only = only }
        end
    end
    local function byName(a, b) return a.name:lower() < b.name:lower() end
    table.sort(full, byName); table.sort(plain, byName)
    for _i, e in ipairs(plain) do full[#full + 1] = e end
    return full
end

-- rescan(): forget the theme folders' scan, so a pack copied in or deleted
-- since the last look (or a theme.json added to one) is seen now, not after
-- the scan TTL. The Theme menu calls it each time it opens. Not the
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
-- coloured plank.
--
-- Cached for the scan TTL: it is asked on every shelf build, a page turn bumps
-- the settings generation, and answering means listing the ornaments folder.
-- A choice (choosePlank, invalidate) drops the answer at once.
M._plank_memo = nil
function M.activePlank()
    if not M.designsOn() then return nil end
    return M.chosenPlank()
end

-- chosenPlank() -> the plank design the shelf on screen shows, whether or not
-- designs are switched on (what Performance tweaks names): Plain's Oak, a
-- theme's plank when it has one, else the reader's own choice. The memo is
-- per shelf theme.
function M.chosenPlank()
    local now = M._clock()
    local key = M.shelfKey()
    local memo = M._plank_memo
    if memo and memo.key == key and M.SCAN_TTL > 0 and (now - memo.at) < M.SCAN_TTL then
        return memo.v
    end
    local v
    local th = M.shelfTheme()
    local p = packOf(th)
    if th == M.PLAIN then
        v = M.builtinPlank()
    elseif p and #(M.theme(p).planks or {}) > 0 then
        v = M.themePlank(p)
    else
        v = M.minePlank()
    end
    M._plank_memo = { at = now, v = v, key = key }
    return v
end

-- minePlank() -> the reader's own plank design, or nil for the colour.
function M.minePlank()
    local c = M.plankChoice()
    if c == "oak" then return M.builtinPlank() end
    if c ~= "colour" then return M._packPlank(c) end
    return nil
end

-- Plank designs on or off (Settings > Advanced > Performance tweaks): a
-- design costs a black and white Kindle ~35ms on each spine-shelf tap (its
-- shadow is blended onto the screen), and Oak is on by default, so it gets a
-- switch there (maintainer). Off draws Bookshelf's own plank colour. It never
-- stops a reader choosing a plank: choosing one switches designs back on.
-- A preference of the device, not of a look: themes never touch it.
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
-- its pack: only by the plank picker (maintainer).

-- _packPlank(id) -> that pack plank, when its pack is there. The collection's
-- pack switches do not matter: they shape ornaments only.
function M._packPlank(id)
    local _all, packs = orn().listAll()
    for _i, p in ipairs(packs or {}) do
        for _j, pl in ipairs(M.theme(p).planks or {}) do
            if pl.id == id then return pl end
        end
    end
    return nil
end

local function fallbackChoice()
    local wood = read(M.WOOD_SETTING)
    if wood == "oak" then return "oak" end
    if wood == false then return "colour" end
    if read("spine_plank_color") ~= nil or read("spine_plank_color_night") ~= nil then
        return "colour"
    end
    return "oak"
end

-- plankChoice() -> "colour" | "oak" | a pack plank's id: the reader's own
-- (a pack plank whose pack is gone reads as the fallback, and comes back
-- with the pack).
function M.plankChoice()
    local v = read(M.PLANK_SETTING)
    if v == false then return "colour" end
    if v == "oak" then return "oak" end
    if type(v) == "string" and M._packPlank(v) then return v end
    return fallbackChoice()
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

-- plankRowLabel() -> the reader's own plank as the Plank row and
-- Performance tweaks name it: "Oak", "Walnut (Planks pack)", or nil for the
-- plain colour (the caller shows the colour's value).
function M.plankRowLabel()
    local p = M.minePlank()
    if not p then return nil end
    if p.pack and p.name then return T(_("%1 (%2 pack)"), p.name, p.pack) end
    return M.plankLabel(p)
end

-- plankOptions() -> the plank picker's entries, in order: the colour, Oak,
-- then each pack's planks (packs A-Z).
function M.plankOptions()
    local out = { { kind = "colour" }, { kind = "oak", plank = M.builtinPlank() } }
    local _all, packs = orn().listAll()
    local sorted = {}
    for _i, p in ipairs(packs or {}) do sorted[#sorted + 1] = p end
    table.sort(sorted)
    for _i, p in ipairs(sorted) do
        local pls = {}
        for _j, pl in ipairs(M.theme(p).planks or {}) do pls[#pls + 1] = pl end
        table.sort(pls, function(a, b) return (a.name or "") < (b.name or "") end)
        for _j, pl in ipairs(pls) do
            out[#out + 1] = { kind = "pack", pack = p, plank = pl }
        end
    end
    return out
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

-- invertHex("#RRGGBB") -> its negative, same shape. What
-- bookshelf_color.invertValue does for a hex value; kept here because a pack
-- only ever lends "#RRGGBB" and this module must load without Blitbuffer.
function M.invertHex(hex)
    local r, g, b = hex:match("^#(%x%x)(%x%x)(%x%x)$")
    if not r then return hex end
    return string.format("#%02X%02X%02X", 255 - tonumber(r, 16),
                         255 - tonumber(g, 16), 255 - tonumber(b, 16))
end

-- coloursSource() -> whose colours the shelf on screen paints: "mine",
-- "plain" (the defaults) or a pack with a colours.json.
function M.coloursSource()
    local th = M.shelfTheme()
    if th == M.MINE or th == M.PLAIN then return th end
    if M.theme(th).colours then return th end
    return M.MINE
end

-- defaultColours() -> true when the shelf on screen paints the default
-- colours whatever the reader has set (Plain). The colour readers
-- (CoverProgress, the chip bar, the page ground) ask before reading the keys.
function M.defaultColours() return M.coloursSource() == M.PLAIN end

-- packColour(pack, key, dark) -> that pack's colour for that setting in the
-- STORED convention of its slot, or nil. Night slots hold colours
-- pre-inverted for a frame that will flip (see bookshelf_color.invertValue);
-- the plank is the one exception, kept in display space in both.
local function packColour(pack, key, dark)
    local c = M.theme(pack).colours
    local set = c and (dark and c.night or c.day)
    local hex = set and set[key]
    if not hex then return nil end
    if dark and key ~= "spine_plank_color" then hex = M.invertHex(hex) end
    return { hex = hex }
end

-- colourOverride(key, dark) -> the shelf on screen's theme colour for that
-- setting, or nil for the reader's own.
function M.colourOverride(key, dark)
    local src = M.coloursSource()
    if src == M.MINE or src == M.PLAIN then return nil end
    return packColour(src, key, dark)
end

-- A pack's wallpaper travels under a NAME, like every other wallpaper, so
-- Wallpaper.bg's cache and the widget's plumbing need no second path. The
-- prefix cannot collide with a file name (it carries a control character) and
-- Wallpaper.pathFor hands names carrying it to wallpaperPath.
M.NAME_PREFIX = "theme-pack\1"

function M.isPackName(name)
    return type(name) == "string" and name:sub(1, #M.NAME_PREFIX) == M.NAME_PREFIX
end

-- wallpaperEntries() -> every pack's wallpaper as a choice for the wallpaper
-- picker ({name, label, pack, path}). The name is the base file's: the
-- view's variant is picked at paint time.
function M.wallpaperEntries()
    local _all, packs = orn().listAll()
    local out = {}
    for _i, p in ipairs(packs or {}) do
        local th = M.theme(p)
        local file = th.wallpaper and th.wallpaper.base
        if file then
            out[#out + 1] = { name = M.NAME_PREFIX .. p .. "\1" .. file, label = p, pack = p,
                              path = th.dir .. "/" .. file }
        end
    end
    return out
end

-- variantName(name, is_full, is_dark) -> for a pack wallpaper's name, that
-- pack's wallpaper for this view (full screen, dark), or nil when its pack
-- is gone; any other name is returned as it is.
function M.variantName(name, is_full, is_dark)
    if not M.isPackName(name) then return name end
    local pack = name:sub(#M.NAME_PREFIX + 1):match("^([^\1]+)\1")
    local th = pack and M.theme(pack)
    if not (th and th.exists and th.wallpaper) then return nil end
    local file = M.wallpaperFile(th.wallpaper, is_full, is_dark)
    return file and (M.NAME_PREFIX .. pack .. "\1" .. file) or nil
end

-- mineWallpaper(is_full, is_dark) -> the reader's own wallpaper name for
-- this view. Full screen: None stays None; its own choice wins, else
-- whatever the wallpaper shows ("Same"). A pack's picture chosen as the
-- reader's own shows as that pack's variant for the view.
function M.mineWallpaper(is_full, is_dark)
    local function layer(key, full_view)
        local v = read(key)
        if M.isPackName(v) then return M.variantName(v, full_view, is_dark) end
        return (type(v) == "string" and v ~= "") and v or nil
    end
    if is_full then
        if read("wallpaper_full") == false then return nil end
        local n = layer("wallpaper_full", true)
        if n then return n end
    end
    return layer("wallpaper_default", is_full)
end

-- shownWallpaper(is_full, is_dark) -> the wallpaper name the shelf on
-- screen shows in this view: Plain's none, a theme's own (full screen None
-- stays None: a view preference), else the reader's own.
function M.shownWallpaper(is_full, is_dark)
    local th = M.shelfTheme()
    if th == M.PLAIN then return nil end
    local p = packOf(th)
    local w = p and M.theme(p).wallpaper
    if w then
        if is_full and read("wallpaper_full") == false then return nil end
        local file = M.wallpaperFile(w, is_full, is_dark)
        if file then return M.NAME_PREFIX .. p .. "\1" .. file end
    end
    return M.mineWallpaper(is_full, is_dark)
end

-- ── MIGRATION (once, at start-up) ───────────────────────────────────────
-- 5.3 and the rc/5.4 builds APPLIED a theme: choosing one wrote its parts
-- into the reader's own settings and kept the old values in theme_applied.
-- Now the reader's own look is never written by a theme, so (maintainer,
-- 2026-10-07):
--   1. theme_applied for pack P: every part and pack switch still as the
--      theme left them -> the library wears P and the reader's own look is
--      put back from the record; anything changed on top -> the settings
--      stay as shown (the reader's own now holds what was on screen) and
--      the library wears none. The record goes.
--   2. theme_colours_pack Q (a Color theme): Q's colours are written into
--      the colour keys, as they were shown, and the key goes.
--   3. wallpaper_* naming a pack's picture stays the reader's choice; if it
--      was not showing (its pack off or gone), the reader's own picture from
--      before it (_own) takes its place. _own goes.
--   4. rc/5.4 tabs: theme "none" -> "mine", theme_look dropped.
-- Idempotent, and guarded by a version so it runs once.
M.MIGRATION_SETTING = "theme_model"
M.MIGRATION_VERSION = 1
M.APPLIED_SETTING   = "theme_applied"
M.COLOURS_SETTING   = "theme_colours_pack"
M._tabmodel = nil   -- seam: the tab model ({ load, save })

-- A saved nil in the old record, which a settings table cannot hold as a value.
local NIL_MARK = "\0nil"
local function dec(v) if v == NIL_MARK then return nil end return v end

local function migrateApplied()
    local s = read(M.APPLIED_SETTING)
    if s == nil then return end
    save(M.APPLIED_SETTING, nil)
    if type(s) ~= "table" or type(s.before) ~= "table" or type(s.applied) ~= "table" then return end
    local pack = s.pack
    -- Gone, or a folder named like a built-in (never a theme now): the
    -- settings stay as shown.
    if not (type(pack) == "string" and M.theme(pack).exists) or M.isReserved(pack) then return end
    local O = orn()
    local _all, packs = O.listAll()
    -- Plank designs on or off is the device's preference now, not a part of
    -- the look: neither compared nor put back.
    local held = true
    for k, a in pairs(s.applied) do
        if k ~= M.DESIGNS_OFF_SETTING and read(k) ~= dec(a) then held = false end
    end
    local packs_applied = type(s.packs_applied) == "table" and s.packs_applied or nil
    if held and packs_applied then
        for _i, p in ipairs(packs or {}) do
            if (O.isPackOff(p) == true) ~= (packs_applied[p] == true) then held = false end
        end
    end
    if not held then return end
    for k in pairs(s.applied) do
        if k ~= M.DESIGNS_OFF_SETTING then save(k, dec(s.before[k])) end
    end
    if packs_applied then
        local before = type(s.packs_before) == "table" and s.packs_before or {}
        for _i, p in ipairs(packs or {}) do O.setPackOff(p, before[p] == true) end
    end
    save(M.LIBRARY_SETTING, pack)
end

local function migrateColours()
    local q = read(M.COLOURS_SETTING)
    if q == nil then return end
    save(M.COLOURS_SETTING, nil)
    if type(q) ~= "string" or q == "" then return end
    local th = M.theme(q)
    -- Only what was on screen: a pack that was off or gone lent nothing.
    if not (th.exists and th.colours) or orn().isPackOff(q) then return end
    for _i, look in ipairs({ "day", "night" }) do
        local dark = look == "night"
        for key in pairs(th.colours[look]) do
            save(key .. (dark and "_night" or ""), packColour(q, key, dark))
        end
    end
end

local function migrateWallpaper(key)
    local own = read(key .. "_own")
    if own ~= nil then save(key .. "_own", nil) end
    local v = read(key)
    if not M.isPackName(v) then return end
    local pack = v:sub(#M.NAME_PREFIX + 1):match("^([^\1]+)\1")
    local th = pack and M.theme(pack)
    local showing = th and th.exists and th.wallpaper and not orn().isPackOff(pack)
    if showing then return end
    if type(own) == "string" and own ~= "" and not M.isPackName(own) then
        save(key, own)
    elseif not (th and th.exists and th.wallpaper) then
        save(key, nil)            -- its pack is gone: it showed nothing
    end
end

local function migrateTabs()
    local TabModel = M._tabmodel
    if not TabModel then
        local ok, TM = pcall(require, "lib/bookshelf_tab_model")
        TabModel = ok and TM or nil
    end
    if not (TabModel and TabModel.load and TabModel.save) then return end
    local tabs = TabModel.load()
    local changed = false
    for _i, t in ipairs(tabs or {}) do
        if t.theme == "none" then t.theme = M.MINE; changed = true end
        if t.theme_look ~= nil then t.theme_look = nil; changed = true end
    end
    -- Saved only when something changed: TabModel.load hands an untouched
    -- reader the DEFAULTS, and saving them would freeze them.
    if changed then TabModel.save(tabs) end
end

function M.migrate()
    local v = read(M.MIGRATION_SETTING)
    if type(v) == "number" and v >= M.MIGRATION_VERSION then return end
    local O = orn()
    local own_defer = O.beginDeferred ~= nil and not O._defer
    if own_defer then O.beginDeferred() end
    local ok, err = pcall(function()
        -- The 5.3 betas "lent" a pack's wallpaper (theme_wallpaper_pack).
        local beta = read("theme_wallpaper_pack")
        if beta ~= nil then
            save("theme_wallpaper_pack", nil)
            for _i, e in ipairs(M.wallpaperEntries()) do
                if e.pack == beta then save("wallpaper_default", e.name) end
            end
        end
        migrateApplied()
        migrateColours()
        migrateWallpaper("wallpaper_default")
        migrateWallpaper("wallpaper_full")
        migrateTabs()
    end)
    if own_defer then O.endDeferred() end
    if not ok then
        logger.warn("[bookshelf] theme migration failed:", tostring(err))
        return
    end
    save(M.MIGRATION_SETTING, M.MIGRATION_VERSION)
    M._plank_memo = nil
    M._cur = nil
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
