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

-- eraser(active, w, h) -> a widget that paints the wallpaper back over its own
-- rect, or nil when there is no wallpaper.
--
-- For chrome that is opaque ON PURPOSE because it has to hide what is beneath
-- it -- the start menu's close X sits exactly over the hamburger and must
-- replace it, not sit on top of it. On paper a white fill does that. Over a
-- wallpaper the same fill is a white box, so the erasing is done by putting
-- the image's own pixels back and then drawing the glyph over them.
--
-- Returns nil rather than a no-op widget so callers can keep their opaque
-- background in the plain case, where it is both correct and cheaper.
local Eraser = nil
function M.eraser(active, w, h)
    if not active or not w or not h or w <= 0 or h <= 0 then return nil end
    if not Eraser then
        local Widget = require("ui/widget/widget")
        Eraser = Widget:extend{ w = 0, h = 0 }
        function Eraser:init()
            self.dimen = require("ui/geometry"):new{ w = self.w, h = self.h }
        end
        function Eraser:paintTo(target, x, y)
            self.dimen.x, self.dimen.y = x, y
            M.restore(target, x, y, self.w, self.h)
        end
    end
    return Eraser:new{ w = w, h = h }
end

-- restore(target, x, y, w, h) -> true if the wallpaper was put back there.
--
-- For chrome that CUTS a shape by painting the page ground back over itself --
-- the shelf plank's chamfered ends, a book's eased foot corners. On a plain
-- page "the ground" is a colour you can just paint. Over a wallpaper it is a
-- photograph, and the only honest way to cut a corner is to put back exactly
-- the pixels that were there.
--
-- Which is easy, because the cached image is full-screen and painted at 0,0:
-- screen (x, y) IS wallpaper (x, y), so a corner is one small blit from the
-- same coordinates.
--
-- REFUSES an offscreen target. A widget that renders into its own buffer (a
-- spine slot does) passes coordinates relative to that buffer, and blitting
-- the screen-indexed wallpaper into it would paste the wrong part of the
-- picture. Comparing dimensions is a cheap, self-validating way to tell the
-- two apart, and returning false lets the caller keep its old behaviour.
function M.restore(target, x, y, w, h)
    local bg = M._bg
    if not (bg and bg.bb and target and w and h) then return false end
    if w <= 0 or h <= 0 then return false end
    if target.getWidth == nil or target.getHeight == nil then return false end
    if target:getWidth() ~= bg.w or target:getHeight() ~= bg.h then return false end
    local ok = pcall(function()
        target:blitFrom(bg.bb, x, y, x, y, w, h)
    end)
    return ok and true or false
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
        if type(w) == "table" then
            if type(w.frame) == "table" then
                w.frame.background = nil
            end
            -- AND the icon, which is the other half and the less obvious one.
            -- ImageWidget defaults to alpha = false, and Button builds its
            -- IconWidget without setting it, so a chevron's SVG is FLATTENED
            -- onto white and blitted opaquely. Clearing the frame's fill alone
            -- leaves a white square the exact size of the icon -- which is
            -- precisely what it looked like on device, and why the page
            -- counter (text, no icon) came out clean while every chevron did
            -- not.
            local icon = w.label_widget
            -- A DISABLED icon dims by lightening its whole RECT
            -- (ImageWidget: `if self.dim then bb:lightenRect(...)`), which on
            -- paper greys a black glyph and over a wallpaper washes a pale
            -- square out of the image instead. KOReader knows: the comment
            -- right above that line says the fix would be "to take the icon
            -- pixmap as an alpha-mask ... and colorBlit it a dim gray onto
            -- the target bb", which is exactly M.mask. So do that, in the
            -- same COLOR_DARK_GRAY Button already dims its TEXT to.
            if type(icon) == "table" and w.enabled == false and icon.dim then
                icon.dim = false
                local lc = w.label_container
                if type(lc) == "table" and lc[1] == icon then
                    local Blitbuffer = require("ffi/blitbuffer")
                    lc[1] = M.mask(true, icon, Blitbuffer.COLOR_DARK_GRAY)
                end
            end
            if type(icon) == "table" and icon.alpha == false then
                icon.alpha = true
                -- ImageWidget keys its render cache on the alpha flag, so a
                -- bitmap rendered flat before this point would not be reused
                -- anyway; dropping it just makes that explicit rather than
                -- relying on the hash.
                if icon._bb and icon._bb_disposable and icon._bb.free then
                    pcall(function() icon._bb:free() end)
                end
                icon._bb = nil
            end
        end
    end
    return ...
end

-- mask(active, inner, fgcolor) -> a widget, or `inner` untouched.
--
-- The answer to the one surface a wallpaper cannot simply be placed behind:
-- text. TextBoxWidget renders into its own buffer, fills it with bgcolor
-- (white) and blits it OPAQUELY; the HTML widgets are worse still, because
-- MuPDF hands back a page, not a picture with holes in it. Neither has a
-- transparent mode.
--
-- But an opaque render of dark text on a white page IS a glyph-coverage mask,
-- just the wrong way round. colorblitFrom uses the source's 8-bit grey VALUE
-- as alpha (setPixelColorize: `local alpha = mask:getColor8().a`), so:
--
--     paint the widget onto white  ->  glyphs dark, page white
--     invert                       ->  glyphs bright, page black
--     colorblitFrom(mask, colour)  ->  glyphs painted, page contributes 0
--
-- Anti-aliasing survives intact, because a half-covered edge pixel becomes a
-- half alpha. Measured against real blitbuffers before this was written: an
-- edge at grey 201 over a ground of 71 came out at exactly 56 in black and
-- 110 in white, both matching the arithmetic to the integer.
--
-- fgcolor defaults to BLACK because this plugin paints in PRE-INVERT space:
-- black here displays white once the panel inverts in night mode, which is
-- the same rule the rest of the shelf follows.
--
-- THE LIMIT, worth knowing before using it somewhere new: a mask has one
-- colour. Bold and italic survive (they are glyph shapes) but anything that
-- relied on being a DIFFERENT colour is flattened to a density of this one.
-- For book text -- prose, outlined pills, a progress bar -- that is fine.
--
-- The mask is built once per wrapper instance and kept. These wrappers are
-- created by a layout build and die with it, so that is once per rebuild
-- rather than once per frame.
local Mask = nil
function M.mask(active, inner, fgcolor)
    if not active or type(inner) ~= "table" then return inner end
    if not Mask then
        local Widget = require("ui/widget/widget")
        Mask = Widget:extend{ inner = nil, fgcolor = nil, _mask = nil }
        function Mask:init()
            self.dimen = self.inner:getSize()
        end
        function Mask:getSize() return self.inner:getSize() end
        function Mask:_build()
            local Blitbuffer = require("ffi/blitbuffer")
            local sz = self.inner:getSize()
            if not sz or sz.w <= 0 or sz.h <= 0 then return nil end
            -- BB8: a mask is a single channel by definition, and one byte per
            -- pixel is a quarter of what RGB32 would cost for the same answer.
            local scratch = Blitbuffer.new(sz.w, sz.h, Blitbuffer.TYPE_BB8)
            scratch:fill(Blitbuffer.COLOR_WHITE)
            self.inner:paintTo(scratch, 0, 0)
            scratch:invertRect(0, 0, sz.w, sz.h)
            return scratch
        end
        function Mask:paintTo(target, x, y)
            if not self._mask then
                local ok, m = pcall(self._build, self)
                if not ok or not m then
                    -- Better an opaque block of readable text than nothing.
                    return self.inner:paintTo(target, x, y)
                end
                self._mask = m
            end
            self.dimen.x, self.dimen.y = x, y
            local m = self._mask
            pcall(function()
                target:colorblitFrom(m, x, y, 0, 0,
                                     m:getWidth(), m:getHeight(), self.fgcolor)
            end)
        end
        function Mask:free()
            if self._mask then
                pcall(function() if self._mask.free then self._mask:free() end end)
                self._mask = nil
            end
            if self.inner and self.inner.free then pcall(function() self.inner:free() end) end
        end
        Mask.onCloseWidget = Mask.free
    end
    local Blitbuffer = require("ffi/blitbuffer")
    return Mask:new{ inner = inner, fgcolor = fgcolor or Blitbuffer.COLOR_BLACK }
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
