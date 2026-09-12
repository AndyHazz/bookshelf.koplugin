-- bookshelf_wallpaper.lua
-- A background image behind the whole screen, chosen PER SHELF.
--
-- ── WHY PER SHELF ───────────────────────────────────────────────────────────
--
-- Every UI plugin that has wallpaper has one wallpaper. Bookshelf's unit is
-- the shelf, not the screen: a chip already carries its own view mode, folder
-- tile style, densities and spine settings, so a chip carrying its own
-- backdrop is the same idea one step further, and it is the reason to do this
-- at all rather than copy what already exists elsewhere (maintainer's call).
-- Genres can be a library, Recent can be a desk, and neither has to agree.
--
-- Three states, using the convention already established by the per-book
-- facts store and the chip pins, so there is one rule and not three:
--
--     a string   this shelf shows that file
--     false      this shelf shows NOTHING, even if the library has a default
--     absent     this shelf follows the library default
--
-- ── WHERE THE FILES LIVE ────────────────────────────────────────────────────
--
-- <KOReader settings dir>/bookshelf/wallpapers/. Not icons/, where the
-- ornaments live: that folder was chosen because ornaments genuinely are the
-- small vector assets KOReader keeps there, and a full-screen photograph is
-- not. This mirrors where SimpleUI keeps its own
-- (settings/simpleui/sui_wallpapers), which is the convention a reader who
-- has used one is most likely to expect from the other.
--
-- ── WHAT THIS MODULE DOES NOT DO ────────────────────────────────────────────
--
-- It does not decide whether a wallpaper is legible, or paint a scrim, or
-- know anything about the widgets it sits behind. It answers "which file,
-- and give me a widget for it at this size", and the shelf does the rest.

local logger = require("logger")
local AssetFolder = require("lib/bookshelf_asset_folder")

local M = {}

-- Everything RenderImage can decode and a reader is likely to have. No SVG:
-- a wallpaper is a photograph or a texture, and nanosvg at full-screen size
-- is a very different cost from an ornament at 100px.
M.EXT_LIST = { "png", "jpg", "jpeg", "bmp", "gif", "webp" }
local EXTS = AssetFolder.extsFromList(M.EXT_LIST)

M.SUBDIR    = "bookshelf/wallpapers"
-- The per-chip key, stored on the tab beside view_mode and the densities.
M.CHIP_KEY  = "wallpaper"
-- The library default, in Bookshelf's own settings.
M.SETTING   = "wallpaper_default"

M._data_dir = nil          -- override for the data dir (tests)
M._lfs      = nil          -- lazily required
M._render   = nil          -- function(path, w, h) -> bb (tests)

local function lfs()
    if M._lfs then return M._lfs end
    local ok, l = pcall(require, "libs/libkoreader-lfs")
    if ok then M._lfs = l end
    return M._lfs
end

function M.dataDir()
    if M._data_dir then return M._data_dir end
    local ok, DataStorage = pcall(require, "datastorage")
    if ok and DataStorage then return DataStorage:getSettingsDir() end
    return nil
end

function M.dir()
    local base = M.dataDir()
    if not base then return nil end
    return base .. "/" .. M.SUBDIR
end

-- ensureDir() -- create the folder (and its parent) so a reader has somewhere
-- to put files. Cheap and idempotent; called before any scan.
M._ensured = false
function M.ensureDir()
    if M._ensured then return end
    local d, fs = M.dir(), lfs()
    if not (d and fs) then return end
    M._ensured = true
    local parent = d:match("^(.*)/[^/]+$")
    if parent and fs.attributes(parent, "mode") ~= "directory" then
        pcall(fs.mkdir, parent)
    end
    if fs.attributes(d, "mode") ~= "directory" then
        pcall(fs.mkdir, d)
    end
end

-- ── which file ─────────────────────────────────────────────────────────────

-- resolve(chip_value, default_value) -> name or nil
--
-- Pure: names only, no filesystem. pathFor turns a name into something to
-- open, and is where a file that has since been deleted drops out.
function M.resolve(chip_value, default_value)
    if chip_value == false then return nil end
    if type(chip_value) == "string" and chip_value ~= "" then
        return chip_value
    end
    if type(default_value) == "string" and default_value ~= "" then
        return default_value
    end
    return nil
end

-- pathFor(name) -> absolute path, or nil if there is no such wallpaper.
--
-- The folder is the whole namespace. A name carrying a separator is refused
-- rather than resolved, because these names come out of settings and a
-- settings file is something a reader can hand-edit -- the same reasoning
-- that produced the updater's traversal fix.
function M.pathFor(name)
    if type(name) ~= "string" or name == "" then return nil end
    if name:find("/", 1, true) or name:find("\\", 1, true) then return nil end
    if name == "." or name == ".." then return nil end
    local d, fs = M.dir(), lfs()
    if not (d and fs) then return nil end
    local path = d .. "/" .. name
    if fs.attributes(path, "mode") ~= "file" then return nil end
    return path
end

-- ── what is on offer ───────────────────────────────────────────────────────

-- list() -> { { name, label, path }, ... } sorted by name.
--
-- label is the filename without its extension: the picker shows a name, not
-- a filename. Cached on the folder's contents, not on its mtime alone -- see
-- lib/bookshelf_asset_folder.lua for the two ways that goes wrong.
M._list_cache = nil
M._list_key   = nil
function M.list()
    M.ensureDir()
    local d, fs = M.dir(), lfs()
    if not (d and fs) then return {} end
    local names, key = AssetFolder.scan(fs, d, EXTS)
    if not names then return {} end
    if M._list_cache and M._list_key == key then return M._list_cache end
    local out = {}
    for _i = 1, #names do
        local name = names[_i]
        out[#out + 1] = {
            name  = name,
            label = name:match("^(.+)%.[^%.]+$") or name,
            path  = d .. "/" .. name,
        }
    end
    M._list_cache, M._list_key = out, key
    return out
end

-- ── chrome that must stop painting its own page ────────────────────────────

-- unfill(active, ...) -> the same widgets, so it can wrap a build inline.
--
-- KOReader's Button has no transparent mode. It builds a FrameContainer with
-- background = COLOR_WHITE unless given a colour, and a colour drops the
-- border and rounds the corners -- so "see-through" is not something the
-- constructor can express. Clearing frame.background afterwards is the way,
-- and it is what Button itself does for its own borderless state (it stashes
-- orig_background and nils the field). FrameContainer then skips the fill:
-- `if self.background then`.
--
-- Gated on `active` rather than done unconditionally, because on a plain page
-- the white fill is CORRECT: it is what makes a button read as a button
-- against the paper. This only applies when there is something behind it.
function M.unfill(active, ...)
    if not active then return ... end
    for i = 1, select("#", ...) do
        local w = select(i, ...)
        if type(w) == "table" and type(w.frame) == "table" then
            w.frame.background = nil
        end
    end
    return ...
end

-- ── the widget ─────────────────────────────────────────────────────────────

-- ONE cached entry, deliberately. A full-screen bitmap is ~2MB as greyscale
-- (measured on a PW5: 1236x1648 comes back BB8) and ~8MB as RGB32; holding a
-- handful so that flipping between shelves never re-decodes would cost more
-- memory than this plugin has any business taking, on devices where running
-- out of it is a live bug (issue 388). One entry means a shelf switch
-- re-decodes, which is the trade to measure before widening.
M._bg     = nil
M._bg_key = nil

function M.free()
    if M._bg and M._bg.bb then
        pcall(function() if M._bg.bb.free then M._bg.bb:free() end end)
    end
    M._bg, M._bg_key = nil, nil
end

-- RenderImage straight to a blitbuffer, NOT an ImageWidget.
--
-- ImageWidget was the obvious choice and did not work: on a PW5 it built
-- happily -- the widget was constructed, inserted and logged -- and then
-- painted nothing at all, whether it sat at the bottom of the overlap group
-- or on top of everything. RenderImage reads the very same file, by the very
-- same relative path, into a 1236x1648 BB8 without complaint, so the file and
-- the decoder were never in question.
--
-- Rather than keep chasing it, this uses the path the ornaments already prove
-- on this hardware every time a plant appears on a shelf. It also buys
-- explicit control of the night pre-invert and a memory figure that can be
-- stated rather than guessed.
--
-- SCALING IS A STRETCH TO THE SCREEN, for now. Choosing between stretch and
-- letterbox needs the image's NATIVE size, and there is no cheap way to get
-- it: RenderImage decodes to whatever size you ask for, and every Pic.open*
-- decodes the whole image. Reading it out of the file header is the answer
-- (the ornaments module already parses PNG IHDR for exactly this) but it is a
-- per-format parser each, so it is its own piece of work rather than a
-- rider on this one.
local function decode(path, w, h)
    local RenderImage = require("ui/renderimage")
    return RenderImage:renderImageFile(path, false, w, h)
end

-- A background is a plain opaque blit: it is the bottom of the stack, there is
-- nothing behind it to blend with, and blitFrom is markedly cheaper than the
-- alpha path over a full screen.
local Background = nil
local function backgroundWidget(bb, w, h)
    if not Background then
        local Widget = require("ui/widget/widget")
        Background = Widget:extend{ bb = nil, w = 0, h = 0 }
        function Background:init()
            self.dimen = require("ui/geometry"):new{ w = self.w, h = self.h }
        end
        function Background:paintTo(target, x, y)
            self.dimen.x, self.dimen.y = x, y
            if not self.bb then return end
            pcall(function()
                target:blitFrom(self.bb, x, y, 0, 0, self.w, self.h)
            end)
        end
    end
    return Background:new{ bb = bb, w = w, h = h }
end

-- bg(name, w, h, night) -> a paintable full-screen widget, or nil.
--
-- night is part of the key AND of the render: the panel inverts everything at
-- refresh, so a wallpaper that should look like itself has to be painted
-- pre-inverted, exactly as a cover is. Same reasoning as the ornaments'
-- faithful mode.
function M.bg(name, w, h, night)
    local path = M.pathFor(name)
    if not path or not w or not h or w <= 0 or h <= 0 then return nil end
    local key = path .. "|" .. w .. "x" .. h .. (night and "|n" or "")
    if M._bg and M._bg_key == key then return M._bg end
    M.free()
    local ok, bb = pcall(decode, path, w, h)
    if not ok or not bb then
        logger.info("[bookshelf] wallpaper could not be decoded:", path)
        return nil
    end
    if night and bb.invertRect then
        pcall(function() bb:invertRect(0, 0, bb:getWidth(), bb:getHeight()) end)
    end
    local widget = backgroundWidget(bb, w, h)
    widget.bb = bb
    M._bg, M._bg_key = widget, key
    return widget
end

return M
