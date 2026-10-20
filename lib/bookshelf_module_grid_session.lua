--[[
The layout editor's state and actions, kept free of widgets so it can be
tested headless. The editor widget (bookshelf_module_grid_editor) draws it
and routes taps and keys here.

A session edits a WORKING COPY: the items (deep-copied from the host's model)
and the boxes of the orientation being edited. Every successful action asks
the host to re-render from that copy (host:render(session:edit())); nothing
reaches the store until commit(), which writes the positions back onto the
items and saves once. A refused action (no room, past the page cap, below a
module's minimum) shows "No room" and changes nothing.

Session.new{
  host,          -- :render(edit) and :model() (load / save / nextId)
  items, boxes,  -- the surface's entries and the boxes for this orientation
  dims, key,     -- grid dimensions; "at" or "at_land"
  page, selected_id,
  notify(text),            -- show a short message
  add_picker(on_added),    -- let the user choose a module; on_added(entry)
  open_settings(entry),    -- the module's own settings
  size_for(entry) -> w, h  -- size for a newly added module
  min_for(entry) -> w, h   -- the module's minimum size (default 1, 1)
}
]]
local Grid = require("lib/bookshelf_module_grid")
local _    = require("lib/bookshelf_i18n").gettext

local MAX_PAGES = 4

local Session = {}
Session.__index = Session

local function deepCopy(v)
    if type(v) ~= "table" then return v end
    local out = {}
    for k, x in pairs(v) do out[k] = deepCopy(x) end
    return out
end

function Session.new(o)
    local s = setmetatable({}, Session)
    s.host          = o.host
    s.items         = deepCopy(o.items or {})
    s.boxes         = deepCopy(o.boxes or {})
    s.dims          = o.dims
    s.key           = o.key or "at"
    s.page          = o.page or 1
    s.selected_id   = o.selected_id
    s.notify        = o.notify or function() end
    s.add_picker    = o.add_picker
    s.open_settings = o.open_settings
    s.size_for      = o.size_for or function() return 1, 1 end
    s.min_for       = o.min_for or function() return 1, 1 end
    return s
end

function Session:edit()
    return { items = self.items, boxes = self.boxes, page = self.page,
             selected_id = self.selected_id }
end

function Session:_render()
    if self.host and self.host.render then self.host:render(self:edit()) end
end

function Session:_refuse()
    self.notify(_("No room"))
    return false
end

-- Take a Grid result: adopt it and re-render, or refuse.
function Session:_adopt(boxes)
    if not boxes then return self:_refuse() end
    self.boxes = boxes
    self:_render()
    return true
end

function Session:item(id)
    for i, it in ipairs(self.items) do
        if it.id == id then return it, i end
    end
end

function Session:box(id)
    for _i, b in ipairs(self.boxes) do
        if b.id == id then return b end
    end
end

--- Pages to show in the footer: those with a module, plus the current one.
function Session:pageList()
    return Grid.pages(self.boxes, self.page)
end

function Session:select(id)
    if self.selected_id == id then return false end
    self.selected_id = id
    self:_render()
    return true
end

function Session:goPage(p)
    if p == self.page or p < 1 then return false end
    self.page = p
    self.selected_id = nil
    self:_render()
    return true
end

function Session:moveBy(dc, dr)
    if not self.selected_id then return false end
    return self:_adopt(Grid.move(self.boxes, self.selected_id, dc, dr, self.dims))
end

function Session:moveToCell(col, row)
    if not self.selected_id then return false end
    return self:_adopt(Grid.moveTo(self.boxes, self.selected_id, col, row, self.dims))
end

function Session:resize(axis, delta)
    local id = self.selected_id
    if not id then return false end
    local min_w, min_h = self.min_for(self:item(id))
    return self:_adopt(Grid.resize(self.boxes, id, axis, delta, self.dims, min_w, min_h))
end

--- Move the selection to page p: any existing page, or the next new one as
--- long as that stays within the page cap. The editor follows it there.
function Session:moveToPage(p)
    local id = self.selected_id
    if not id then return false end
    local pages = Grid.pages(self.boxes)
    local last = pages[#pages] or 1
    if p < 1 or p > MAX_PAGES or p > last + 1 then return self:_refuse() end
    local boxes = Grid.toPage(self.boxes, id, p, self.dims)
    if not boxes then return self:_refuse() end
    self.boxes = boxes
    self.page = p
    self:_render()
    return true
end

function Session:remove()
    local id = self.selected_id
    if not id then return false end
    local _it, i = self:item(id)
    if i then table.remove(self.items, i) end
    for j, b in ipairs(self.boxes) do
        if b.id == id then table.remove(self.boxes, j); break end
    end
    self.selected_id = nil
    -- Leave a page that just emptied for the nearest one still in use.
    local pages = Grid.pages(self.boxes)
    local here = false
    for _j, p in ipairs(pages) do if p == self.page then here = true end end
    if not here and #pages > 0 then
        local pick = pages[1]
        for _j, p in ipairs(pages) do if p < self.page then pick = p end end
        self.page = pick
    end
    self:_render()
    return true
end

--- Pick a module and place it at the first free spot on the current page,
--- then the following pages up to the cap. It becomes the selection.
function Session:add()
    if not self.add_picker then return false end
    self.add_picker(function(entry)
        if not entry then return end
        local w, h = self.size_for(entry)
        w = math.min(w, self.dims.cols)
        h = math.min(h, self.dims.rows)
        local function tryPage(p)
            local c, r = Grid.firstFree(self.boxes, self.dims, p, w, h)
            if not c then return false end
            self.items[#self.items + 1] = entry
            self.boxes[#self.boxes + 1] = { id = entry.id, page = p, col = c, row = r, w = w, h = h }
            self.page = p
            self.selected_id = entry.id
            self:_render()
            return true
        end
        for p = self.page, MAX_PAGES do
            if tryPage(p) then return end
        end
        for p = 1, self.page - 1 do
            if tryPage(p) then return end
        end
        self:_refuse()
    end)
    return true
end

--- Save the working copy: positions written back onto the items, one save.
function Session:commit()
    Grid.writeBack(self.items, self.boxes, self.key)
    self.host:model().save(self.items)
end

--- Open the selected module's settings. Commits first, so the module's own
--- save (which reloads the stored list) sees the positions edited so far.
function Session:settings()
    local id = self.selected_id
    if not id or not self.open_settings then return false end
    self:commit()
    self.open_settings(self:item(id))
    return true
end

return Session
