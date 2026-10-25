--[[--
What the shelf looked like under a window shown over it, kept so the
window's close can put it back instead of the shelf painting itself again.

UIManager:close marks every window still showing as dirty (no region), so
closing anything over the shelf -- a menu, a dialog, the sleep screen --
repainted the whole shelf: ~150 ms of paint for a menu on a PW5, and on wake
~580 ms. The shelf's pixels under a window do not change while it is up
(nothing on the shelf moved), so they are copied off the screen just before
the window first paints over them, and written back when it closes.

- A window over the shelf paints through a stand-in for the screen that
  copies each 64 px tile of the shelf just before the window first draws on
  it (most KOReader dialogs are a full-screen container round a small box,
  so the window's own size says nothing about what it covers). A menu
  costs about a menu's worth of tiles. A window drawing over most of the
  screen is not kept (usually the reader) -- except the sleep screen, which
  is copied whole while the device goes to sleep, when no one is waiting.
- Each tile is copied once, by the first window to draw on it: that copy
  is the shelf's.
- If the shelf paints itself while a window is over it, what was copied is
  no longer what it shows: the copies are dropped and closes repaint as
  they always did.

The shelf (bookshelf_widget) installs this (Underlay.install(bw)) and asks
Underlay.restoring() from its dirty tracking, so the close's own repaint
request is the only one it lets go unpainted.
]]

local M = {}

M.MAX_SHARE = 0.6      -- of the screen; a window drawing over more is not kept
M.TILE = 64            -- px: the shelf is copied in tiles, each before it is first drawn on

local _bw              -- the shelf
local _over = {}       -- [window] = true: shown over the shelf, being tracked
local _pieces = {}     -- { { bb, x, y, w, h }, ... }
local _tiles = {}      -- [tile index] = true once copied
local _tile_area = 0
local _valid = true
local _restoring = false
M._last_restore = 0

local function screen()
    return require("device").screen
end

local function dropPieces()
    for _i, p in ipairs(_pieces) do pcall(function() p.bb:free() end) end
    _pieces, _tiles, _tile_area = {}, {}, 0
end

--- invalidate(): the shelf painted under a window; nothing copied stands.
function M.invalidate()
    if next(_over) == nil and #_pieces == 0 then return end
    _valid = false
    dropPieces()
end

local function copy(bb, x, y, w, h)
    local Blitbuffer = require("ffi/blitbuffer")
    local piece = Blitbuffer.new(w, h, bb:getType())
    piece:blitFrom(bb, 0, 0, x, y, w, h)
    _pieces[#_pieces + 1] = { bb = piece, x = x, y = y, w = w, h = h }
end

-- ensure(bb, x, y, w, h): every tile under the rect copied off the screen
-- before anything is drawn there. Each tile once: the first copy is the
-- shelf's (a later window's draw over a tile an earlier one drew on finds
-- it already kept).
local function ensure(bb, x, y, w, h)
    if not _valid or not (x and y and w and h) or w <= 0 or h <= 0 then return end
    local Screen = screen()
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    local T = M.TILE
    local tx0, ty0 = math.max(0, math.floor(x / T)), math.max(0, math.floor(y / T))
    local tx1 = math.min(math.ceil(sw / T) - 1, math.floor((x + w - 1) / T))
    local ty1 = math.min(math.ceil(sh / T) - 1, math.floor((y + h - 1) / T))
    local per_row = math.ceil(sw / T)
    -- Over the limit with this draw: stop before copying anything for it.
    -- A big popup's first draw is usually its whole frame, so the copy
    -- that would only be thrown away is never made.
    local new_area = 0
    for ty = ty0, ty1 do
        for tx = tx0, tx1 do
            if not _tiles[ty * per_row + tx] then new_area = new_area + T * T end
        end
    end
    if new_area > 0 and _tile_area + new_area > M.MAX_SHARE * sw * sh then
        _valid = false
        dropPieces()
        return
    end
    for ty = ty0, ty1 do
        local run_from
        for tx = tx0, tx1 + 1 do
            local idx = ty * per_row + tx
            local need = tx <= tx1 and not _tiles[idx]
            if need then
                _tiles[idx] = true
                run_from = run_from or tx
            elseif run_from then
                -- One copy for a run of new tiles along the row.
                local px, py = run_from * T, ty * T
                local pw = math.min(sw, tx * T) - px
                local ph = math.min(sh, py + T) - py
                copy(bb, px, py, pw, ph)
                _tile_area = _tile_area + pw * ph
                run_from = nil
            end
        end
    end
    if _tile_area > M.MAX_SHARE * sw * sh then
        -- Most of the screen: not worth keeping (and usually the reader).
        _valid = false
        dropPieces()
    end
end

-- The stand-in a window over the shelf paints through: each drawing call
-- first keeps the tiles it is about to cover, then draws on the real
-- screen. Anything that is not a drawing call goes to the screen as it is.
local Cow = {}
local BLITS = { "blitFrom", "alphablitFrom", "pmulalphablitFrom", "ditherblitFrom",
                "ditheralphablitFrom", "ditherpmulalphablitFrom", "colorblitFrom",
                "colorblitFromRGB32", "invertblitFrom", "addblitFrom" }
for _i, name in ipairs(BLITS) do
    Cow[name] = function(self, src, dx, dy, ox, oy, w, h, ...)
        if type(src) == "table" and rawget(src, "_is_cow") then src = rawget(src, "_bb") end
        local bw_, bh_ = w, h
        if not bw_ then bw_, bh_ = src:getWidth() - (ox or 0), src:getHeight() - (oy or 0) end
        ensure(self._bb, dx, dy, bw_, bh_)
        local bb = self._bb
        return bb[name](bb, src, dx, dy, ox, oy, w, h, ...)
    end
end
for _i, name in ipairs({ "paintRect", "paintRectRGB32", "invertRect", "lightenRect", "darkenRect",
                         "dimRect", "blendRectRGB32", "paintBorder", "paintRoundedRect",
                         "paintBorderRGB32", "paintInnerBorder", "paintRoundedCorner" }) do
    Cow[name] = function(self, x, y, w, h, ...)
        ensure(self._bb, x, y, w, h)
        local bb = self._bb
        return bb[name](bb, x, y, w, h, ...)
    end
end
for _i, name in ipairs({ "setPixel", "setPixelClamped", "setPixelAdd", "setPixelBlend" }) do
    Cow[name] = function(self, x, y, ...)
        ensure(self._bb, x, y, 1, 1)
        local bb = self._bb
        return bb[name](bb, x, y, ...)
    end
end
function Cow:fill(...)
    local bb = self._bb
    ensure(bb, 0, 0, bb:getWidth(), bb:getHeight())
    return bb:fill(...)
end
-- A viewport draws on the screen directly: keep all of it first.
function Cow:viewport(x, y, w, h)
    ensure(self._bb, x, y, w, h)
    return self._bb:viewport(x, y, w, h)
end
local cow_mt = {
    __index = function(self, k)
        local f = Cow[k]
        if f then return f end
        local bb = rawget(self, "_bb")
        local v = bb[k]
        if type(v) == "function" then return function(_s, ...) return v(bb, ...) end end
        return v
    end,
}
function M.cow(bb) return setmetatable({ _bb = bb, _is_cow = true }, cow_mt) end

local function sleepScreen(window)
    return window.name == "ScreenSaver" or window.name == "ScreenSaverLock"
end

-- paintOver(window, paint, bb, x, y): the window's paint, through the
-- stand-in while its draws are being kept. The sleep screen covers it all:
-- one copy of the whole screen first, then its own paint.
local function paintOver(window, paint, bb, x, y)
    local Screen = screen()
    if not _valid or bb ~= Screen.bb then return paint(window, bb, x, y) end
    if sleepScreen(window) then
        if not _tiles.all then
            _tiles.all = true
            local ok = pcall(copy, bb, 0, 0, Screen:getWidth(), Screen:getHeight())
            if not ok then _valid = false; dropPieces() end
        end
        return paint(window, bb, x, y)
    end
    local ok, err = pcall(paint, window, M.cow(bb), x, y)
    if not ok then
        -- It read the screen back through the stand-in, say: drawn as it
        -- always was, and nothing kept for this close.
        _valid = false
        dropPieces()
        require("logger").dbg("[bookshelf] underlay: painted directly:", tostring(err))
        return paint(window, bb, x, y)
    end
end

--- shown(window): UIManager:show put window over the shelf.
function M.shown(window)
    if not (_bw and window and window ~= _bw) or window.invisible then return end
    if _over[window] then return end
    -- A window that covers the whole screen (the reader) hides the shelf
    -- from UIManager's repaints and is not kept: copying it all would be a
    -- full read off the framebuffer, and the reader's page is drawn by
    -- crengine straight into the buffer it is handed. Not tracked at all.
    -- The sleep screen is the exception (see paintOver).
    if window.covers_fullscreen and not sleepScreen(window) then
        M.invalidate()
        return
    end
    -- Only over the shelf as it stands on screen: when the shelf is not the
    -- window under everything shown since it, this has nothing to keep.
    if next(_over) == nil then
        _valid = true
        dropPieces()
    end
    _over[window] = true
    local paint = window.paintTo
    -- Its own paintTo, if it had one, to put back (false: none).
    rawset(window, "_underlay_own", rawget(window, "paintTo") or false)
    rawset(window, "paintTo", function(self, bb, x, y)
        return paintOver(self, paint, bb, x, y)
    end)
end

--- closing(window) -> true when the shelf's pixels went back under it (and
--- the shelf need not paint for this close).
function M.closing(window)
    if not _over[window] then return false end
    _over[window] = nil
    local own = rawget(window, "_underlay_own")
    rawset(window, "paintTo", own or nil)
    rawset(window, "_underlay_own", nil)
    local restored = false
    if _valid and #_pieces > 0 then
        local Screen = screen()
        local ok = pcall(function()
            for _i, p in ipairs(_pieces) do
                Screen.bb:blitFrom(p.bb, p.x, p.y, 0, 0, p.w, p.h)
            end
        end)
        restored = ok
        if ok then M._last_restore = os.time() end
    end
    if next(_over) == nil then dropPieces(); _valid = true end
    return restored
end

--- restoring() -> true during a close that put the shelf back.
function M.restoring() return _restoring end
function M._setRestoring(v) _restoring = v and true or false end

--- covered() -> true while a tracked window is over the shelf.
function M.covered() return next(_over) ~= nil end

--- install(bw): wrap UIManager.show / close once; bw is the live shelf.
function M.install(bw)
    _bw = bw
    if M._installed then return end
    M._installed = true
    local UIManager = require("ui/uimanager")
    local show, close = UIManager.show, UIManager.close
    UIManager.show = function(um, window, ...)
        local res = table.pack and table.pack(show(um, window, ...)) or { show(um, window, ...) }
        pcall(function()
            if _bw and not _bw._closed and um:isWidgetShown(_bw) then M.shown(window) end
        end)
        return (table.unpack or unpack)(res, 1, res.n or #res)
    end
    UIManager.close = function(um, window, ...)
        local ok_r, restored = pcall(M.closing, window)
        if ok_r and restored then
            _restoring = true
            local ok, err = pcall(close, um, window, ...)
            _restoring = false
            if not ok then error(err, 0) end
            return
        end
        return close(um, window, ...)
    end
end

function M._debugPieces() return _pieces end

function M._reset()
    dropPieces(); _over = {}; _valid = true; _restoring = false; _bw = nil
end

return M
