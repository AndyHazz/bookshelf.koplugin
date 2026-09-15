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

local function loadSpec(dir, fname, origin)
    local ok, spec = pcall(dofile, dir .. "/" .. fname)
    if not ok then
        logger.warn("[bookshelf] micro-module failed to load, skipping:",
            fname, spec)
        return
    end
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

local function scan()
    if scanned then return end
    -- Kill switch: when every micro-module surface (start menu / hero /
    -- full-screen) is off, skip discovery entirely so no module file is even
    -- dofile'd. Re-attempts when a surface is turned back on (scanned stays
    -- false). pcall + explicit `== false` so the standalone test runner (no
    -- settings store) and any read error fall through to scanning, never block.
    local ok_any, any = pcall(function()
        return require("lib/bookshelf_settings_store").microAnyEnabled()
    end)
    if ok_any and any == false then return end
    scanned = true
    -- User dir FIRST so a user module overrides a bundled one of the same key
    -- (first-registered wins), and survives plugin updates; then the bundled
    -- modules. Either dir may be absent - scanDir tolerates that.
    scanDir(userModulesDir(), "user")
    scanDir(modulesDir(), "bundled")
end

-- Additive registration for callers that build specs in code (kept for
-- API stability; file-based modules in micromodules/ are preferred).
function M.register(key, def) registry[key] = def end
function M.get(key)
    scan()
    return registry[key]
end
function M.title(key)
    scan()
    local d = registry[key]
    return d and d.title
end
function M.keys()
    scan()
    local out = {}
    for k in pairs(registry) do out[#out + 1] = k end
    table.sort(out)
    return out
end

M._test = { scanDir = scanDir, registry = registry }
return M
