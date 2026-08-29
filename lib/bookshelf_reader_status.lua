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

local ReaderStatus = Widget:extend{
    -- Height of the last painted strip, in pixels. Published so bookends can
    -- reserve the space; 0 when nothing was drawn.
    painted_h = 0,
}

--- Whether the user has asked for this line in the reader.
function ReaderStatus.enabled()
    local ok, StatusLine = pcall(require, "lib/status_line")
    if not ok or not StatusLine then return false end
    local cfg = StatusLine.fromSettings(G_reader_settings)
    return (cfg and cfg.show_in_reader) and true or false
end

--- The side inset the shelf uses, so the strip lines up with itself.
local function sidePad()
    local ok, StatusLine = pcall(require, "lib/status_line")
    if not ok or not StatusLine then return 0 end
    return StatusLine.sidePad(Screen:getWidth(),
                              Size and Size.padding and Size.padding.fullscreen)
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

    local ok_book, book = pcall(Repo.buildBook, filepath)
    if not ok_book or not book then return nil end
    local ok_state, state = pcall(BW.deviceState)
    if not ok_state then state = {} end

    -- with_hairline = false, matching the expanded shelf: there the chip strip
    -- below serves as the separator, and here the page text does.
    local ok_row, row = pcall(HeroCard.buildStatusRow, book, state, width, false)
    if not ok_row then return nil end
    return row
end

function ReaderStatus:paintTo(bb, x, y)
    self.painted_h = 0
    if not ReaderStatus.enabled() then return end

    local pad = sidePad()
    local width = Screen:getWidth() - pad * 2
    if width <= 0 then return end

    -- Rebuilt each paint rather than cached: the line carries a clock, the
    -- battery level and the frontlight state, so a cached widget would show
    -- the time the reader was opened. The shelf rebuilds it per render for the
    -- same reason.
    local ok, row = pcall(buildRow, width)
    if not ok or not row then return end

    local size = row.getSize and row:getSize() or { h = 0 }
    if not size.h or size.h <= 0 then return end

    pcall(function() row:paintTo(bb, x + pad, y + pad) end)
    self.painted_h = size.h
    ReaderStatus.publishHeight(pad + size.h)
    if row.free then pcall(function() row:free() end) end
end

--- Publish the space this strip occupies from the top of the screen, so
--- bookends can move its own top row and any top-anchored bar clear of it.
--- Written only when the value changes, since this runs on every paint.
local _published
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
