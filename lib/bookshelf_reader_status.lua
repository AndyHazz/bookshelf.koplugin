--[[
The Bookshelf status line, drawn in the READER.

Registered with ReaderView via view:registerViewModule, exactly like the
in-reader launcher buttons in lib/bookshelf_reader_buttons.lua, so paintTo runs
as part of every ReaderView paint pass and the strip survives page turns and
refreshes.

WHY BOOKSHELF DRAWS THIS AND NOT BOOKENDS
-----------------------------------------
An earlier attempt had bookends mirror the line by reading bookshelf's config
and rebuilding the widget itself. That worked, but it made the feature depend
on bookends being installed and enabled, and it meant two renderers for one
line - so keeping them pixel-identical was arithmetic I had to get right rather
than a property of the code.

This draws the line with HeroCard.buildStatusRow, the SAME builder the expanded
shelf uses. Parity is then structural: same widget, same fonts, same elastic
%spacer split, same inset. Bookends' only remaining job is to move its own top
row (and any top-anchored progress bar) out of the way, which it does by
reading the height published below.

Independent of bookends entirely: with bookends disabled, this still draws.
]]
local Device     = require("device")
local Geom       = require("ui/geometry")
local Size       = require("ui/size")
local Widget     = require("ui/widget/widget")
local Screen     = Device.screen

-- Height of the last published strip, in pixels. Declared up here rather than
-- beside publishHeight because bandRect (above) closes over it too.
local _published

local ReaderStatus = Widget:extend{
    -- Height of the last painted strip, in pixels. Published so bookends can
    -- reserve the space; 0 when nothing was drawn.
    painted_h = 0,
}

--- The vendored status-line definition, or nil. Memoised: paintTo runs on
--- every ReaderView pass and this was three pcall(require) calls per paint.
local _status_line
local function statusLine()
    if _status_line == nil then
        local ok, mod = pcall(require, "lib/status_line")
        _status_line = (ok and mod) or false
    end
    return _status_line or nil
end

--- Whether the user has asked for this line in the reader.
function ReaderStatus.enabled()
    local StatusLine = statusLine()
    if not StatusLine then return false end
    return StatusLine.showInReader(G_reader_settings)
end

--- Does the line actually name any of these tokens?
---
--- The gate on the event-driven repaints below. Same matching rule as the
--- shelf's _anyActiveRegionUses - "%name" followed by a non-identifier
--- character, or end of string, so %lightning is not %light - but scoped to
--- the one region this strip renders rather than all eight. Reads the same
--- resolved template HeroCard.buildStatusRow does, so the gate cannot
--- disagree with what is on screen.
---
--- @param tokens table  list of bare token names, e.g. { "light", "batt" }
--- @return boolean
function ReaderStatus.usesTokens(tokens)
    if type(tokens) ~= "table" or #tokens == 0 then return false end
    if not ReaderStatus.enabled() then return false end
    local ok, Regions = pcall(require, "lib/bookshelf_hero_regions")
    if not ok or not Regions then return false end
    local ok_read, resolved = pcall(Regions.read)
    if not ok_read or type(resolved) ~= "table" then return false end
    local r = resolved.status
    if not r or r.disabled or type(r.template) ~= "string" then return false end
    for _i, name in ipairs(tokens) do
        if r.template:find("%%" .. name .. "[^%w_]")
                or r.template:match("%%" .. name .. "$") then
            return true
        end
    end
    return false
end

--- The screen band the strip occupies, for a region-scoped refresh. nil when
--- nothing has been painted yet, in which case the caller should fall back to
--- a full refresh rather than skip one.
function ReaderStatus.bandRect()
    local h = _published or 0
    if h <= 0 then return nil end
    return Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = h }
end

--- The side inset the shelf uses, so the strip lines up with itself.
local function sidePad()
    local StatusLine = statusLine()
    if not StatusLine then return 0 end
    return StatusLine.sidePad(Screen:getWidth(),
                              Size and Size.padding and Size.padding.fullscreen)
end

--- The book record, cached on a short TTL.
---
--- buildBook is NOT cheap enough to run per paint: it queries BIM's SQLite
--- database and opens DocSettings, which stats the sidecar directories and
--- parses the sidecar Lua. want_cover=false drops the worst of it (BIM's zstd
--- decode plus a Blitbuffer allocation for a cover buildStatusRow never looks
--- at), and the TTL bounds the rest to once every few seconds however often
--- the reader repaints. Same 5s window the shelf's device-state cache uses,
--- and for the same reason: the values move slowly, the paints do not.
---
--- Progress tokens therefore lag by up to the TTL, and come from the sidecar
--- on disk rather than the live reader, so they are as fresh as the last
--- flush. The shipped default template carries no book tokens.
local RECORD_TTL = 5
local _rec_path, _rec_book, _rec_expires_at = nil, nil, 0

local function bookRecord(Repo, filepath)
    local now = os.time()
    if _rec_book and _rec_path == filepath and now < _rec_expires_at then
        return _rec_book
    end
    local ok, book = pcall(Repo.buildBook, filepath, { want_cover = false })
    if not ok or not book then return nil end
    _rec_path, _rec_book, _rec_expires_at = filepath, book, now + RECORD_TTL
    return book
end

--- Drop the cached record. Called when the strip is torn down, so reopening a
--- book cannot show the record of the previous one for the rest of the TTL.
function ReaderStatus.invalidate()
    _rec_path, _rec_book, _rec_expires_at = nil, nil, 0
end

--- Build the row for the currently open document, or nil.
local function buildRow(width)
    local ui = require("apps/reader/readerui").instance
    local filepath = ui and ui.document and ui.document.file
    if not filepath then return nil end

    local ok_hc, HeroCard = pcall(require, "lib/bookshelf_hero_card")
    local ok_repo, Repo   = pcall(require, "lib/bookshelf_book_repository")
    local ok_bw, BW       = pcall(require, "lib/bookshelf_widget")
    if not (ok_hc and HeroCard and ok_repo and Repo and ok_bw and BW) then
        return nil
    end

    local book = bookRecord(Repo, filepath)
    if not book then return nil end
    local ok_state, state = pcall(BW.deviceState)
    if not ok_state then state = {} end

    -- with_hairline = false, matching the expanded shelf: there the chip strip
    -- below serves as the separator, and here the page text does.
    local ok_row, row = pcall(HeroCard.buildStatusRow, book, state, width, false)
    if not ok_row then return nil end
    return row
end

--- Draw the strip and return the space it occupies from the top of the
--- screen, or 0. Split out so paintTo has exactly one publish point: an early
--- return that skipped it left bookends reserving room for a strip that was no
--- longer being drawn.
function ReaderStatus:_paintStrip(bb, x, y)
    if not ReaderStatus.enabled() then return 0 end

    local pad = sidePad()
    local width = Screen:getWidth() - pad * 2
    if width <= 0 then return 0 end

    -- The WIDGET is rebuilt each paint even though the book record behind it
    -- is cached: the line carries a clock, the battery level and the
    -- frontlight state, so a cached widget would show the time the reader was
    -- opened. The shelf rebuilds it per render for the same reason.
    local ok, row = pcall(buildRow, width)
    if not ok or not row then return 0 end

    local size = row.getSize and row:getSize() or { h = 0 }
    if not size.h or size.h <= 0 then return 0 end

    pcall(function() row:paintTo(bb, x + pad, y + pad) end)
    self.painted_h = size.h
    if row.free then pcall(function() row:free() end) end
    return pad + size.h
end

function ReaderStatus:paintTo(bb, x, y)
    self.painted_h = 0
    local ok, h = pcall(self._paintStrip, self, bb, x, y)
    ReaderStatus.publishHeight((ok and h) or 0)
end

--- Publish the space this strip occupies from the top of the screen, so
--- bookends can move its own top row and any top-anchored bar clear of it.
--- Written only when the value changes, since this runs on every paint.
---
--- 0 is a real value here, not an absence: it is how "I drew nothing" is
--- announced. Bookends also gates on the switch (see StatusLine.reservedHeight)
--- for the case where we are never loaded at all and cannot say so.
function ReaderStatus.publishHeight(h)
    h = math.floor(tonumber(h) or 0)
    if _published == h then return end
    _published = h
    local ok, StatusLine = pcall(require, "lib/status_line")
    if not ok or not StatusLine then return end
    pcall(function()
        G_reader_settings:saveSetting(StatusLine.RESERVED_KEY, h)
    end)
end

function ReaderStatus:getSize()
    return Geom:new{ w = Screen:getWidth(), h = self.painted_h or 0 }
end

return ReaderStatus
