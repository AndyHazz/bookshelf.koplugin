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
--                                           "dark", "plank": a plank's name,
--                                           "hero": the piece its card in the
--                                           Theme library shows (file stem)}
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

-- The panel options a theme.json may set (5.4, maintainer 2026-10-09:
-- "macabre looks best with light transparency and blur off"), each optional:
--   "panel_shading": a level name as the Panel shading menu shows it, in
--                    lower case: "transparent", "low", "moderate", "heavy",
--                    "solid"; or a number from 0 (transparent) to 1 (solid)
--   "panel_blur":    true or false, Blur wallpaper behind panels
--   "covers_panel":  true or false, Panel behind Covers shelves
-- Anything else is ignored, so the shelf keeps Custom theme's. The values are
-- Settings.SCRIM_LEVELS' (a test keeps the two the same).
M.SHADING_LEVELS = { transparent = 0, low = 0.35, moderate = 0.6, heavy = 0.85, solid = 1 }
-- shadingValue(v) -> 0..1 for a theme.json panel_shading, or nil.
function M.shadingValue(v)
    if type(v) == "string" then v = M.SHADING_LEVELS[v:lower()] end
    if type(v) ~= "number" or v ~= v then return nil end
    if v < 0 then return 0 end
    if v > 1 then return 1 end
    return v
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
    local function bool(k)
        if type(doc[k]) == "boolean" then return doc[k] end
        return nil
    end
    return { name = str("name"), description = str("description"), shelf = shelf, plank = str("plank"),
             hero = str("hero"), panel_shading = M.shadingValue(doc.panel_shading),
             panel_blur = bool("panel_blur"), covers_panel = bool("covers_panel") }
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

function M.invalidate() M._cache = {}; M._plank_memo = nil; M._cur = nil end
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
--   theme_edits     { [a pack's folder, or "plain"] = the reader's edits to
--                   that theme }: see EDITABLE THEMES below
--
-- Per shelf: its own choice, else the library's, else mine. Per part: the
-- reader's edit to that theme, else the theme's when it has one, else mine.
-- Plain's parts are fixed: no wallpaper, the built-in Oak, the default
-- colours, no ornaments; light or dark follows the reader's setting, as it
-- does for mine and for a theme whose theme.json does not say.
M.LIBRARY_SETTING = "library_theme"
M.MINE  = "mine"
M.PLAIN = "plain"
M.SHELF_SETTING = "shelf_theme"          -- CoverProgress.THEME_SETTING

-- mineName() -> what menus call the reader's own look. The ONE place the
-- name lives, so it can be renamed with a one-line change (maintainer).
-- "Custom theme", not "My theme" (maintainer, 2026-10-09); the id stays
-- "mine".
function M.mineName() return _("Custom theme") end

-- addThemeLabel() / showAddThemeInfo(): the "Add theme pack..." row that ends
-- every list of themes (the Theme library, wherever it is opened from;
-- maintainer, 2026-10-07) and the popup it opens: where theme packs go, that
-- any theme can be edited and reset (maintainer, 2026-10-09, as Bookends'
-- gallery says presets can be edited freely once installed), and where to
-- get packs. The shop link is a parameter, not part of the msgid, so a
-- translation cannot break it.
function M.addThemeLabel() return _("Add theme pack\xE2\x80\xA6") end
function M.showAddThemeInfo()
    local UIManager = require("ui/uimanager")
    local InfoMessage = require("ui/widget/infomessage")
    local T = require("ffi/util").template
    -- A findable path: the settings dir can be relative.
    local dir = require("lib/bookshelf_ornaments").dir() or "?"
    local ok, util = pcall(require, "ffi/util")
    local real = ok and util.realpath and util.realpath(dir)
    UIManager:show(InfoMessage:new{
        text = T(_("A theme pack brings a wallpaper, a plank, colors and ornaments together, and is chosen here. To add one, copy its folder into\n%1\nthen open the Theme library again.\n\nYou can edit any theme freely; your changes stay with it, and Reset brings back the original.\n\nReady-made theme packs:\n%2"),
            real or dir, "ko-fi.com/andyhazz/shop"),
    })
end
function M.plainName() return _("Plain") end

-- A pack folder whose name is a built-in value, in any case ("Plain",
-- "mine", "NONE"), is never a theme: stored, it could not be told from the
-- built-in. Its pieces, wallpaper and planks are still the reader's to use.
-- "none" and "own" were ids of unreleased builds; still reserved, and a
-- stored one reads as unset.
M.RESERVED = { mine = true, plain = true, none = true, own = true }
function M.isReserved(pack)
    return type(pack) == "string" and M.RESERVED[pack:lower()] == true
end

-- normalise(v) -> a stored theme choice, or nil (none stored, or no theme).
local function normalise(v)
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

-- choiceList(cur, shelf, scan) -> the Theme library's list, in order: for a
-- shelf (shelf true) Default theme ({ same = true }, stores nothing), then a
-- missing pack still chosen (cur; { value, missing = true }), Custom theme,
-- Plain, every theme by name ({ value }). The cards name them (choiceLabel,
-- themeName) and say what each brings (bookshelf_theme_library). scan
-- (optional): the ornament scan the caller already holds (allThemes).
function M.choiceList(cur, shelf, scan)
    local out = {}
    if shelf then out[1] = { same = true } end
    cur = normalise(cur)
    if packOf(cur) and not M.theme(cur).exists then out[#out + 1] = { value = cur, missing = true } end
    out[#out + 1] = { value = M.MINE }
    out[#out + 1] = { value = M.PLAIN }
    for _i, th in ipairs(M.allThemes(scan)) do out[#out + 1] = { value = th.pack } end
    return out
end

-- choiceLabel(choice) -> what a shelf's choice is called: "Default theme"
-- while it follows the default (nil; "Default", not "library", the Theme
-- library's own name, maintainer 2026-10-09), else the theme's name.
function M.choiceLabel(choice)
    if choice == nil then return _("Default theme") end
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

-- lookOf(id) -> "auto" | "light" | "dark" for that shelf: the reader's edit
-- to its theme, else its theme's manifest when it says, else the reader's
-- own setting (themePart).
function M.lookOf(id)
    local v = M.themePart(M.themeFor(id), M.SHELF_SETTING)
    if v == "light" or v == "dark" then return v end
    return "auto"
end

-- current() -> the shelf on screen resolved ({ theme, look }), once per
-- settings generation: colour reads ask for it per cover at paint time. A
-- tab save, a theme or pack change all bump the generation; without a
-- generation, no memo.
M._cur = nil
local function current()
    local s = store()
    local g = s and s.generation and s.generation()
    local c = M._cur
    if g ~= nil and c and c.g == g and c.id == M._shelf then return c end
    local theme = M.themeFor(M._shelf)
    local e = M.editsOf(theme)
    c = { g = g, id = M._shelf, theme = theme, look = M.lookOf(M._shelf),
          -- The reader's edits to that theme (EDITABLE THEMES), and whether
          -- they touch a colour: the colour readers ask per cover.
          e = e, ecol = e ~= nil and M.editsColours(e) }
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

-- ornamentsFor(id) -> what that shelf deals from: "mine" (the collection,
-- loose pieces included), "plain" (nothing) or a pack (its own pieces only:
-- themes do not mix, maintainer). A theme without pieces deals the reader's.
-- A theme whose ornaments the reader has edited deals its edited set
-- (poolOf: a table, bookshelf_ornaments.listFor).
function M.ornamentsFor(id) return M.poolOf(M.themeFor(id)) end

-- poolOf(theme) -> what a shelf showing that theme deals from, as above.
function M.poolOf(theme)
    if theme == nil or theme == M.MINE then return M.MINE end
    local e = M.editsOf(theme)
    if e and type(e.pieces) == "table" then return M.editPoolOf(theme, e) end
    if theme == M.PLAIN then return M.PLAIN end
    if M.hasPieces(theme) then return theme end
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
-- memo, the ornament plan). A theme whose ornaments are edited adds its
-- pool's key, so switching a piece is a new key; an edit to another part
-- keeps it, and the pages keep their ornaments.
function M.shelfKey()
    local c = current()
    local k = "t:" .. tostring(c.theme)
    if c.e and type(c.e.pieces) == "table" then k = k .. "|" .. M.editPoolOf(c.theme, c.e).key end
    return k
end

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

-- NOT the edits' count: an edit is a settings write, which bumps the
-- generation itself, so every memo keyed on it follows; in the key, every
-- colour nudge on a pack's shelf was a full-screen flash (review, 2026-10-09).
-- A theme with edited colours paints its own (coloursSource names it), so
-- two themes still tell apart; two shelves on one theme share the key.
-- coloursSource() -> whose colours the shelf on screen paints: "mine",
-- "plain" (the defaults) or a pack with a colours.json, or with colours the
-- reader has edited. Part of the look's key.
function M.coloursSource()
    local c = current()
    local th = c.theme
    if th == M.MINE or th == M.PLAIN then return th end
    if M.theme(th).colours or c.ecol then return th end
    return M.MINE
end

-- lookParts() -> the look but its colours, and whose colours it paints
-- with how its panels are shaded. The panels go with the colours: two
-- shelves that differ only there still bump the generation when one follows
-- the other (the ground memo and the plates read them), and an edit to one is
-- a colour-like change on screen, never a full-screen flash per tap.
local function lookParts()
    local plank = M.activePlank()
    local look = M.shelfLook()
    if look == "auto" then look = autoDark() and "dark" or "light" end
    local P = M.PANEL_KEYS
    return table.concat({
        tostring(M.shownWallpaper(false, false)), tostring(M.shownWallpaper(true, false)),
        tostring(plank and plank.id), look,
    }, "\2"), table.concat({
        tostring(M.coloursSource()),
        tostring(M.partRead(P.shading)), tostring(M.partRead(P.buttons) == true),
        tostring(M.partRead(P.blur) == true), tostring(M.partRead(P.covers) == true),
    }, "\2")
end
function M.lookKey()
    local rest, colours = lookParts()
    return rest .. "\2" .. colours
end

-- setShelf(id) -> true when the shelf on screen now LOOKS different, worth a
-- full-screen refresh. A different look bumps the settings generation, so
-- the caches keyed on it rebuild. An edit on screen that only changes whose
-- colours paint (a pack without a colours.json gets its first edited
-- colour, or loses its last) bumps it too, but is a colour change like any
-- other: no full-screen refresh, as on a Custom theme shelf.
M._look_key = nil
M._look_at = nil      -- { id, theme, rest }: what the last key was taken for
function M.setShelf(id)
    M._shelf = id
    local rest, colours = lookParts()
    local look = rest .. "\2" .. colours
    if M._look_key == nil then
        -- The first shelf: anything read before it was read as the
        -- library's, so compare with the library's look.
        M._shelf = nil
        M._look_key = M.lookKey()
        M._shelf = id
    end
    local prev, theme = M._look_at, M.shelfTheme()
    M._look_at = { id = id, theme = theme, rest = rest }
    if look == M._look_key then return false end
    M._look_key = look
    local s = store()
    if s and s.bump then s.bump() end
    if prev and prev.id == id and prev.theme == theme and prev.rest == rest then return false end
    return true
end

-- displayName(pack) -> what menus call a theme: its manifest's name, else
-- its folder's. Every pack is a theme since 5.4 (maintainer, 2026-10-03).
function M.displayName(pack)
    local m = pack and M.theme(pack).manifest
    return (m and m.name) or pack
end

-- allThemes() -> every pack as a theme, ONE alphabetical list by the name
-- menus show (a theme.json's name, else the folder's), whether or not it has
-- a theme.json (maintainer, 2026-10-08: Autumn, a pack of ornaments, came
-- after Ukiyo-e). Case-insensitive, by byte, so the order is the same in
-- every locale; a tie goes by folder. Switched-off packs too:
-- the collection's switches shape the reader's own ornaments, not themes. A
-- pack with neither a theme.json nor an ornament (a pack of planks) is not a
-- theme: its planks are in the plank picker (maintainer, 2026-10-04).
-- scan (optional): { all, packs }, the ornament scan the caller holds (the
-- Theme library takes one per open): listAll walks every folder each time
-- it is asked, ~28ms on a PW5.
function M.allThemes(scan)
    local all, packs
    if scan then all, packs = scan.all, scan.packs else all, packs = orn().listAll() end
    local has_piece = {}
    for _i, e in ipairs(all or {}) do
        if e.pack then has_piece[e.pack] = true end
    end
    local out = {}
    for _i, p in ipairs(packs or {}) do
        local th = M.theme(p)
        local m = th.manifest
        if M.isReserved(p) then
            if not M._reserved_warned then
                M._reserved_warned = true
                logger.warn("[bookshelf] a pack folder named like a built-in theme is not listed as a theme:", p)
            end
        elseif m then
            out[#out + 1] = { pack = p, name = m.name or p, description = m.description }
        elseif has_piece[p] then
            out[#out + 1] = { pack = p, name = p }
        end
    end
    table.sort(out, function(a, b)
        local x, y = a.name:lower(), b.name:lower()
        if x ~= y then return x < y end
        return a.pack < b.pack
    end)
    return out
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
-- designs are switched on (what Performance tweaks names): the reader's edit
-- to its theme, else Plain's Oak, a theme's plank when it has one, else the
-- reader's own choice (themePart). The memo is per shelf theme; an edit
-- drops it.
function M.chosenPlank()
    local now = M._clock()
    local key = M.shelfKey()
    local memo = M._plank_memo
    if memo and memo.key == key and M.SCAN_TTL > 0 and (now - memo.at) < M.SCAN_TTL then
        return memo.v
    end
    local v = M.plankIn(M.shelfTheme())
    M._plank_memo = { at = now, v = v, key = key }
    return v
end

-- plankIn(theme): the plank design that theme shows (nil: the reader's
-- own), or nil for the colour; minePlank() the reader's own.
function M.plankIn(theme)
    local c = M.plankChoiceIn(theme)
    if c == "oak" then return M.builtinPlank() end
    if c ~= "colour" then return M._packPlank(c) end
    return nil
end
function M.minePlank() return M.plankIn(nil) end

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

-- plankChoiceIn(theme): "colour" | "oak" | a pack plank's id: what that
-- theme shows (nil: the reader's own). A pack plank whose pack is gone reads
-- as the fallback, and comes back with the pack. plankChoice() is the theme
-- being edited (the seam, partRead).
function M.plankChoiceIn(theme)
    local v = M.themePart(theme, M.PLANK_SETTING)
    if v == false then return "colour" end
    if v == "oak" then return "oak" end
    if type(v) == "string" and M._packPlank(v) then return v end
    return fallbackChoice()
end
function M.plankChoice() return M.plankChoiceIn(M.shelfTheme()) end

-- choosePlank(choice): the reader's pick, for the theme being edited.
-- Choosing a design shows it, even with designs off (Performance tweaks);
-- choosing the colour does not touch that switch.
function M.choosePlank(choice)
    -- Not `and false or choice`: false is falsy, so that saved the word.
    local v = choice
    if choice == "colour" then v = false end
    M.partSave(M.PLANK_SETTING, v)
    -- Folded into the one choice; the reader's own only.
    if M.shelfTheme() == M.MINE then save(M.WOOD_SETTING, nil) end
    if choice ~= "colour" and not M.designsOn() then M.setDesignsOn(true) end
    M._plank_memo = nil
end

-- plankRowLabel(): the plank of the theme being edited as the Plank row
-- and Performance tweaks name it: "Oak", "Walnut (Planks pack)", "Walnut
-- (missing)" for an edit to a theme naming a plank whose pack has gone, or
-- nil for the plain colour (the caller shows the colour's value).
function M.plankRowLabel()
    local th = M.shelfTheme()
    local stored = M.partEdited(M.PLANK_SETTING) and M.partRead(M.PLANK_SETTING)
    if type(stored) == "string" and stored ~= "oak" and not M._packPlank(stored) then
        return T(_("%1 (missing)"), stored:match("plank%.([^/]+)$") or stored:match("^([^/]+)") or stored)
    end
    local p = M.plankIn(th)
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

-- colour(key) -> the colour the shelf on screen PAINTS for a colour setting
-- (key with its slot's suffix, "ink_color_night"), in the stored shape, or
-- nil for the default. THE one resolver every colour reader asks (the
-- palette, the hero and list bars, the selected shelf, the page ground) and
-- what the colour rows show and edit: the reader's edit to the theme on
-- screen (unset is the default), else the theme's own (Plain's defaults, a
-- pack's colours.json), else Custom theme's (partRead). Asked per cover at
-- paint, so memoised on the shelf's resolution, which a new settings
-- generation, an edit or a rescan replaces: a page of covers reads the
-- settings once a key, not once a cover.
local NONE = {}
function M.colour(key)
    local c = current()
    local memo = c.colours
    if not memo then memo = {}; c.colours = memo end
    local v = memo[key]
    if v == nil then
        v = M.partRead(key)
        memo[key] = (v == nil) and NONE or v
        return v
    end
    if v == NONE then return nil end
    return v
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

-- mineWallpaper(is_full, is_dark, theme): the reader's own wallpaper name
-- for this view (theme: what that theme shows instead, themePart). Full
-- screen: None stays None; its own choice wins, else whatever the wallpaper
-- shows ("Same"). A pack's picture shows as that pack's variant for the
-- view, chosen as the reader's own or as a pack's own.
function M.mineWallpaper(is_full, is_dark, theme)
    local function layer(key, full_view)
        local v = M.themePart(theme, key)
        if M.isPackName(v) then return M.variantName(v, full_view, is_dark) end
        return (type(v) == "string" and v ~= "") and v or nil
    end
    if is_full then
        if M.themePart(theme, "wallpaper_full") == false then return nil end
        local n = layer("wallpaper_full", true)
        if n then return n end
    end
    return layer("wallpaper_default", is_full)
end

-- shownWallpaper(is_full, is_dark) -> the wallpaper name the shelf on
-- screen shows in this view: the reader's edit to its theme, else Plain's
-- none, a theme's own (full screen None stays None: a view preference), else
-- the reader's own (themePart's originals).
function M.shownWallpaper(is_full, is_dark)
    local th = M.shelfTheme()
    if th == M.MINE then return M.mineWallpaper(is_full, is_dark) end
    return M.mineWallpaper(is_full, is_dark, th)
end

-- ── EDITABLE THEMES ─────────────────────────────────────────────────────
-- Every theme can be edited, and the edits are saved with that theme, to
-- appear wherever it does (maintainer, 2026-10-08: "you could apply macabre,
-- edit it to change to another wallpaper, swap back to plain, then use
-- macabre again in future on a specific shelf and it'd still have your
-- edits, then reset it back to original"). Once per theme, not per shelf:
-- two shelves on one theme cannot differ.
--
--   theme_edits = { [a pack's folder, or "plain"] = {
--     keys   = { [a part's settings key] = value }: the parts edited
--              (PART_KEYS), stored as Custom theme stores them (the night slot
--              pre-inverted, the plank colour the exception); UNSET is a
--              part edited to unset: the default, never the theme's or the
--              reader's own,
--     pieces = { [ornament relpath] = true }: its switched-on ornaments once
--              they are edited, from any pack or loose; nil while they are
--              the theme's own,
--     rev    = its edit count (lookKey),
--   } }
--
-- A part resolves (themePart) as the reader's edit, else the theme's
-- original (Plain's fixed parts, a pack's), else, for a pack without that
-- part, Custom theme's. Custom theme IS the reader's own settings: no edits, no
-- original. An edit that puts a part back as the theme has it is dropped, so
-- Reset to original greys once nothing differs; resetEdits removes the
-- theme's entry. A pack updated in place keeps its edits over the new
-- version (Reset gives the new original); one deleted keeps them, harmless,
-- for when it comes back. The wallpaper, the plank and the pieces are
-- REFERENCES (a picture's name, a plank id, a relpath), never copies: one
-- that has gone falls back as a missing pack's does, and its row says so.
--
-- THE SEAM: partRead / partSave. Every reader of a part of the look the
-- shelf paints, and every row of the theme menu that edits one, goes through
-- them: they answer for the theme of the shelf on screen (Custom theme: the
-- reader's own keys).
M.EDITS_SETTING = "theme_edits"
M.UNSET = "\0nil"

-- PART_KEYS: Custom theme's parts, as settings keys: what its menu writes
-- (light or dark, the wallpaper rows, the panel rows, the plank, every
-- colour row; each colour in both slots). The ornament switches are pieces,
-- above. The extra wallpaper folder and plank designs on or off are display
-- preferences no theme touches.
M.PART_KEYS = {
    [M.SHELF_SETTING]          = true,
    ["wallpaper_default"]      = true,
    ["wallpaper_full"]         = true,
    ["wallpaper_invert_night"] = true,
    [M.PLANK_SETTING]          = true,
    -- The shelf menu without its bar: in Colors beside the bar's colour, so
    -- saved with the theme as the colours are (maintainer, 2026-10-09).
    ["chip_bar_transparent"]   = true,
}
-- The panels over a wallpaper (Wallpaper's SCRIM_SETTING, BUTTONS_SETTING,
-- BLUR_SETTING, COVERS_PANEL_SETTING): part of the theme since 2026-10-09
-- (maintainer: "Yes make those part of the theme"), in its Wallpaper menu.
-- Transparent buttons is not a row: Panel shading writes it with the level
-- (Transparent sets it), so it is a part beside it, or a pack's light
-- shading would be cut to nothing by Custom theme's Transparent.
M.PANEL_KEYS = {
    shading = "wallpaper_chrome_scrim",
    buttons = "wallpaper_transparent_buttons",
    blur    = "wallpaper_panel_blur",
    covers  = "covers_full_panel",
}
for _n, key in pairs(M.PANEL_KEYS) do M.PART_KEYS[key] = true end
-- A colour key's slot: { the colours.json setting, night }.
local COLOUR_SLOT = {}
for _n, key in pairs(M.COLOUR_NAMES) do
    M.PART_KEYS[key] = true
    M.PART_KEYS[key .. "_night"] = true
    COLOUR_SLOT[key] = { key, false }
    COLOUR_SLOT[key .. "_night"] = { key, true }
end
function M.isPart(key) return M.PART_KEYS[key] == true end
local PANEL_PART = {}
for _n, key in pairs(M.PANEL_KEYS) do PANEL_PART[key] = true end

-- editsOf(theme) -> the reader's edits to that theme, or nil (none, or
-- Custom theme). hasEdits(theme): Reset to original is greyed without them, and
-- the theme's card says Edited with them.
function M.editsOf(theme)
    if theme == nil or theme == M.MINE then return nil end
    local all = read(M.EDITS_SETTING)
    local e = type(all) == "table" and all[theme] or nil
    return type(e) == "table" and e or nil
end
function M.hasEdits(theme) return M.editsOf(theme) ~= nil end

-- editsColours(e): has the reader edited any colour of that theme, the
-- page's included.
function M.editsColours(e)
    for k in pairs(type(e) == "table" and type(e.keys) == "table" and e.keys or {}) do
        if COLOUR_SLOT[k] then return true end
    end
    return false
end

-- ownPart(theme, key) -> true, value when that theme has that part of its
-- own, in the stored convention: Plain's fixed parts (no wallpaper, the
-- built-in Oak, the default colours), a pack's own (a colours.json lends
-- only the colours it names; its wallpaper by name, so the full screen and
-- dark variants come with it). false for a part it takes from Custom theme:
-- light or dark and invert on Plain, whatever a pack lacks, and full screen
-- None, the reader's view preference over a pack's wallpaper.
local function ownPart(theme, key)
    local slot = COLOUR_SLOT[key]
    if theme == M.PLAIN then
        if slot or key == "wallpaper_default" or key == "wallpaper_full" then return true, nil end
        if key == M.PLANK_SETTING then return true, "oak" end
        if key == "chip_bar_transparent" then return true, nil end   -- the bar, as by default
        -- The panels as by default: Heavy shading, no blur, no Covers panel.
        if PANEL_PART[key] then return true, nil end
        return false
    end
    local th = M.theme(theme)
    if PANEL_PART[key] then
        local m = th.manifest or {}
        local P = M.PANEL_KEYS
        if key == P.shading and m.panel_shading ~= nil then return true, m.panel_shading end
        if key == P.buttons and m.panel_shading ~= nil then return true, (m.panel_shading <= 0) or nil end
        if key == P.blur and m.panel_blur ~= nil then return true, m.panel_blur or nil end
        if key == P.covers and m.covers_panel ~= nil then return true, m.covers_panel or nil end
        return false
    end
    if slot then
        local c = th.colours and packColour(theme, slot[1], slot[2])
        if c then return true, c end
        return false
    end
    if key == M.SHELF_SETTING then
        if th.manifest and th.manifest.shelf then return true, th.manifest.shelf end
        return false
    end
    if th.wallpaper and key == "wallpaper_default" then
        return true, M.NAME_PREFIX .. theme .. "\1" .. th.wallpaper.base
    end
    if th.wallpaper and key == "wallpaper_full" then
        if read(key) == false then return false end
        return true, nil
    end
    if key == M.PLANK_SETTING and #(th.planks or {}) > 0 then
        local pl = M.themePlank(theme)
        return true, pl and pl.id or nil
    end
    return false
end

-- originalPart(theme, key) -> that part as the theme shows it unedited: its
-- own (ownPart), else the reader's own.
function M.originalPart(theme, key)
    if theme == nil or theme == M.MINE then return read(key) end
    local has, v = ownPart(theme, key)
    if has then return v end
    return read(key)
end

-- themePart(theme, key) -> that part as that theme shows it: the reader's
-- edit, else its original (nil theme: Custom theme's, the reader's own key).
-- e (optional): that theme's edits when the caller holds them (partRead:
-- the shelf's resolution has them), so they are not read again.
function M.themePart(theme, key, e)
    if theme == nil or theme == M.MINE then return read(key) end
    if e == nil then e = M.editsOf(theme) end
    local keys = e and e.keys
    if type(keys) == "table" and keys[key] ~= nil then
        local v = keys[key]
        if v == M.UNSET then return nil end
        return v
    end
    return M.originalPart(theme, key)
end

-- partRead(key): a part's value in the theme the shelf on screen paints
-- and the menu edits. A key that is not a part is the reader's preference.
function M.partRead(key)
    if not M.isPart(key) then return read(key) end
    local c = current()
    return M.themePart(c.theme, key, c.e or false)
end

-- partEdited(key) -> has the reader edited that part of the theme on
-- screen (a row names a reference that has gone as "(missing)").
function M.partEdited(key)
    local e = current().e
    return e ~= nil and type(e.keys) == "table" and e.keys[key] ~= nil
end

local function same(a, b)
    if a == b then return true end
    if type(a) ~= "table" or type(b) ~= "table" then return false end
    for k, v in pairs(a) do if b[k] ~= v then return false end end
    for k, v in pairs(b) do if a[k] ~= v then return false end end
    return true
end

-- originalPieces(theme) -> { [relpath] = true }: what that theme deals
-- unedited: none on Plain, a pack's own pieces, else (a pack without any)
-- the collection's switched-on set. Shared: copy before changing it. Once
-- per list, not per piece the browser asks about.
M._orig = {}
local function originalPieces(theme)
    if theme == M.PLAIN then return {} end
    local O = orn()
    local list = M.hasPieces(theme) and O.listFor(theme) or O.list()
    local hit = M._orig[theme]
    if hit and hit.list == list then return hit.set end
    local set = {}
    for _i, e in ipairs(list or {}) do set[e.name] = true end
    M._orig[theme] = { list = list, set = set }
    return set
end

-- writeEdits(theme, fn): fn(e) edits that theme's entry (a copy: the stored
-- one is replaced whole, never changed in place); parts and pieces put back
-- as the theme has them are dropped, an entry left with nothing goes. One
-- settings write, which bumps the generation, so every memo moves (deferred
-- while the ornament browser is open, as the collection's switches are).
local function writeEdits(theme, fn)
    if theme == nil or theme == M.MINE then return end
    local all = read(M.EDITS_SETTING)
    local out = {}
    if type(all) == "table" then for k, v in pairs(all) do out[k] = v end end
    local old = type(out[theme]) == "table" and out[theme] or {}
    local old_keys = type(old.keys) == "table" and old.keys or {}
    -- pieces keeps its table unless fn replaces it: the pool keys on it, and
    -- a colour edit must not re-deal the pages' ornaments.
    local e = { keys = {}, pieces = old.pieces }
    for k, v in pairs(old_keys) do e.keys[k] = v end
    fn(e)
    -- Only the parts this write changed, and only against the theme's OWN
    -- part (ownPart): an edit that equals what the theme takes from Custom
    -- theme is still an edit, or the theme would follow Custom theme's
    -- next change (review, 2026-10-09).
    for k, v in pairs(e.keys) do
        if not same(v, old_keys[k]) then
            local has, orig = ownPart(theme, k)
            if has and same(v ~= M.UNSET and v or nil, orig) then e.keys[k] = nil end
        end
    end
    if type(e.pieces) == "table" and e.pieces ~= old.pieces and same(e.pieces, originalPieces(theme)) then
        e.pieces = nil
    end
    if next(e.keys) == nil and type(e.pieces) ~= "table" then
        out[theme] = nil
    else
        e.rev = (tonumber(old.rev) or 0) + 1
        out[theme] = e
    end
    save(M.EDITS_SETTING, next(out) ~= nil and out or nil)
    M._plank_memo, M._cur = nil, nil
end

-- partSave(key, v): a part edited, in the theme the menu edits (as
-- partRead): Custom theme's key, else that theme's edits. A key that is not a
-- part is the reader's preference: saved as it always was.
function M.partSave(key, v)
    local th = M.shelfTheme()
    if th ~= M.MINE and M.isPart(key) then
        writeEdits(th, function(e)
            if v == nil then e.keys[key] = M.UNSET else e.keys[key] = v end
        end)
        return
    end
    save(key, v)
end
function M.partDelete(key) M.partSave(key, nil) end

-- partSnapshot(key) / partRestore(key, snap): a picker's Cancel puts the
-- part back as it was, edited or not: an unedited part of a theme goes
-- back to unedited, so it follows Custom theme again, rather than being
-- pinned to the value it showed when the picker opened.
function M.partSnapshot(key)
    return { v = M.partRead(key), edited = M.partEdited(key) }
end
function M.partRestore(key, snap)
    local th = M.shelfTheme()
    if th ~= M.MINE and M.isPart(key) and not snap.edited then
        writeEdits(th, function(e) e.keys[key] = nil end)
        return
    end
    M.partSave(key, snap.v)
end

-- partClear(keys): those parts back to the default, both slots, in one
-- write (Reset to default colors). In a theme only its parts: a preference
-- listed with them stays as the reader set it.
function M.partClear(keys)
    local th = M.shelfTheme()
    if th ~= M.MINE then
        writeEdits(th, function(e)
            for _i, k in ipairs(keys) do
                if M.isPart(k) then e.keys[k] = M.UNSET end
                if M.isPart(k .. "_night") then e.keys[k .. "_night"] = M.UNSET end
            end
        end)
        return
    end
    for _i, k in ipairs(keys) do save(k, nil); save(k .. "_night", nil) end
end

-- resetEdits(theme): Reset to original (confirmed by the caller): that
-- theme's edits gone, wherever it shows. true when it had some.
function M.resetEdits(theme)
    local all = read(M.EDITS_SETTING)
    if type(all) ~= "table" or all[theme] == nil then return false end
    local out = {}
    for k, v in pairs(all) do if k ~= theme then out[k] = v end end
    save(M.EDITS_SETTING, next(out) ~= nil and out or nil)
    M._plank_memo, M._cur = nil, nil
    return true
end

-- confirmReset(theme, after): Reset to original for a pack or Plain, asked
-- first: the Theme library's footer Reset and a card's long-press
-- (maintainer, 2026-10-09) ask the one question. after(): once the edits are
-- gone, to refresh what showed them. The wallpaper's decode is NOT freed:
-- Wallpaper.bg keys it by the picture, so a shelf that shows another one
-- after the reset decodes that one on its rebuild, and a shelf on another
-- theme keeps its picture (freed, it went blank until the next page turn).
function M.confirmReset(theme, after)
    if theme == nil or theme == M.MINE then return end
    local UIManager = require("ui/uimanager")
    local ConfirmBox = require("ui/widget/confirmbox")
    UIManager:show(ConfirmBox:new{
        text = T(_("Reset %1 to its original settings? Your changes to it are lost."), M.themeName(theme)),
        ok_text = _("Reset"),
        ok_callback = function()
            M.resetEdits(theme)
            if after then after() end
        end,
    })
end

-- editPoolOf(theme, e): what a shelf showing a theme with edited ornaments
-- deals from (bookshelf_ornaments.listFor): { slot, key, on = its
-- switched-on pieces }. The same table while the pieces are unchanged: the
-- deck and the plan key on what listFor hands back.
M._pools, M._pool_n = {}, 0
function M.editPoolOf(theme, e)
    local hit = M._pools[theme]
    if hit and hit.src == e.pieces then return hit.v end
    M._pool_n = M._pool_n + 1
    local slot = "edit:" .. tostring(theme)
    local v = { edit = theme, slot = slot, key = slot .. ":" .. M._pool_n, on = e.pieces }
    M._pools[theme] = { src = e.pieces, v = v }
    return v
end

-- editPool(): the pool of the theme the menu edits (the Ornaments row's
-- count).
function M.editPool() return M.poolOf(M.shelfTheme()) end

-- switches(): the ornament on/off switches the editors (the ornament
-- browser, a piece's own menu) read and write: the collection's on a Custom
-- theme shelf, else the theme on screen's set. Editing a theme's ornaments
-- may switch on any installed piece, from any pack or loose (spec,
-- 2026-10-08); a theme has no pack switches: a pack is only pieces to it.
function M.switches()
    local th = M.shelfTheme()
    if th == M.MINE then
        local O = orn()
        return { isOff = O.isOff, isPackOff = O.isPackOff, setOff = O.setOff, setPackOff = O.setPackOff }
    end
    local function on()
        local e = M.editsOf(th)
        if e and type(e.pieces) == "table" then return e.pieces end
        return originalPieces(th)
    end
    return {
        theme = th,
        isOff = function(name) return not on()[name] end,
        isPackOff = function() return false end,
        setOff = function(name, off)
            writeEdits(th, function(e)
                local p = {}
                for k, v in pairs(type(e.pieces) == "table" and e.pieces or originalPieces(th)) do p[k] = v end
                p[name] = (not off) or nil
                e.pieces = p
            end)
        end,
        setPackOff = function() end,
    }
end

-- editName(): the theme the Theme menu is named for, "Theme (Macabre)": the
-- theme of the shelf on screen, which its rows edit (Custom theme, Plain,
-- Macabre).
function M.editName() return M.themeName(M.shelfTheme()) end

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
-- Version 2 (editable themes, 2026-10-08):
--   4. 5.3 switched single pack pieces off in the collection (ornaments_off)
--      and a shelf wearing that pack did not deal them. A pack deals its own
--      set now, edited with the theme: each pack's off switches become that
--      pack's edit, so nothing on screen changes. ornaments_off stays as it
--      is: it is Custom theme's set, which deals pack pieces too. The pack
--      the library wore (step 1) already has its edit: everything 5.3 dealt
--      there, loose pieces included.
-- Version 3 (2026-10-09):
--   5. Panel shading Transparent used to leave out the shelf menu's bar as
--      well; now only Shelf menu background: Transparent does. A reader at
--      Transparent shading with no choice of their own for the bar gets that
--      choice set, so the bar stays as they saw it.
-- Idempotent, and guarded by a version so each step runs once.
M.MIGRATION_SETTING = "theme_model"
M.MIGRATION_VERSION = 3
M.APPLIED_SETTING   = "theme_applied"
M.COLOURS_SETTING   = "theme_colours_pack"

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
    -- What 5.3 dealt with the theme on: every piece switched on whose pack
    -- was on (its own, the loose ones, any pack switched back on). A pack
    -- deals only its own pieces now, so this becomes the pack's edited set,
    -- or the loose pieces would leave the shelf. Taken before the reader's
    -- pack switches come back; the card then says Edited (maintainer,
    -- 2026-10-09), unless it is just the pack's own set (writeEdits drops it).
    local dealt = {}
    for _i, e in ipairs((O.listAll()) or {}) do
        if not O.isOff(e.name) and not (e.pack and O.isPackOff(e.pack)) then dealt[e.name] = true end
    end
    for k in pairs(s.applied) do
        if k ~= M.DESIGNS_OFF_SETTING then save(k, dec(s.before[k])) end
    end
    if packs_applied then
        local before = type(s.packs_before) == "table" and s.packs_before or {}
        for _i, p in ipairs(packs or {}) do O.setPackOff(p, before[p] == true) end
    end
    save(M.LIBRARY_SETTING, pack)
    writeEdits(pack, function(ed) ed.pieces = dealt end)
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

local function migratePieceSwitches()
    local O = orn()
    local all = O.listAll() or {}
    local packs = {}
    for _i, e in ipairs(all) do
        if e.pack and not M.isReserved(e.pack) and O.isOff(e.name) then packs[e.pack] = true end
    end
    for pack in pairs(packs) do
        local had = M.editsOf(pack)
        if not (had and type(had.pieces) == "table") then
            writeEdits(pack, function(ed)
                local p = {}
                for _i, e in ipairs(all) do
                    if e.pack == pack and not O.isOff(e.name) then p[e.name] = true end
                end
                ed.pieces = p
            end)
        end
    end
end

function M.migrate()
    local v = read(M.MIGRATION_SETTING)
    if type(v) == "number" and v >= M.MIGRATION_VERSION then return end
    local from = type(v) == "number" and v or 0
    local O = orn()
    local own_defer = O.beginDeferred ~= nil and not O._defer
    if own_defer then O.beginDeferred() end
    local ok, err = pcall(function()
        if from < 1 then
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
        end
        if from < 2 then
            migratePieceSwitches()
        end
        if from < 3 then
            local shading = read("wallpaper_chrome_scrim")
            if type(shading) == "number" and shading <= 0 and read("chip_bar_transparent") == nil then
                save("chip_bar_transparent", true)
            end
        end
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
