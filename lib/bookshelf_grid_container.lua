--[[
Absolute-position container for the micro-module grid.

Children are the module cells; pos[i] = { x, y } is child i's offset from the
grid's top-left. The cell grid has gaps and multi-row cells, which nested
row/column groups can't express, so each cell is simply painted where the grid
says. Indexing is plain array slots, so HeroModules._swapCell can replace a
cell in place (self[i] = new) and it keeps its slot's offset.

Optional hooks (used by the layout editor):
  under(bb, x, y)  painted before the cells (dashed outlines of empty cells)
  over(bb, x, y)   painted after them (dimming, the selection outline)
  hold()           a long-press on the grid that no cell took (an empty
                   cell, a gap): the top panel and full screen open the
                   layout editor with it

paintTo records the grid's screen position in self.dimen, which is where the
layout editor reads it to hit-test taps.
]]
local WidgetContainer = require("ui/widget/container/widgetcontainer")

local GridContainer = WidgetContainer:extend{
    pos = nil,
}

function GridContainer:getSize()
    return self.dimen
end

-- Cells are laid out by the grid, nothing to recompute; kept so callers that
-- reset a group after swapping a child (HeroModules._swapCell) work unchanged.
function GridContainer:resetLayout() end

function GridContainer:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    -- Each cell's paint, into an open interaction's timing (lib/bookshelf_perf).
    local Perf = require("lib/bookshelf_perf")
    local timing = Perf.active()
    local t
    if self.under then self.under(bb, x, y) end
    local pos = self.pos or {}
    for i, w in ipairs(self) do
        local p = pos[i]
        if p then
            if timing then t = Perf.now() end
            w:paintTo(bb, x + p.x, y + p.y)
            if timing then Perf.part("paint " .. tostring(w.perf_name or i), t) end
        end
    end
    if timing then t = Perf.now() end
    if self.over then self.over(bb, x, y) end
    if timing then Perf.part("paint over", t) end
end

-- Cells first (a module's own long-press opens the editor on it); a hold
-- they leave, inside the grid, goes to the hold hook.
function GridContainer:handleEvent(event)
    if WidgetContainer.handleEvent(self, event) then return true end
    if not (self.hold and event and event.handler == "onGesture") then return false end
    local ges = event.args and event.args[1]
    local d = self.dimen
    if not (ges and ges.ges == "hold" and ges.pos and d and d.x) then return false end
    local px, py = ges.pos.x - d.x, ges.pos.y - d.y
    if px < 0 or py < 0 or px >= d.w or py >= d.h then return false end
    self.hold()
    return true
end

return GridContainer
