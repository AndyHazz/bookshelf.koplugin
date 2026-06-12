-- lib/bookshelf_fonts.lua
-- Single resolver for the fonts bookshelf renders its own UI in. In "follow"
-- mode it delegates to KOReader's named faces (byte-identical to stock); when
-- a Bookshelf UI font is chosen it returns that font's face.
--
-- IMPORTANT: KOReader's Font:getFace only resolves a font that lives in
-- ./fonts (KOReader's bundle) or a *scanned* external dir (e.g. /mnt/us/fonts).
-- It cannot load an arbitrary plugin-folder path. So the stored UI font is a
-- *resolvable* font_face -- a bare filename (for our bundled fonts, which
-- ensureInstalled copies into the scanned dir) or whatever path the font
-- picker returns from KOReader's FontList. Icon ("symbols") and mono faces
-- always pass through unchanged.

local Font     = require("ui/font")
local lfs      = require("libs/libkoreader-lfs")
local Settings = require("lib/bookshelf_settings_store")

local M = {}

-- This module's own directory -> the plugin's bundled fonts dir. Used only as
-- the COPY SOURCE for ensureInstalled (io.open reads it fine relative to cwd);
-- never handed to Font:getFace, which can't resolve plugin-folder paths.
local function module_dir()
    local src = debug.getinfo(1, "S").source
    src = src:sub(1, 1) == "@" and src:sub(2) or src
    return src:match("^(.*)/lib/bookshelf_fonts%.lua$") or "."
end
M.PLUGIN_DIR = module_dir()
M.FONT_DIR   = M.PLUGIN_DIR .. "/fonts"

M.SETTING_KEY = "bookshelf_ui_font"     -- stores a resolvable font_face, or absent = follow
M.SEEDED_KEY  = "bookshelf_fonts_seeded"
M.FOLLOW      = "__follow__"            -- legacy sentinel; also treated as follow

-- Bundled fonts: display name -> filenames (regular required).
M.BUNDLED = {
    ["Roboto Condensed"] = {
        regular = "RobotoCondensed-Regular.ttf", bold = "RobotoCondensed-Bold.ttf",
        italic  = "RobotoCondensed-Italic.ttf",  bolditalic = "RobotoCondensed-BoldItalic.ttf",
    },
    ["Inter ExtraBold"] = { regular = "Inter-ExtraBold.ttf" },
    ["Caveat"]          = { regular = "Caveat-Regular.ttf" },
}
M.BUNDLED_ORDER = { "Roboto Condensed", "Inter ExtraBold", "Caveat" }

-- Faces that must never be remapped (icon glyphs, monospace).
local PASSTHROUGH = { symbols = true, scfont = true, infont = true, smallinfont = true, hpkfont = true }
-- Text faces whose default weight is bold (KOReader maps these to NotoSans-Bold).
local BOLD_FACES = { tfont = true, smalltfont = true, x_smalltfont = true, smallinfofontbold = true }

-- Resolvable font_face id for a bundled font (its bare filename). Resolves via
-- the scanned font dir once ensureInstalled has copied it there. Used by the
-- fresh-install seed and the hero title/author defaults.
function M.bundledFaceId(name, variant)
    local b = M.BUNDLED[name]
    if not b then return nil end
    return b[variant or "regular"] or b.regular
end

-- The currently chosen UI font face (a resolvable font_face), or nil for follow.
function M.getUIFontFace()
    local v = Settings.read(M.SETTING_KEY, nil)
    if v == nil or v == M.FOLLOW or v == "" then return nil end
    return v
end
function M.isFollow() return M.getUIFontFace() == nil end

-- Persist the chosen UI font face. nil / FOLLOW / "" -> follow KOReader.
function M.setUIFontFace(face)
    if face == nil or face == M.FOLLOW or face == "" then
        Settings.delete(M.SETTING_KEY)
    else
        Settings.save(M.SETTING_KEY, face)
    end
    Settings.flush()
end

-- Derive the bold sibling of a regular font_face ("-Regular." -> "-Bold."),
-- mirroring KOReader's own bold-variant convention. nil if no substitution.
local function bold_sibling(face)
    local b, n = face:gsub("%-Regular%.", "-Bold.", 1)
    if n > 0 then return b end
    return nil
end

-- Derive the italic sibling: check bundled table first (explicit italic field),
-- then fall back to the "-Regular." -> "-Italic." name convention.
local function italic_sibling(face)
    for _, b in pairs(M.BUNDLED) do
        if b.regular == face and b.italic then return b.italic end
    end
    local it, n = face:gsub("%-Regular%.", "-Italic.", 1)
    if n > 0 then return it end
    return nil
end

-- getFace(face_name, size, opts) -> face, bold
--   opts.bold: whether the caller wanted bold for this text.
-- Returns the face AND the bold flag the widget should use (false when a real
-- bold file is returned, so the widget doesn't faux-bold on top). Always falls
-- back to the native named face if a chosen font can't be resolved -- so a
-- missing/unresolvable font degrades to "follow", never a nil-face crash.
function M:getFace(face_name, size, opts)
    opts = opts or {}
    if PASSTHROUGH[face_name] then
        return Font:getFace(face_name, size), opts.bold
    end
    local ui = M.getUIFontFace()
    if not ui then
        if opts.italic then
            -- Derive italic sibling from the native face's realname so follow
            -- mode uses e.g. NotoSans-Italic rather than hardcoding it.
            local reg = Font:getFace(face_name, size)
            if reg and reg.realname then
                local sib = italic_sibling(reg.realname)
                if sib then
                    local itf = Font:getFace(sib, size)
                    if itf then return itf, false end
                end
            end
        end
        return Font:getFace(face_name, size), opts.bold       -- follow: identical to stock
    end
    local want_bold = opts.bold or BOLD_FACES[face_name] or false
    if want_bold then
        local sib = bold_sibling(ui)
        if sib then
            local bf = Font:getFace(sib, size)
            if bf then return bf, false end                   -- real bold file, no faux bold
        end
        local rf = Font:getFace(ui, size)
        if rf then return rf, true end                        -- no bold file: faux-bold the regular
    elseif opts.italic then
        local sib = italic_sibling(ui)
        if sib then
            local itf = Font:getFace(sib, size)
            if itf then return itf, false end
        end
        local rf = Font:getFace(ui, size)
        if rf then return rf, false end                       -- no italic variant: use regular
    else
        local rf = Font:getFace(ui, size)
        if rf then return rf, false end
    end
    return Font:getFace(face_name, size), opts.bold           -- unresolvable -> native (no crash)
end

-- Writable, KOReader-scanned user font dir per platform.
local function user_font_dir()
    local ok_dev, Device = pcall(require, "device")
    if ok_dev and Device then
        if Device:isKindle()  then return "/mnt/us/fonts" end
        if Device:isAndroid() and Device.home_dir then return Device.home_dir .. "/fonts" end
    end
    local ok_ds, DataStorage = pcall(require, "datastorage")
    if ok_ds and DataStorage then return DataStorage:getDataDir() .. "/fonts" end
    return nil
end

local function copy_file(src, dst)
    local fi = io.open(src, "rb"); if not fi then return false end
    local data = fi:read("*a"); fi:close()
    local fo = io.open(dst, "wb"); if not fo then return false end
    fo:write(data); fo:close()
    return true
end

-- Best-effort: copy any not-yet-present bundled files into the scanned user
-- font dir. This is what makes the bundled fonts resolvable by Font:getFace
-- (and selectable in the font picker). Never raises; returns the count copied.
local _ensure_installed_done = false
function M.ensureInstalled()
    -- Once per session: plugin init re-runs on every FM/Reader
    -- re-instantiation (each book open and close); the bundled files
    -- can't go missing mid-session, so re-statting every variant on
    -- each init is wasted flash I/O. A restart re-checks naturally.
    if _ensure_installed_done then return 0 end
    local dir = user_font_dir()
    if not dir then return 0 end
    _ensure_installed_done = true
    if lfs.attributes(dir, "mode") == nil then pcall(lfs.mkdir, dir) end
    local copied = 0
    for _, name in ipairs(M.BUNDLED_ORDER) do
        local b = M.BUNDLED[name]
        for _, variant in ipairs({ "regular", "bold", "italic", "bolditalic" }) do
            local file = b[variant]
            if file then
                local dst = dir .. "/" .. file
                if lfs.attributes(dst, "mode") == nil then
                    local ok, done = pcall(copy_file, M.FONT_DIR .. "/" .. file, dst)
                    if ok and done then copied = copied + 1 end
                end
            end
        end
    end
    return copied
end

-- One-time: on a genuinely fresh install (no settings file existed at load),
-- seed the fresh-install defaults -- Bookshelf UI font (Roboto Condensed),
-- the hero/detail layout, and author-name formatting (First Last). Existing
-- users (settings file present) are left untouched. Runs once; guarded by
-- SEEDED_KEY.
function M.maybeSeedFreshInstall()
    if Settings.read(M.SEEDED_KEY, false) then return end
    if not Settings.wasPresent() then            -- no prior settings file => fresh install
        Settings.save(M.SETTING_KEY, M.bundledFaceId("Roboto Condensed"))
        Settings.save("author_format", "first_last")
        local ok, Regions = pcall(require, "lib/bookshelf_hero_regions")
        if ok and Regions and Regions.applyFreshInstallDefaults then
            Regions.applyFreshInstallDefaults()
        end
    end
    Settings.save(M.SEEDED_KEY, true)
    Settings.flush()
end

return M
