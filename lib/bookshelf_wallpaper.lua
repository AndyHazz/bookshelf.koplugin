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
-- not. Other home-screen tools keep theirs the same way, beside their own
-- (settings/simpleui/sui_wallpapers), which is the convention a reader who
-- has used one is most likely to expect from the other.
--
-- ── WHAT THIS MODULE DOES NOT DO ────────────────────────────────────────────
--
-- It does not decide whether a wallpaper is legible, or paint a scrim, or
-- know anything about the widgets it sits behind. It answers "which file,
-- and give me a widget for it at this size", and the shelf does the rest.

local logger = require("logger")
local _ = require("lib/bookshelf_i18n").gettext
local _gettime
do
    local ok, sock = pcall(require, "socket")
    _gettime = (ok and sock and type(sock.gettime) == "function")
        and function() return sock.gettime() end
        or  os.clock
end
local AssetFolder = require("lib/bookshelf_asset_folder")

local M = {}

-- Everything RenderImage can decode and a reader is likely to have. No SVG:
-- a wallpaper is a photograph or a texture, and nanosvg at full-screen size
-- is a very different cost from an ornament at 100px.
M.EXT_LIST = { "png", "jpg", "jpeg", "bmp", "gif", "webp" }
local EXTS = AssetFolder.extsFromList(M.EXT_LIST)

M.SUBDIR    = "bookshelf/wallpapers"
-- The library default, in Bookshelf's own settings.
M.SETTING   = "wallpaper_default"

-- ── The page ground ────────────────────────────────────────────────────────
--
-- What the screen is where no wallpaper reaches: the whole page when no
-- wallpaper is set, and anything a picture does not cover. Stored in the
-- same {grey=} / {hex=} shape as every other Bookshelf colour, so the shared
-- picker and its day/night key suffix work unchanged.
M.BG_SETTING = "wallpaper_bg"


-- ── Transparent buttons ────────────────────────────────────────────────────
--
-- OFF by default (maintainer's call). Chrome that goes see-through reads well
-- over a calm texture and badly over a busy photograph, and the safe default
-- for something that affects legibility is the one that keeps contrast. Covers
-- the shelf menu bar's chips and the hero's tag pills.
M.BUTTONS_SETTING = "wallpaper_transparent_buttons"

function M.transparentButtons(read)
    if type(read) ~= "function" then return false end
    return read(M.BUTTONS_SETTING) and true or false
end


-- ── Chrome scrim ───────────────────────────────────────────────────
--
-- A solid panel behind the top panel and footer defeats the wallpaper, and a
-- border around each shape is not enough separation over a busy photograph.
-- What works is what a phone OS does: tint the strip, leave the picture
-- readable through it.
--
-- Blitbuffer gives us that for one C call. blendRectRGB32 composites a colour
-- OVER the rect at its alpha, via BB_blend_RGB32_over_rect, so the cost does
-- not scale with how many shapes sit on top. It subsumes the two states we
-- already had: alpha 0xFF is the solid fill, alpha 0 is transparent buttons.
--
-- NO DAY/NIGHT BRANCH, and that is not an oversight. The panel inverts the
-- whole frame in night mode and the wallpaper is pre-inverted to match (see
-- M.bg), so painted 0xFF is the page ground in BOTH modes -- white by day,
-- black at night. Tinting toward chrome_bg therefore always moves the strip
-- toward the ground colour the chrome was drawn for. Same reasoning as the
-- night card shadow's #D9D9D9.
M.SCRIM_SETTING = "wallpaper_chrome_scrim"

-- Fraction of chrome_bg to blend over the strip. Heavy rather than Medium:
-- 0.6 leaves the picture legible under the chrome, but "legible under" is not
-- the same as "legible", and which it turns out to be depends entirely on the
-- picture the reader chose. A busy or high-contrast one puts detail straight
-- through the chip labels. 0.85 still shows the picture through the strip and
-- is safe with any of them (maintainer: "safer legibility"). Anyone who wants
-- more of their wallpaper can turn it down; nobody has to discover that they
-- need to.
M.SCRIM_DEFAULT = 0.85

-- scrimStrength(read) -> 0..1
--
-- Transparent buttons is the zero point rather than a separate code path, so
-- there is only ever one question at the paint site: how much to tint.
function M.scrimStrength(read)
    if type(read) ~= "function" then return M.SCRIM_DEFAULT end
    if M.transparentButtons(read) then return 0 end
    local v = read(M.SCRIM_SETTING)
    if type(v) ~= "number" then return M.SCRIM_DEFAULT end
    if v < 0 then return 0 end
    if v > 1 then return 1 end
    return v
end

-- _roundedSpans(x, y, w, h, r) -> a list of {x, y, w, h} rows that tile a
-- rounded rectangle EXACTLY ONCE each.
--
-- Blitbuffer has paintRoundedRect but no blended equivalent, and the obvious
-- workaround -- blend the body, then blend the corners -- is wrong: every
-- pixel in the overlap gets the tint twice and the corners come out darker
-- than the panel they belong to. Tiling by row means each pixel is written
-- once, so a 60% tint is 60% everywhere.
--
-- Rows only, no anti-aliasing. These panels sit on a 16-level greyscale e-ink
-- screen over a photograph, where a one-pixel stair step is invisible and a
-- feathered edge would just look like a smudge.
-- One table, reused, for the square case. _roundedSpans is called for every
-- panel and every band of the shelf recess -- several dozen times a frame --
-- and the square answer is always the same one-element list. Callers iterate
-- it and are done with it before the next call, so there is nothing to alias.
local _SQUARE = { { } }

local function _roundedSpans(x, y, w, h, r)
    r = math.min(r or 0, math.floor(w / 2), math.floor(h / 2))
    if r <= 0 then
        local sp = _SQUARE[1]
        sp.x, sp.y, sp.w, sp.h = x, y, w, h
        return _SQUARE
    end

    local spans = {}
    for i = 0, r - 1 do
        -- Distance from the corner circle's centre to this row's midline.
        local dy = r - i - 0.5
        local inset = math.floor(r - math.sqrt(r * r - dy * dy) + 0.5)
        local sw = w - inset * 2
        if sw > 0 then
            spans[#spans + 1] = { x = x + inset, y = y + i,         w = sw, h = 1 }
            spans[#spans + 1] = { x = x + inset, y = y + h - 1 - i, w = sw, h = 1 }
        end
    end
    local mid_h = h - r * 2
    if mid_h > 0 then
        spans[#spans + 1] = { x = x, y = y + r, w = w, h = mid_h }
    end
    return spans
end
M._roundedSpans = _roundedSpans

-- isShowing() -> is a wallpaper on screen right now?
--
-- The decoded backdrop is the only honest answer: a name can be set for an
-- image that has since been deleted or failed to decode, and chrome that
-- adapts itself for a picture that is not there looks broken on a plain page.
function M.isShowing()
    return (M._bg ~= nil)
end

-- shade(bb, x, y, w, h, strength, night, radius) -> true if it painted.
--
-- A drop shadow over a picture. Unlike scrim this DOES branch on night, and
-- the difference is worth stating because the two look like the same job.
--
-- A panel tints toward the page ground, and the page ground is one painted
-- value in both modes (0xFF), so scrim needs no branch. A shadow has to come
-- out DARKER THAN WHATEVER IS BEHIND IT on screen -- and "darker on screen"
-- is a lower painted value by day and a HIGHER one at night, because the
-- panel inverts the frame. Opposite directions, hence the branch.
--
-- Which is also why a shadow cannot be a fixed colour over a picture: the
-- shipped grey reads as a shadow on white paper and as a HIGHLIGHT over a
-- dark wallpaper, because it is lighter than the thing it falls on. Blending
-- pure black (or white) at a fraction is relative to what is there, so it
-- darkens anything.
-- shadeRect(bb, x, y, w, h, strength, night) -> the direct form: one rect,
-- no radius, no pcall, no span table. For callers that issue thousands per
-- paint from inside a pcall of their own (the recess painter: ~2000 bands
-- per spine page), where shade()'s per-call wrapping WAS the cost.
--
-- Both forms refuse a buffer whose C blitter is unavailable
-- (bb:canUseCbb() false, the flip flag being set on a device that cannot
-- flip in hardware): darkenRect/lightenRect are then per-pixel Lua, and a
-- missing shadow beats a paint measured in seconds.
function M.shadeRect(bb, x, y, w, h, strength, night)
    if not bb then return false end
    if not w or not h or w <= 0 or h <= 0 then return false end
    if not strength or strength <= 0 then return false end
    if strength > 1 then strength = 1 end
    if type(bb.canUseCbb) == "function" and not bb:canUseCbb() then return false end
    local op = night and bb.lightenRect or bb.darkenRect
    if not op then return false end
    op(bb, x, y, w, h, strength)
    return true
end

-- shadeClipped(bb, x, y, w, h, strength, night, radius, clips) -> true
--
-- Shades (the rounded rect) INTERSECTED WITH (the union of clips), each
-- clip a { x, y, w, h }. For a shadow that something opaque is about to
-- cover almost entirely: a cover tile's shadow is its own size, and the
-- card then hides all but an L-shaped margin, so blending the whole rect
-- was a read-modify-write of the framebuffer twenty times larger than what
-- shows. Clips must be disjoint, or the overlap is darkened twice. No
-- clips: plain shade.
function M.shadeClipped(bb, x, y, w, h, strength, night, radius, clips)
    if type(clips) ~= "table" or #clips == 0 then
        return M.shade(bb, x, y, w, h, strength, night, radius)
    end
    if not bb then return false end
    if not w or not h or w <= 0 or h <= 0 then return false end
    if not strength or strength <= 0 then return false end
    if strength > 1 then strength = 1 end
    if type(bb.canUseCbb) == "function" and not bb:canUseCbb() then return false end
    local op = night and bb.lightenRect or bb.darkenRect
    if not op then return false end
    local spans = _roundedSpans(x, y, w, h, radius)
    for i = 1, #spans do
        local sp = spans[i]
        for k = 1, #clips do
            local c  = clips[k]
            local x0 = math.max(sp.x, c.x)
            local y0 = math.max(sp.y, c.y)
            local x1 = math.min(sp.x + sp.w, c.x + c.w)
            local y1 = math.min(sp.y + sp.h, c.y + c.h)
            if x1 > x0 and y1 > y0 then op(bb, x0, y0, x1 - x0, y1 - y0, strength) end
        end
    end
    return true
end

function M.shade(bb, x, y, w, h, strength, night, radius)
    if not bb then return false end
    if not w or not h or w <= 0 or h <= 0 then return false end
    if not strength or strength <= 0 then return false end
    if strength > 1 then strength = 1 end
    if type(bb.canUseCbb) == "function" and not bb:canUseCbb() then return false end
    local op = night and bb.lightenRect or bb.darkenRect
    if not op then return false end
    return pcall(function()
        for _i, sp in ipairs(_roundedSpans(x, y, w, h, radius)) do
            op(bb, sp.x, sp.y, sp.w, sp.h, strength)
        end
    end)
end

-- scrim(bb, x, y, w, h, colour, strength, radius) -> true if it painted.
--
-- Tolerant by design: this runs inside paintTo, where an error takes the whole
-- shelf down, and a missing scrim is a cosmetic loss not a broken screen.
-- The blitbuffer module, looked up once per module identity. scrim runs
-- several hundred times a frame through _reshade; a pcall(require) on each
-- was measurable. Re-checked against package.loaded so the headless tests,
-- which install their stub after this file is read, still see it.
local _bb_mod, _bb_seen = nil, nil
local function _blitbuffer()
    local cur = package.loaded["ffi/blitbuffer"]
    if _bb_mod ~= nil and _bb_seen == cur then return _bb_mod end
    local ok, B = pcall(require, "ffi/blitbuffer")
    _bb_mod, _bb_seen = (ok and B) or false, package.loaded["ffi/blitbuffer"]
    return _bb_mod
end

function M.scrim(bb, x, y, w, h, colour, strength, radius)
    if not bb or not colour then return false end
    if not w or not h or w <= 0 or h <= 0 then return false end
    strength = strength or M.SCRIM_DEFAULT
    if strength <= 0 then return false end

    local Blitbuffer = _blitbuffer()
    if not Blitbuffer or not Blitbuffer.ColorRGB32 then return false end

    local ok = pcall(function()
        local c = colour.getColorRGB32 and colour:getColorRGB32() or colour
        local alpha = math.floor(255 * strength + 0.5)
        if alpha > 255 then alpha = 255 end
        local tint = Blitbuffer.ColorRGB32(c:getR(), c:getG(), c:getB(), alpha)
        -- blendRectRGB32 is C only while canUseCbb() holds. When the buffer
        -- carries the flip flag the C blitter refuses it (a dark display on
        -- a device that cannot flip in hardware, and the desktop emulator)
        -- and the blend is a per-pixel Lua loop: the top panel is ~588k
        -- pixels of it per paint. Opaque there, translucent everywhere else.
        local no_cbb = type(bb.canUseCbb) == "function" and not bb:canUseCbb()
        local opaque = alpha >= 255 or not bb.blendRectRGB32 or no_cbb
        local spans = _roundedSpans(x, y, w, h, radius)
        for _i, s in ipairs(spans) do
            if opaque then
                bb:paintRect(s.x, s.y, s.w, s.h, colour)
            else
                bb:blendRectRGB32(s.x, s.y, s.w, s.h, tint)
            end
        end
    end)
    return ok
end


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
-- Pictures shipped with the plugin, copied in the first time the folder is
-- made. A wallpaper folder that starts empty documents nothing: the reader has
-- to already know the feature exists, find the folder, and guess what belongs
-- in it. One picture in place answers all three.
--
-- Seeded ONLY when the folder is created, never topped up, so a reader who
-- deletes one does not find it back next launch -- the same rule the ornament
-- template follows.
M.SEED_SUBDIR = "assets/wallpapers"

-- copyFile(src, dst) -> true if the bytes landed.
--
-- Block-wise rather than a single read: these are ~500KB JPEGs and the whole
-- point of doing this at folder-creation time is that it happens once, so
-- there is no reason to hold the entire file in memory to do it.
local function copyFile(src, dst)
    local fi = io.open(src, "rb")
    if not fi then return false end
    local fo = io.open(dst, "wb")
    if not fo then fi:close(); return false end
    local ok = true
    while true do
        local chunk = fi:read(64 * 1024)
        if not chunk then break end
        if not fo:write(chunk) then ok = false; break end
    end
    fi:close()
    fo:close()
    return ok
end

-- seedDir(d) -- copy the shipped pictures into a freshly made folder.
--
-- Silent on every failure: a missing seed folder (a source checkout that never
-- ran the build, say) is not a reason to keep a reader out of the feature.
function M.seedDir(d)
    local fs = lfs()
    if not (d and fs) then return end
    -- This file's own directory, the idiom bookshelf_i18n and
    -- start_menu_modules already use -- it resolves whether the plugin was
    -- loaded by absolute path (the device) or relative (the test runner).
    -- One level up from lib/ is the plugin root.
    local libdir = debug.getinfo(1, "S").source:match("^@(.+/)") or "./"
    local from = libdir .. "../" .. M.SEED_SUBDIR
    if fs.attributes(from, "mode") ~= "directory" then return end
    local ok_iter, iter = pcall(fs.dir, from)
    if not ok_iter then return end
    for name in iter do
        local ext = name:match("%.([^%.]+)$")
        if name ~= "." and name ~= ".." and ext and EXTS[ext:lower()] then
            pcall(copyFile, from .. "/" .. name, d .. "/" .. name)
        end
    end
end

function M.ensureDir()
    if M._ensured then return end
    local d, fs = M.dir(), lfs()
    if not (d and fs) then return end
    M._ensured = true
    local parent = d:match("^(.*)/[^/]+$")
    if parent and fs.attributes(parent, "mode") ~= "directory" then
        pcall(fs.mkdir, parent)
    end
    -- Seed only on CREATION: existing readers keep whatever they have, and a
    -- deleted seed stays deleted.
    if fs.attributes(d, "mode") ~= "directory" then
        pcall(fs.mkdir, d)
        if fs.attributes(d, "mode") == "directory" then
            pcall(M.seedDir, d)
        end
    end
end

-- ── which file ─────────────────────────────────────────────────────────────

-- FULL_SETTING -- a second library-wide image, for full screen shelves only.
--
-- The two views want different backdrops: the top panel is mostly text over
-- the picture, while full screen shelves are wall-to-wall covers and spines,
-- and a backdrop that reads well behind one is often wrong behind the other.
M.FULL_SETTING = "wallpaper_full"

-- resolveFor(full_value, default_value, is_full) -> name or nil
--
-- Pure: names only, no filesystem. pathFor turns a name into something to
-- open, and is where a file that has since been deleted drops out.
--
-- There WAS a third, more specific source here: a per-shelf image, picked in
-- the chip editor. It was removed rather than fixed. Changing the backdrop on
-- a chip tap means the whole screen has to repaint, and the shelf's refreshes
-- are regional by design, so moving between two chips with different pictures
-- left stale rectangles behind. The same hazard applies to the full screen
-- image below, which is why that switch goes through a full repaint.
function M.resolveFor(full_value, default_value, is_full)
    -- Three states for the full screen image, not two: unset means "same as
    -- the default", false means "no picture in this view". Treating false as
    -- unset would make None unreachable for full screen shelves.
    if is_full then
        if full_value == false then return nil end
        if type(full_value) == "string" and full_value ~= "" then
            return full_value
        end
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
    local tok, rest = name:match("^([^:]+):(.+)$")
    if tok then
        if rest == "." or rest == ".." then return nil end
        d = nil
        for _i, f in ipairs(M.extraFolders()) do
            if f.token == tok then d = f.dir; break end
        end
        name = rest
    end
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
-- ── Other folders that hold wallpapers ────────────────────────────────────
--
-- A reader who already keeps pictures for another tool should not have to
-- copy them. Every image in any of these folders that exists joins the list,
-- under a name that says which folder it came from ("<folder>:<file>") so
-- pathFor knows where to look. Read only: none of them is ever created, and
-- nothing outside them is read.
--
-- NOT the screensaver folder, though it was here at first on the reasoning
-- that readers commonly fill one and the same picture often suits both. It
-- does not survive contact with real ones: most screensaver images shared for
-- KOReader are PNGs with transparency, cut to sit alone on a blank screen, and
-- behind a shelf they read as holes rather than as a backdrop. A folder of
-- them also floods the picker, each entry looking exactly like a wallpaper the
-- reader chose to put there (maintainer, having looked through their own).
--
-- The mechanism stays: SimpleUI's folder is a genuine wallpaper folder, and so
-- is /mnt/us/Wallpapers.
M.EXTRA_DIRS = nil     -- override for the tests; nil = the defaults below
function M.extraDirs()
    if M.EXTRA_DIRS then return M.EXTRA_DIRS end
    local out = {}
    local settings = M.dataDir()
    if settings then out[#out + 1] = settings .. "/simpleui/sui_wallpapers" end
    out[#out + 1] = "/mnt/us/Wallpapers"
    return out
end

-- The token a folder's files are named under: its last path component.
local function _dirToken(d)
    return (tostring(d):gsub("/+$", "")):match("([^/]+)$") or "x"
end

-- extraFolders() -> { {token, dir}, ... } for the extra folders that exist.
function M.extraFolders()
    local fs = lfs()
    if not fs then return {} end
    local seen, out = {}, {}
    for _i, d in ipairs(M.extraDirs()) do
        d = tostring(d):gsub("/+$", "")
        if not seen[d] and d ~= M.dir() and fs.attributes(d, "mode") == "directory" then
            seen[d] = true
            out[#out + 1] = { token = _dirToken(d), dir = d }
        end
    end
    return out
end

function M.list()
    M.ensureDir()
    local d, fs = M.dir(), lfs()
    if not (d and fs) then return {} end
    local names, key = AssetFolder.scan(fs, d, EXTS)
    if not names then return {} end
    -- The other folders are part of the cache key: a file added to one of
    -- them must show up here too.
    local folders = M.extraFolders()
    local extra = {}
    for _i, f in ipairs(folders) do
        local fnames, fkey = AssetFolder.scan(fs, f.dir, EXTS)
        extra[#extra + 1] = { folder = f, names = fnames or {} }
        key = key .. "|" .. f.token .. "=" .. tostring(fkey)
    end
    if M._list_cache and M._list_key == key then return M._list_cache end
    local out, labels = {}, {}
    local function add(name, label, path)
        out[#out + 1] = { name = name, label = label, path = path }
        labels[label] = (labels[label] or 0) + 1
    end
    for _i = 1, #names do
        local name = names[_i]
        add(name, name:match("^(.+)%.[^%.]+$") or name, d .. "/" .. name)
    end
    for _i, e in ipairs(extra) do
        for _j = 1, #e.names do
            local name = e.names[_j]
            add(e.folder.token .. ":" .. name, name:match("^(.+)%.[^%.]+$") or name,
                e.folder.dir .. "/" .. name)
        end
    end
    -- Two folders holding a file of the same name: say which is which.
    for _i, it in ipairs(out) do
        if labels[it.label] > 1 then
            local tok = it.name:match("^([^:]+):")
            it.label = it.label .. " (" .. (tok or _("wallpapers")) .. ")"
        end
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
--
-- scrim_color/scrim_strength put the PANEL back too. "The image's own pixels"
-- stopped being the whole truth once the footer grew a tinted panel: the
-- hamburger sits inside it, so restoring the raw wallpaper there punches a
-- dark rectangle through the panel exactly the size of the close X's box.
-- What was on screen is wallpaper THEN tint, so the eraser replays both.
local Eraser = nil
function M.eraser(active, w, h, scrim_color, scrim_strength)
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
            -- No radius: this patch is strictly INSIDE the panel, so it wants
            -- the panel's fill, never its corners.
            if self.scrim_color and (self.scrim_strength or 0) > 0 then
                M.scrim(target, x, y, self.w, self.h,
                        self.scrim_color, self.scrim_strength)
            end
        end
    end
    return Eraser:new{ w = w, h = h,
                       scrim_color = scrim_color, scrim_strength = scrim_strength }
end

-- backdrop(target) -> true if the whole backdrop was painted into `target`.
--
-- For code that composes a frame in its OWN screen-sized buffer rather than
-- painting to the screen -- the chip strip's page wipe does exactly that.
-- Blitbuffer.new callocs, so such a buffer starts BLACK, and whatever the
-- widget does not cover reveals black when the wipe runs. That was invisible
-- while chips were opaque white cards over a white page.
--
-- Reuses the background widget's own paintTo, so the ground colour
-- are honoured without a second implementation to keep in step.
-- backdrop(target [, region]) -> true when the wallpaper was laid into
-- target. With a region, only that rect is blitted: the chip strip's page
-- wipe needs the picture under its own band in a scratch buffer, and laying
-- the whole screen into it for a 60px strip was most of the wipe's cost.
function M.backdrop(target, region)
    local bg = M._bg
    if not (bg and bg.bb and target) then return false end
    if target.getWidth == nil or target.getHeight == nil then return false end
    if target:getWidth() ~= bg.w or target:getHeight() ~= bg.h then return false end
    if type(region) == "table" and region.w and region.h then
        local ok = pcall(function()
            target:blitFrom(bg.bb, region.x, region.y, region.x, region.y,
                            region.w, region.h)
        end)
        return ok and true or false
    end
    local ok = pcall(function() bg:paintTo(target, 0, 0) end)
    return ok and true or false
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
-- ── the ground, which is not always a picture ──────────────────────────────
--
-- restore() and patch() exist to answer "what is behind this rect", and for a
-- long time the only answer worth having was a photograph. It is not the only
-- one: a reader can set a page colour, and the shelf's own dark theme is a
-- ground too. Both want exactly the same compositing the picture does -- the
-- chrome stops painting its own paper and whatever is behind shows through --
-- so the ground is set here and these two answer for it whether or not an
-- image was ever loaded.
--
-- nil means the shelf is plain paper and every caller should take its
-- historical no-picture path, which is what keeps a default install
-- byte-identical.
M._ground = nil
function M.setGround(colour)
    M._ground = (type(colour) ~= "nil") and colour or nil
end
function M.ground() return M._ground end

-- THE PANEL, registered so restore can tell the truth.
--
-- restore()'s contract is "put back what was behind this rect". Inside a
-- panel that is NOT the raw picture: the panel tinted it first, and blitting
-- the untouched photograph back punches a bright hole in the tint. That is
-- what the hero cover's rounded corners were -- four light notches on a dark
-- panel, at the picture's own brightness (maintainer, on device).
--
-- One rect, set by whoever paints the panel, cleared when it does not. Kept
-- here rather than threaded through every caller because the callers are
-- asking "what is behind me", not "am I in a panel" -- they have no business
-- knowing, and every one of them would have to be told.
M._panel = nil
function M.setPanel(x, y, w, h, colour, strength, radius)
    if not (x and y and w and h) or w <= 0 or h <= 0
            or type(colour) == "nil" or not strength or strength <= 0 then
        M._panel = nil
        return
    end
    -- Called on every paint of the top panel; mutate rather than allocate.
    local p = M._panel or {}
    p.x, p.y, p.w, p.h = x, y, w, h
    p.colour, p.strength, p.radius = colour, strength, radius or 0
    M._panel = p
end

-- _reshade(target, x, y, w, h): re-apply the panel's tint over a rect that
-- has just had raw picture put back into it. Clipped to the panel, so a rect
-- straddling its edge only gets tinted on the inside.
local function _reshade(target, x, y, w, h)
    local p = M._panel
    if not p then return end
    local x0 = math.max(x, p.x)
    local y0 = math.max(y, p.y)
    local x1 = math.min(x + w, p.x + p.w)
    local y1 = math.min(y + h, p.y + p.h)
    if x1 <= x0 or y1 <= y0 then return end
    pcall(function()
        M.scrim(target, x0, y0, x1 - x0, y1 - y0, p.colour, p.strength, 0)
    end)
end


function M.restore(target, x, y, w, h)
    if not (target and w and h) or w <= 0 or h <= 0 then return false end
    local bg = M._bg
    if bg and bg.bb then
        if target.getWidth == nil or target.getHeight == nil then return false end
        if target:getWidth() ~= bg.w or target:getHeight() ~= bg.h then return false end
        local ok = pcall(function()
            target:blitFrom(bg.bb, x, y, x, y, w, h)
        end)
        if ok then
            _reshade(target, x, y, w, h)
            return true
        end
        return false
    end
    -- No picture, but a ground: the flat colour IS what is behind this rect,
    -- and the caller's own fallback would paint paper white into it.
    if type(M._ground) == "nil" then return false end
    local ok = pcall(function()
        target:paintRect(x, y, w, h, M._ground)
    end)
    return ok and true or false
end

-- patch(target, dx, dy, sx, sy, w, h) -> true if it painted.
--
-- restore()'s offscreen sibling. restore refuses anything that is not
-- screen-sized, because it blits source-to-destination at the same
-- coordinates; this takes the two separately, so a small scratch buffer can
-- be given the slice of wallpaper that sits under the rect it will be blitted
-- back to.
--
-- Needed wherever a one-shot frame is composed offscreen and then copied over
-- the screen: it cannot alphablit (the screen still holds the outgoing frame,
-- which would show through), so it needs a real ground, and over a wallpaper
-- the only correct ground is the picture itself.
function M.patch(target, dx, dy, sx, sy, w, h)
    if not (target and w and h) or w <= 0 or h <= 0 then return false end
    local bg = M._bg
    if not (bg and bg.bb) then
        -- No picture, but a ground: the flat colour is what belongs here, and
        -- it needs no source coordinates at all. Same reasoning as restore.
        if type(M._ground) == "nil" then return false end
        local ok = pcall(function()
            target:paintRect(dx, dy, w, h, M._ground)
        end)
        return ok and true or false
    end
    if not (sx and sy) or sx < 0 or sy < 0 then return false end
    -- CLAMP rather than refuse. A slot at the right or bottom edge of the
    -- screen overhangs the picture by a pixel or two, and refusing the whole
    -- copy for that sent the caller to its flat-colour fallback -- a white (or
    -- black) hole where the wallpaper should have been.
    if sx + w > bg.w then w = bg.w - sx end
    if sy + h > bg.h then h = bg.h - sy end
    if w <= 0 or h <= 0 then return false end
    local ok = pcall(function()
        target:blitFrom(bg.bb, dx, dy, sx, sy, w, h)
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

-- iconHasColour(icon) -> true if the icon's own artwork is chromatic.
--
-- IconWidget looks in `<data dir>/icons` BEFORE `resources/icons/mdlight`, so
-- "chevron.left" is whatever the user dropped there. Replacing the pagination
-- chevrons is a common thing to do and the replacements are often coloured.
-- Everything else in this file can treat an icon as black line art; the mask
-- cannot, because it has room for exactly one colour.
--
-- Read off the rendered bitmap rather than the file, because that is the thing
-- that gets painted: an SVG, a PNG and a scaled copy of either all end up here
-- as the same kind of buffer, and getColorRGB32 normalises every blitbuffer
-- type to r/g/b so the answer does not depend on which one it is.
--
-- TWO THINGS the naive version gets wrong:
--
--   * ALPHA. NanoSVG hands back STRAIGHT alpha, so the RGB sitting behind a
--     fully transparent pixel is whatever the rasteriser last left there --
--     frequently not grey, and never visible. Sampling it says "colour" for
--     every icon ever drawn. Skip anything close to invisible.
--   * TOLERANCE. A scaled or dithered greyscale render lands a channel a
--     point or two off its neighbours. Require a real spread, not inequality.
--
-- Sampled on a stride so the cost is ~256 reads whatever the icon's size, and
-- cached against the RESOLVED PATH -- which is the field that distinguishes a
-- user's chevron.left from the shipped one of the same name. The answer is a
-- property of the file, so once per session is once too many already.
local CHROMA_TOLERANCE = 8      -- r/g/b spread below this is grey enough
local CHROMA_MIN_ALPHA = 0x10   -- fainter than this contributes nothing
local _icon_colour = {}
function M.iconHasColour(icon)
    if type(icon) ~= "table" then return false end
    local key = icon.file or icon.icon
    if type(key) ~= "string" or key == "" then return false end
    local hit = _icon_colour[key]
    if type(hit) == "boolean" then return hit end

    local scanned, found = false, false
    pcall(function()
        if not icon._bb and type(icon._render) == "function" then
            icon:_render()
        end
        local bb = icon._bb
        if not bb or type(bb.getPixel) ~= "function" then return end
        local w, h = bb:getWidth(), bb:getHeight()
        if not w or not h or w <= 0 or h <= 0 then return end
        scanned = true
        local step = math.max(1, math.floor(math.min(w, h) / 16))
        for y = 0, h - 1, step do
            for x = 0, w - 1, step do
                local c = bb:getPixel(x, y):getColorRGB32()
                if (c.alpha or 0xFF) > CHROMA_MIN_ALPHA then
                    local lo = math.min(c.r, c.g, c.b)
                    local hi = math.max(c.r, c.g, c.b)
                    if hi - lo >= CHROMA_TOLERANCE then
                        found = true
                        return
                    end
                end
            end
        end
    end)
    -- Only remember a verdict we actually reached. A render that has not
    -- happened yet is not evidence that the icon is grey.
    if scanned then _icon_colour[key] = found end
    return found
end

-- recolourIcons(active, ink, ...) -> the same widgets, so it can wrap a list
-- inline. Paints every ENABLED button icon in `ink` instead of its own black.
--
-- For the shelf's own dark theme, where nothing inverts the frame for us and
-- KOReader's icons are black-on-transparent bitmaps with no colour to set.
--
-- MASKED, not inverted. ImageWidget has an `invert` flag, and it is the wrong
-- tool here: it inverts the icon's whole RECT, so the panel showing through
-- the transparent part flips too and every chevron gains a pale box -- which
-- is exactly what it looked like. The mask takes the pixmap as an alpha
-- stencil and colour-blits it, leaving everything around the glyph alone.
--
-- Same wrapping unfill uses for a DISABLED icon: replace the widget inside
-- Button's label_container, since that is what actually gets painted.
--
-- SKIPPED for an icon that carries colour. KOReader resolves icons from the
-- user's own `<data dir>/icons` before its own set, so the chevron here may be
-- a cat paw somebody drew -- and a mask has exactly one colour. Flattening
-- stock black line art is the whole point; flattening a painted icon is just
-- deleting it. So ask the bitmap first.
-- tintIcon(ink, icon) -> the icon, or a stand-in that paints it in `ink`.
--
-- The rule recolourIcons applies, lifted out so it can be pointed at a bare
-- IconWidget as well as at a Button's. KOReader icons are black-on-transparent
-- bitmaps and take no colour from anyone: an `fgcolor` handed to the widget
-- that builds one is simply ignored. That is fine while the surface behind is
-- white, and it is why a micro-module can pass the right ink to its icon and
-- still paint black on a black card.
--
-- ALWAYS returns something paintable, so a caller can assign the result
-- unconditionally. It hands the original straight back when there is nothing
-- to do:
--   * no ink, or not an alpha bitmap -- nothing to recolour;
--   * an ink that is already black -- the artwork is drawn in it, so a mask
--     render would cost a buffer to change nothing;
--   * a COLOUR icon -- mask is an alpha stencil with one fgcolor, so it would
--     flatten the artwork to a silhouette. iconHasColour is that test.
function M.tintIcon(ink, icon)
    if type(ink) == "nil" or type(icon) ~= "table" or icon.alpha == nil then
        return icon
    end
    local ok_l, lum = pcall(function() return ink:getColor8().a end)
    if ok_l and lum == 0 then return icon end
    if M.iconHasColour(icon) then return icon end
    icon.dim = false
    return M.mask(true, icon, ink)
end

function M.recolourIcons(active, ink, ...)
    if not active or not ink then return ... end
    for i = 1, select("#", ...) do
        local w = select(i, ...)
        if type(w) == "table" and w.enabled ~= false then
            local icon = w.label_widget
            local lc   = w.label_container
            -- lc[1] == icon: only swap what the container is actually painting.
            if type(icon) == "table" and type(lc) == "table" and lc[1] == icon then
                lc[1] = M.tintIcon(ink, icon)
            end
        end
    end
    return ...
end

-- nightProofIcons(night, ...) -> the same widgets, so it can wrap a list
-- inline. Stops a COLOUR icon displaying as its own negative in night mode.
--
-- ImageWidget pre-inverts what it paints so the panel's inversion lands on the
-- original, and then exempts anything flagged `is_icon`:
--
--     if Screen.night_mode and self.original_in_nightmode and not self.is_icon
--
-- For black line art that exemption is the whole trick -- paint black, display
-- white, match the text. For a colour icon it is simply wrong, and upstream
-- says so in the comment directly above that line: "As for *color* icons, we
-- really *ought* to invert them here, but we currently don't, as we don't
-- really trickle down a way to discriminate them from the B&W ones."
--
-- iconHasColour IS that discrimination, so do what the note asks. Inverting
-- here means the icon DISPLAYS the colours its author chose, in both modes --
-- never a negative of them, which is the one outcome nobody wants.
--
-- A PRIVATE COPY, never the widget's own buffer: `_bb` normally belongs to
-- ImageWidget's render cache, shared with every other widget showing the same
-- icon at the same size. Inverting it in place would flip those too, and flip
-- them again on the next rebuild.
--
-- The RGB32 invert masks 0x00FFFFFF in both the Lua and the C path, so the
-- alpha channel survives and the glyph keeps its shape. That only holds for a
-- buffer that still HAS an alpha channel: with no wallpaper up, ImageWidget
-- caches the icon already flattened onto white (`if self.is_icon and not
-- self.alpha`), and inverting that gives a black card. So this is gated on
-- alpha being on, which is the state unfill puts these icons in.
function M.nightProofIcons(night, ...)
    if not night then return ... end
    for i = 1, select("#", ...) do
        local w = select(i, ...)
        if type(w) == "table" and w.enabled ~= false then
            local icon = w.label_widget
            local lc   = w.label_container
            -- lc[1] == icon: if a mask already replaced it, that wrapper is
            -- what gets painted and it has no colour left to protect.
            if type(icon) == "table" and icon.alpha == true
                    and type(lc) == "table" and lc[1] == icon
                    and M.iconHasColour(icon) then
                pcall(function()
                    local src = icon._bb
                    if not src or type(src.copy) ~= "function" then return end
                    local copy = src:copy()
                    copy:invertRect(0, 0, copy:getWidth(), copy:getHeight())
                    if icon._bb_disposable and type(src.free) == "function" then
                        src:free()
                    end
                    icon._bb = copy
                    icon._bb_disposable = true
                end)
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

-- free() -- drop the decoded backdrop.
--
-- The buffer is freed on the NEXT TICK, not here. The widget holding it may
-- still be in the live tree: the shelf swaps trees on rebuild, and a repaint
-- can land between the free and the swap. Painting a freed blitbuffer is a
-- segfault in the C blitter with no Lua traceback -- which is what a night
-- toggle produced, because that path frees the day image and rebuilds a tick
-- later. Detaching first and freeing after the next paint closes the window:
-- a stale paint finds bb = nil and draws nothing, which is a blank frame at
-- worst.
function M.free()
    local old = M._bg
    M._bg, M._bg_key = nil, nil
    if not (old and old.bb) then return end
    local bb = old.bb
    local ok_ui, UIManager = pcall(require, "ui/uimanager")
    if ok_ui and UIManager and UIManager.nextTick then
        UIManager:nextTick(function()
            old.bb = nil
            pcall(function() if bb.free then bb:free() end end)
        end)
    else
        old.bb = nil
        pcall(function() if bb.free then bb:free() end end)
    end
end

-- flipNight() -> true if the cached backdrop was flipped to the other mode.
--
-- A night toggle inverts the panel, so the wallpaper already on screen shows
-- as a NEGATIVE until something repaints it pre-inverted the other way. The
-- shelf's rebuild does that eventually, but it is a tick or two away and the
-- negative is very visible in the meantime.
--
-- Re-decoding would cost a full JPEG decode for a result that differs from
-- what we already hold by exactly one inversion -- and invertRect IS that
-- inversion, over a buffer in hand. One C pass instead of a decode.
--
-- The key has to follow, or the next M.bg call reads it as the wrong mode and
-- throws this buffer away for an identical one.
function M.flipNight()
    local bg = M._bg
    if not (bg and bg.bb and bg.bb.invertRect and M._bg_key) then return false end
    local ok = pcall(function()
        bg.bb:invertRect(0, 0, bg.bb:getWidth(), bg.bb:getHeight())
    end)
    if not ok then return false end
    if M._bg_key:sub(-2) == "|n" then
        M._bg_key = M._bg_key:sub(1, -3)
    else
        M._bg_key = M._bg_key .. "|n"
    end
    return true
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
    -- M._render is the test seam, the same one the ornaments module exposes:
    -- the painting is what is worth pinning headless, and a real decode would
    -- drag KOReader's image stack into a plain-Lua suite.
    if M._render then return M._render(path, w, h) end
    local RenderImage = require("ui/renderimage")
    local t0 = _gettime()
    local bb = RenderImage:renderImageFile(path, false, w, h)
    -- Permanent, per the [bookshelf perf] convention: this is the one
    -- synchronous decode on the cold-start path, and it is the number to
    -- watch if a picture ever lands in a launch complaint.
    logger.dbg(string.format("[bookshelf perf] wallpaper: decode=%.0fms %dx%d %s",
        (_gettime() - t0) * 1000, w or 0, h or 0, tostring(path)))
    return bb
end

-- A background is a plain opaque blit: it is the bottom of the stack, there is
-- nothing behind it to blend with, and blitFrom is markedly cheaper than the
-- alpha path over a full screen.
--
-- A wallpaper covers the whole screen. The ground colour is painted first so
-- an image whose aspect ratio leaves a margin shows the page colour there
-- rather than whatever the last frame left behind.
local function backgroundWidget(bb, w, h)
    if not Background then
        local Widget = require("ui/widget/widget")
        Background = Widget:extend{ bb = nil, w = 0, h = 0,
                                    ground = nil }
        function Background:init()
            self.dimen = require("ui/geometry"):new{ w = self.w, h = self.h }
        end
        function Background:paintTo(target, x, y)
            self.dimen.x, self.dimen.y = x, y
            if not self.bb then return end
            -- THIS WIDGET OWNS THE WHOLE SCREEN. The ground is painted first
            -- so a picture that does not cover every pixel (a different aspect
            -- ratio, say) leaves the page colour behind it rather than last
            -- frame's content -- the page frame above deliberately does not
            -- fill when a wallpaper is present.
            -- ...but only when there IS a margin. decode() scales the picture
            -- to exactly the screen, so this fill was a 2MB write per paint
            -- that the blit then covered in full.
            local ground = self.ground
            if ground then
                local ok_c, covers = pcall(function()
                    return self.bb:getWidth() >= self.w and self.bb:getHeight() >= self.h
                end)
                if not (ok_c and covers) then
                    pcall(function() target:paintRect(x, y, self.w, self.h, ground) end)
                end
            end
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
