--[[
Micro-module registry + loader. A micro-module is a read-only info panel:
  { key = <string>, title = <string>,
    render = function(width) -> widget|nil, on_tap = function(ctx)|nil,
    keep_open = boolean|function(ctx) -> bool|nil,
    show_settings = function(ctx)|nil }
Micro-modules live as self-contained spec files in <plugin>/micromodules/
(one file each, returning the spec table); see the README there for the
contract. Discovery is lazy - the directory is scanned on first registry
access, not at require time - and loads via dofile, NOT require: the
directory isn't a module namespace, and dofile'd files can still
require("lib/...") because package.path is process-wide. Invalid or
crashing files are logged and skipped; a broken contributed module must
never break the menu.
]]
local logger = require("logger")

local M = {}
local registry = {}
local scanned = false
-- Which file each registered key came from, and which files have been run,
-- so the lazy path below and the full scan never dofile one twice.
local file_of = {}
local loaded_files = {}

-- Shared card-surface grey: the start menu's module rows, the module
-- picker's preview cards and every module's opaque TextBoxWidget bgcolor
-- all paint this one constant, so the muted-text contrast is tuned in one
-- place (0xEE keeps COLOR_DARK_GRAY text readable while still reading as
-- a distinct surface against the panel's white). pcall: blitbuffer is
-- unavailable under the standalone test runner that dofiles this file.
local ok_bb, Blitbuffer = pcall(require, "ffi/blitbuffer")
M.CARD_BG = ok_bb and Blitbuffer.COLOR_GRAY_E or nil

-- setCardBg(c) -- point the card surface at a new colour, for the whole module
-- system at once.
--
-- The card and the text drawn on it are ONE decision: every TextBoxWidget the
-- Kit builds paints CARD_BG as its own background, because a text widget
-- cannot be transparent. Let the two drift and every line of text grows a box
-- behind it in the old colour.
--
-- Assignment, not a parameter, because the modules read this at RENDER time
-- (`local CARD_BG = SM.CARD_BG` inside their render functions) and several are
-- user-supplied drop-ins that cannot be asked to take a new argument.
--
-- The Kit is required lazily: it requires THIS file at load, so reaching for
-- it up here would be a cycle.
function M.setCardBg(c)
    if not c then return end
    M.CARD_BG = c
    local ok, Kit = pcall(require, "lib/bookshelf_module_kit")
    if ok and Kit then Kit.CARD_BG = c end
end

-- Shared text-colour roles for micromodules, so every card renders text the
-- same way instead of each module hardcoding its own constants (which drifted
-- -- some even pulled COLOR_* off ui/renderimage, where they're nil, so the
-- text fell back to black). Defining them here means a future contrast /
-- theme control can adjust every card from one place.
--   PRIMARY: main content and emphasised lines, including the "Tap…" hints.
--   MUTED:   small category labels and timestamps; use sparingly.
-- MUTED is GRAY_5 (0x55), not DARK_GRAY (0x88): on the 0xEE card surface the
-- 0x88 mid-gray didn't carry enough contrast on weaker e-ink panels (the V3
-- launch readability problem). 0x55 keeps it clearly a muted gray while
-- giving ~0x99 of contrast against the card instead of ~0x66.
M.COLOR_PRIMARY = ok_bb and Blitbuffer.COLOR_BLACK or nil
M.COLOR_MUTED   = ok_bb and Blitbuffer.COLOR_GRAY_5 or nil

-- setInk(primary, muted) -- the theme control that comment anticipated.
--
-- The shelf calls this beside setCardBg on every rebuild. Under its own dark
-- theme the card goes near-black and black text on it is not muted, it is
-- gone -- and unlike the device's night mode nothing inverts to rescue it.
-- Either argument may be nil to keep the current value.
--
-- MUTED keeps the same relationship to the card it always had: a third of the
-- way from the ink toward the surface, which is what 0x55 is between black
-- ink and a 0xEE card. On a dark card that lands near 0xB0, so a label stays
-- clearly secondary without dropping into the board.
function M.setInk(primary, muted)
    if type(primary) ~= "nil" then M.COLOR_PRIMARY = primary end
    if type(muted)   ~= "nil" then M.COLOR_MUTED   = muted end
    -- AND THE KIT'S COPIES, exactly as setCardBg does, and for the same
    -- reason: bookshelf_module_kit re-exports these so a module needs one
    -- require, and it does it by VALUE at load time --
    --     Kit.COLOR_PRIMARY = SM.COLOR_PRIMARY
    -- so a module reaching for Kit.COLOR_MUTED kept getting the black that was
    -- current when the kit was first required, whatever this setter did
    -- afterwards. Half the cards themed and half stayed black-on-black,
    -- depending only on which of the two names that module happened to use.
    --
    -- Required lazily for the cycle setCardBg documents.
    local ok, Kit = pcall(require, "lib/bookshelf_module_kit")
    if ok and Kit then
        if type(primary) ~= "nil" then Kit.COLOR_PRIMARY = primary end
        if type(muted)   ~= "nil" then Kit.COLOR_MUTED   = muted end
    end
end

-- resetTheme() -- the light defaults back, in both names.
--
-- The palette above is process-global and only the LIBRARY's hero build
-- writes it (HeroModules.build, beside setCardBg). The start menu is also
-- hosted by the reader, over a plain page the shelf theme never touches, so
-- after a dark or wallpapered shelf its module cards kept the dark card and
-- the white ink until the shelf was next rebuilt in light. The reader host
-- calls this before it builds.
local DEFAULT_CARD_BG = M.CARD_BG
local DEFAULT_PRIMARY = M.COLOR_PRIMARY
local DEFAULT_MUTED   = M.COLOR_MUTED
function M.resetTheme()
    M.setCardBg(DEFAULT_CARD_BG)
    M.setInk(DEFAULT_PRIMARY, DEFAULT_MUTED)
end

-- Menu-open generation: StartMenu bumps this once per menu open, so modules
-- may key per-open caches on it (the counter is stable across the menu's
-- focus-step rebuilds, unlike a TTL). See quote_of_day's "every menu open"
-- refresh mode.
M.menu_generation = 0
function M.bumpGeneration()
    M.menu_generation = M.menu_generation + 1
end

-- <plugin root>/micromodules, resolved from this file's own location
-- (lib/, so one level up) - same trick as bookshelf_i18n's locale path.
local function modulesDir()
    local dir = debug.getinfo(1, "S").source:match("^@(.+/)") or "./"
    return dir:gsub("lib/$", "") .. "micromodules"
end

-- User micro-module dir, OUTSIDE the plugin so dropped-in modules survive a
-- plugin update (the bundled dir is replaced wholesale on update). Lives under
-- KOReader's writable settings dir; nil when DataStorage is unavailable (e.g.
-- the standalone test runner). Not created here - absent is fine.
local function userModulesDir()
    local ok, DataStorage = pcall(require, "datastorage")
    if ok and DataStorage and DataStorage.getSettingsDir then
        return DataStorage:getSettingsDir() .. "/bookshelf/micromodules"
    end
    return nil
end

-- ── Module packs ────────────────────────────────────────────────────────────
-- A third-party pack ships as a small KOReader plugin: a .koplugin holding a
-- bookshelf_modules/ folder of module files. App Store and Storefront install
-- and update plugins, so a pack published that way installs and updates from
-- the device, and Bookshelf itself never goes online for it.

-- packDirs(lookup_paths, disabled) -> { { dir, origin = "plugin:<name>" } }:
-- every <path>/<name>.koplugin/bookshelf_modules under the given plugin
-- folders, leaving out plugins switched off in KOReader (disabled[name]).
local function packDirs(lookup_paths, disabled)
    local out = {}
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok_lfs then return out end
    disabled = disabled or {}
    for _i, path in ipairs(lookup_paths or {}) do
        if lfs.attributes(path, "mode") == "directory" then
            for entry in lfs.dir(path) do
                local name = entry:match("^(.+)%.koplugin$")
                if name and not disabled[name] then
                    local d = path .. "/" .. entry .. "/bookshelf_modules"
                    if lfs.attributes(d, "mode") == "directory" then
                        out[#out + 1] = { dir = d, origin = "plugin:" .. name }
                    end
                end
            end
        end
    end
    return out
end

-- The plugin folders KOReader loads from (PluginLoader:_discover): its own
-- "plugins", and extra_plugin_paths, or the data dir's when that's unset.
local function pluginLookupPaths()
    local paths = { "plugins" }
    local ok, extra = pcall(function()
        return G_reader_settings and G_reader_settings:readSetting("extra_plugin_paths")
    end)
    extra = ok and extra or nil
    if type(extra) == "string" then extra = { extra } end
    if type(extra) == "table" then
        for _i, p in ipairs(extra) do
            if type(p) == "string" and p ~= "plugins" then paths[#paths + 1] = p end
        end
    else
        local ok_ds, DataStorage = pcall(require, "datastorage")
        if ok_ds and DataStorage and DataStorage.getDataDir and DataStorage:getDataDir() ~= "." then
            paths[#paths + 1] = DataStorage:getDataDir() .. "/plugins"
        end
    end
    return paths
end

local function installedPackDirs()
    local ok, disabled = pcall(function()
        return G_reader_settings and G_reader_settings:readSetting("plugins_disabled")
    end)
    return packDirs(pluginLookupPaths(), ok and type(disabled) == "table" and disabled or {})
end

-- Every folder modules load from, in precedence order (first registered key
-- wins): the user's own, then plugin packs, then the bundled ones.
local function moduleDirs()
    local out = { { dir = userModulesDir(), origin = "user" } }
    for _i, d in ipairs(installedPackDirs()) do out[#out + 1] = d end
    out[#out + 1] = { dir = modulesDir(), origin = "bundled" }
    return out
end

-- registerSpec(spec, dir, fname, origin): check one module spec and add it
-- to the registry; a bad one is logged and skipped.
local function registerSpec(spec, dir, fname, origin)
    if type(spec) ~= "table"
            or type(spec.key) ~= "string" or spec.key == ""
            or type(spec.title) ~= "string"
            or type(spec.render) ~= "function" then
        logger.warn("[bookshelf] micro-module spec invalid"
            .. " (need string key, string title, function render), skipping:",
            fname)
        return
    end
    if spec.show_settings ~= nil and type(spec.show_settings) ~= "function" then
        logger.warn("[bookshelf] micro-module spec invalid"
            .. " (show_settings must be a function when present), skipping:",
            fname)
        return
    end
    if spec.keep_open ~= nil and type(spec.keep_open) ~= "boolean"
            and type(spec.keep_open) ~= "function" then
        logger.warn("[bookshelf] micro-module spec invalid"
            .. " (keep_open must be a boolean or function when present),"
            .. " skipping:", fname)
        return
    end
    if spec.on_minute ~= nil and type(spec.on_minute) ~= "function" then
        logger.warn("[bookshelf] micro-module spec invalid"
            .. " (on_minute must be a function when present), skipping:", fname)
        return
    end
    if spec.on_tap ~= nil and type(spec.on_tap) ~= "function" then
        logger.warn("[bookshelf] micro-module spec invalid"
            .. " (on_tap must be a function when present), skipping:", fname)
        return
    end
    if spec.aspect ~= nil and type(spec.aspect) ~= "string" then
        logger.warn("[bookshelf] micro-module spec invalid"
            .. " (aspect must be a string when present), skipping:", fname)
        return
    end
    if spec.bare ~= nil and type(spec.bare) ~= "boolean" then
        logger.warn("[bookshelf] micro-module spec invalid"
            .. " (bare must be a boolean when present), skipping:", fname)
        return
    end
    if spec.in_place ~= nil and type(spec.in_place) ~= "boolean" then
        logger.warn("[bookshelf] micro-module spec invalid"
            .. " (in_place must be a boolean when present), skipping:", fname)
        return
    end
    -- Optional colour rows of its own (bookshelf_module_card): a list of
    -- { id, text, default, default_dark }, none taking a card key.
    if spec.colors ~= nil and not require("lib/bookshelf_module_card").validColors(spec.colors) then
        logger.warn("[bookshelf] micro-module spec invalid"
            .. " (colors must be a list of { id, text }, ids not bg/border/border_color/ink),"
            .. " skipping:", fname)
        return
    end
    -- Optional grid size hints (whole cells): the size it starts at, and the
    -- smallest the layout editor lets the module be sized to. The grid clamps
    -- them to its own size.
    for _i, f in ipairs({ "start_w", "start_h", "min_w", "min_h" }) do
        local v = spec[f]
        if v ~= nil and (type(v) ~= "number" or v < 1 or v ~= math.floor(v)) then
            logger.warn("[bookshelf] micro-module spec invalid"
                .. " (" .. f .. " must be a whole number of cells, 1 or more),"
                .. " skipping:", fname)
            return
        end
    end
    if registry[spec.key] then
        if origin == "bundled" then
            -- The user dir is scanned first, so a bundled key already present
            -- means a user module deliberately overrides this shipped one
            -- (lets a developer iterate on a bundled module locally). Expected,
            -- not an error.
            logger.info("[bookshelf] micro-module '" .. spec.key
                .. "' overridden by a user module; keeping the user version")
        else
            logger.warn("[bookshelf] micro-module duplicate key, skipping:",
                fname, spec.key)
        end
        return
    end
    registry[spec.key] = spec
    if origin then file_of[spec.key] = { fname = fname, origin = origin, dir = dir } end
end

local function loadSpec(dir, fname, origin)
    local fkey = tostring(origin) .. "|" .. dir .. "/" .. fname
    if loaded_files[fkey] then return end
    loaded_files[fkey] = true
    -- loadfile + call, not dofile: the chunk receives its own folder as
    -- `...`, so a pack's module file can dofile shared code beside it.
    local chunk, load_err = loadfile(dir .. "/" .. fname)
    local ok, spec
    if chunk then
        ok, spec = pcall(chunk, dir)
    else
        ok, spec = false, load_err
    end
    if not ok then
        logger.warn("[bookshelf] micro-module failed to load, skipping:",
            fname, spec)
        return
    end
    -- A list of modules: a pack that finds out when it loads what it can
    -- offer (one per thing it found, or none when what it needs is missing).
    -- Each entry is checked on its own; an empty list is simply nothing.
    if type(spec) == "table" and spec.key == nil and spec.render == nil then
        for _i, one in ipairs(spec) do registerSpec(one, dir, fname, origin) end
        return
    end
    registerSpec(spec, dir, fname, origin)
end

local function scanDir(dir, origin)
    if not dir then return end
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok_lfs then
        logger.warn("[bookshelf] micro-modules: lfs unavailable", lfs)
        return
    end
    if lfs.attributes(dir, "mode") ~= "directory" then return end
    for fname in lfs.dir(dir) do
        if fname:sub(-4) == ".lua" then
            loadSpec(dir, fname, origin)
        end
    end
end

-- inUse() -> false only when micro-modules are used nowhere: every surface
-- switched off (start menu / hero / full-screen / On the shelf), or only On
-- the shelf on and no shelf with modules among its books. Counting only the
-- first three left a shelf's modules with no definition: they showed their
-- key ("shelf") in place of themselves (maintainer, PW5). pcall + explicit
-- `== false` so the standalone test runner (no settings store) and any read
-- error count as in use, never block.
local function inUse()
    local ok_any, any = pcall(function()
        return require("lib/bookshelf_settings_store").microAnyEnabled()
    end)
    if ok_any and any == false then return false end
    -- On, but perhaps only On the shelf (on by default): in use only if a
    -- shelf has modules, so a reader who uses none loads none.
    local ok_s, surfaces = pcall(function()
        local Store = require("lib/bookshelf_settings_store")
        return Store.microInStartMenu() or Store.microInHero() or Store.microFullscreenButton()
    end)
    if not ok_s or surfaces ~= false then return true end
    local ok_t, on_shelf = pcall(function()
        for _i, t in ipairs(require("lib/bookshelf_tab_model").load() or {}) do
            if type(t.shelf_modules) == "table" and #t.shelf_modules > 0 then return true end
        end
        return false
    end)
    return not ok_t or on_shelf == true
end

-- scan(force): load every module file. Kill switch: unless forced, skipped
-- while micro-modules are in use nowhere (inUse), so no module file is even
-- dofile'd; re-attempted once something uses them (scanned stays false). The
-- picker forces it: opening it is asking for modules (M.keys).
local function scan(force)
    if scanned then return end
    if not force and not inUse() then return end
    scanned = true
    -- User dir FIRST so a user module overrides a bundled one of the same key
    -- (first-registered wins), and survives plugin updates; then the bundled
    -- modules. Either dir may be absent - scanDir tolerates that.
    for _i, d in ipairs(moduleDirs()) do scanDir(d.dir, d.origin) end
    M._saveIndex()
end

-- ── Lazy loading ────────────────────────────────────────────────────────────
-- The full scan runs every module file in both dirs. Cold on a PW5 that was
-- 124ms of a full-screen open showing 7 of 17 modules. M.get(key) first tries
-- the index the last full scan left (key -> file, in the module cache): it
-- runs just that file. The index is trusted only while the two dirs hold
-- exactly the files they held then (names listed, which is cheap next to
-- running them), so a module added, removed or overriding a bundled one sends
-- the next lookup through the full scan, which rewrites the index. A key the
-- index names but its file no longer defines does the same.
local INDEX_KEY = "module_index"
local _index_checked, _index

local function dirSignature()
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok_lfs then return nil end
    local parts = {}
    for _i, d in ipairs(moduleDirs()) do
        local dir, origin = d.dir, d.origin
        local names = {}
        if dir and lfs.attributes(dir, "mode") == "directory" then
            for fname in lfs.dir(dir) do
                if fname:sub(-4) == ".lua" then names[#names + 1] = fname end
            end
        end
        table.sort(names)
        parts[#parts + 1] = origin .. ":" .. table.concat(names, ",")
    end
    return table.concat(parts, ";")
end

function M._saveIndex()
    local sig = dirSignature()
    if not sig then return end
    local keys = {}
    for k, f in pairs(file_of) do keys[k] = { f.fname, f.origin, f.dir } end
    pcall(function()
        require("lib/bookshelf_module_cache").save(INDEX_KEY, { sig = sig, keys = keys })
    end)
end

local function trustedIndex()
    if _index_checked then return _index end
    _index_checked = true
    local ok, idx = pcall(function()
        return require("lib/bookshelf_module_cache").read(INDEX_KEY)
    end)
    if ok and type(idx) == "table" and type(idx.keys) == "table"
            and idx.sig ~= nil and idx.sig == dirSignature() then
        _index = idx
    end
    return _index
end

local function loadIndexed(key)
    if scanned then return false end
    if not inUse() then return false end
    local idx = trustedIndex()
    local e = idx and idx.keys[key]
    if type(e) ~= "table" then return false end
    local dir = e[3] or ((e[2] == "user") and userModulesDir() or modulesDir())
    if not dir then return false end
    loadSpec(dir, e[1], e[2])
    return registry[key] ~= nil
end

-- Additive registration for callers that build specs in code (kept for
-- API stability; file-based modules in micromodules/ are preferred).
function M.register(key, def) registry[key] = def end
function M.get(key)
    if registry[key] then return registry[key] end
    if loadIndexed(key) then return registry[key] end
    scan()
    return registry[key]
end

-- notifyRemoved(entry): a card was removed. Its module's optional
-- on_remove(entry) cleans up what the card owned (a Shelf card's own shelf).
-- Errors are the module's own: they never stop the removal.
function M.notifyRemoved(entry)
    if type(entry) ~= "table" or type(entry.module) ~= "string" then return end
    local def = M.get(entry.module)
    if def and type(def.on_remove) == "function" then pcall(def.on_remove, entry) end
end
function M.title(key)
    local d = M.get(key)
    return d and d.title
end
function M.keys()
    scan(true)
    local out = {}
    for k in pairs(registry) do out[#out + 1] = k end
    table.sort(out)
    return out
end

M._test = { scanDir = scanDir, registry = registry, packDirs = packDirs,
            reset = function()
                for k in pairs(registry) do registry[k] = nil end
                for k in pairs(file_of) do file_of[k] = nil end
                for k in pairs(loaded_files) do loaded_files[k] = nil end
                scanned, _index_checked, _index = false, false, nil
            end }
-- ── Groups: the module library's chips ─────────────────────────────────────
-- Every module belongs to one group, a chip in the library. Bundled modules
-- have a category set below; a plugin pack's modules are that pack; loose
-- modules in the reader's own folder group by a "Name · " title prefix (how
-- a bundle like Reading Log's names its cards), else they are the reader's
-- own. A spec may say so itself: `pack = "Name"`, or `category = "<id>"`
-- with one of the ids below.
M.CATEGORY_ORDER = { "shelf", "reading", "time", "fun", "actions" }
local function _(s)
    local ok, i18n = pcall(require, "lib/bookshelf_i18n")
    return (ok and i18n and i18n.gettext) and i18n.gettext(s) or s
end
-- Functions, so each label is a literal _() the translation tools find, and
-- is looked up when shown (the language may change while running).
local CATEGORY_LABEL = {
    shelf   = function() return _("Shelf & books") end,
    reading = function() return _("Reading") end,
    time    = function() return _("Time & device") end,
    fun     = function() return _("Fun & info") end,
    actions = function() return _("Actions") end,
}
local BUNDLED_CATEGORY = {
    shelf = "shelf", last_books = "shelf", random_unread = "shelf",
    shelf_size = "shelf", ornament = "shelf",
    reading_goal = "reading", stats = "reading", reading_streak = "reading",
    quote_of_day = "reading",
    clock = "time", analogue_clock = "time", battery = "time", countdown = "time",
    fact = "fun", otd = "fun", trivia = "fun", weather = "fun",
    action = "actions",
}

-- groupFor(key, spec, file) -> group id, its label. file is where the module
-- was loaded from ({ origin = "bundled" | "user" | "plugin:<folder>",
-- label = the pack's own name, if known }).
function M.groupFor(key, spec, file)
    spec, file = spec or {}, file or {}
    if type(spec.pack) == "string" and spec.pack ~= "" then
        return "pack:" .. spec.pack, spec.pack
    end
    if type(spec.category) == "string" and CATEGORY_LABEL[spec.category] then
        return spec.category, CATEGORY_LABEL[spec.category]()
    end
    local origin = file.origin or "bundled"
    if origin == "bundled" then
        local c = BUNDLED_CATEGORY[key] or "fun"
        return c, CATEGORY_LABEL[c]()
    end
    local plugin = origin:match("^plugin:(.+)$")
    if plugin then
        return "pack:" .. plugin, file.label or plugin
    end
    local prefix = type(spec.title) == "string" and spec.title:match("^(.-)%s+\xC2\xB7%s+.+$")
    if prefix and prefix ~= "" then return "pack:" .. prefix, prefix end
    return "mine", _("My modules")
end

-- group(key) -> the registered module's group id and label.
function M.group(key)
    local spec = M.get(key)
    local file = file_of[key]
    local info = file and { origin = file.origin }
    if info and file.origin and file.origin:match("^plugin:") and file.dir then
        -- The pack's own name, from its _meta.lua beside bookshelf_modules.
        pcall(function()
            local meta = dofile(file.dir:gsub("/bookshelf_modules$", "") .. "/_meta.lua")
            if type(meta) == "table" and type(meta.fullname) == "string" then info.label = meta.fullname end
        end)
    end
    return M.groupFor(key, spec, info)
end

-- groupChips(ids, labels) -> the library's chips for the groups in use: All,
-- the categories in their order, packs by name, then the reader's own.
function M.groupChips(ids, labels)
    labels = labels or {}
    local used = {}
    for _i, id in ipairs(ids or {}) do used[id] = true end
    local chips = { { id = "all", label = _("All") } }
    for _i, c in ipairs(M.CATEGORY_ORDER) do
        if used[c] then chips[#chips + 1] = { id = c, label = labels[c] or CATEGORY_LABEL[c]() } end
    end
    local packs = {}
    for id in pairs(used) do if id:match("^pack:") then packs[#packs + 1] = id end end
    table.sort(packs, function(a, b) return (labels[a] or a):lower() < (labels[b] or b):lower() end)
    for _i, id in ipairs(packs) do chips[#chips + 1] = { id = id, label = labels[id] or id:sub(6) } end
    if used.mine then chips[#chips + 1] = { id = "mine", label = labels.mine or _("My modules") } end
    return chips
end

return M
