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
  open_colors(entry),      -- its card and colour menu (the palette icon)
  size_for(entry) -> w, h  -- size for a newly added module
  min_for(entry) -> w, h   -- the module's minimum size (default 1, 1)
  title_for(entry)         -- the module's name, for messages
}
]]
local Grid = require("lib/bookshelf_module_grid")
local _    = require("lib/bookshelf_i18n").gettext

local MAX_PAGES = 4

local Session = {}
Session.__index = Session

-- The move chevrons the shelf and ornament editors use (symbols font).
Session.CHEV_LEFT  = "\xEE\xA1\x80"  -- U+E840 mdi-chevron-left
Session.CHEV_RIGHT = "\xEE\xA1\x81"  -- U+E841 mdi-chevron-right
Session.CHEV_UP    = "\xEE\xA1\x82"  -- U+E842 mdi-chevron-up
Session.CHEV_DOWN  = "\xEE\xA0\xBF"  -- U+E83F mdi-chevron-down
-- Move the selection to the previous / next page (the toolbar's page buttons).
Session.PAGE_PREV  = "\xEE\xA0\xBC"  -- U+E83C mdi-chevron-double-left
Session.PAGE_NEXT  = "\xEE\xA0\xBD"  -- U+E83D mdi-chevron-double-right

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
    s.open_colors   = o.open_colors
    s.size_for      = o.size_for or function() return 1, 1 end
    s.min_for       = o.min_for or function() return 1, 1 end
    s.title_for     = o.title_for or function(entry) return entry.module end
    s.max_pages     = o.max_pages   -- a host with its own page count (a shelf)
    return s
end

function Session:edit()
    return { items = self.items, boxes = self.boxes, page = self.page,
             selected_id = self.selected_id }
end

function Session:_render()
    if self.host and self.host.render then self.host:render(self:edit()) end
end

-- "No room", or "No room to move <module>" when we know what's in the way.
function Session:_refuse(blocker_id)
    local entry = blocker_id and self:item(blocker_id)
    if entry then
        local title = tostring(self.title_for(entry))
        self.notify((_("No room to move %1"):gsub("%%1", function() return title end)))
    else
        self.notify(_("No room"))
    end
    return false
end

-- Take a Grid result: adopt it and re-render, or refuse.
function Session:_adopt(boxes, _why, blocker_id)
    if not boxes then return self:_refuse(blocker_id) end
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
    require("lib/bookshelf_perf").start("editor select")
    self.selected_id = id
    -- Only the outline and the dimming move: a host that can, repaints
    -- without rebuilding its modules (host:reselect).
    if self.host and self.host.reselect and self.host:reselect(self:edit()) then return true end
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
    return self:moveIdBy(self.selected_id, dc, dr)
end

--- Move any module a cell, leaving the selection as it is (a swipe moves the
--- module under the finger without opening its toolbar).
function Session:moveIdBy(id, dc, dr)
    if not self:box(id) then return false end
    return self:_adopt(Grid.move(self.boxes, id, dc, dr, self.dims))
end

--- Move the selection to a tapped cell: its top-left goes there, pulled back
--- just enough to keep the whole module on the grid (it still covers the cell).
function Session:moveToCell(col, row)
    local b = self.selected_id and self:box(self.selected_id)
    if not b then return false end
    col = math.max(1, math.min(col, self.dims.cols - b.w + 1))
    row = math.max(1, math.min(row, self.dims.rows - b.h + 1))
    return self:_adopt(Grid.moveTo(self.boxes, self.selected_id, col, row, self.dims))
end

function Session:resize(axis, delta)
    if not self.selected_id then return false end
    return self:resizeId(self.selected_id, axis, delta)
end

--- Resize any module a cell, leaving the selection as it is (a pinch or
--- spread resizes the module under the fingers without opening its toolbar).
function Session:resizeId(id, axis, delta)
    if not self:box(id) then return false end
    local min_w, min_h = self.min_for(self:item(id))
    local function mins_for(other)
        local it = self:item(other)
        if not it then return 1, 1 end
        return self.min_for(it)
    end
    return self:_adopt(Grid.resize(self.boxes, id, axis, delta, self.dims, min_w, min_h, mins_for))
end

--- Would resizing the selection one cell along `axis` change it? The
--- toolbar hides (on a shelf) a button that would do nothing.
function Session:canResize(axis, delta)
    local id = self.selected_id
    local b = id and self:box(id)
    if not b then return false end
    local min_w, min_h = 1, 1
    if self.min_for then min_w, min_h = self.min_for(self:item(id)) end
    local function mins_for(other)
        local it = self:item(other)
        if not (it and self.min_for) then return 1, 1 end
        return self.min_for(it)
    end
    local out = Grid.resize(self.boxes, id, axis, delta, self.dims, min_w, min_h, mins_for)
    if not out then return false end
    for _i, nb in ipairs(out) do
        if nb.id == id then return nb.w ~= b.w or nb.h ~= b.h end
    end
    return false
end

--- Where the toolbar's previous (-1) / next (1) page button would take the
--- selection: the nearest page in use that way, or for next, a new page when
--- one is allowed and comes after this one. nil when there is nowhere.
function Session:adjacentPage(dir)
    if not self.selected_id then return nil end
    -- A host with its own page count (a shelf, whose books fill every page)
    -- has every page from 1 to that count, modules or not.
    if self.max_pages then
        local p = self.page + (dir < 0 and -1 or 1)
        return (p >= 1 and p <= self.max_pages) and p or nil
    end
    local best
    for _i, p in ipairs(Grid.pages(self.boxes)) do
        if dir < 0 and p < self.page and (not best or p > best) then best = p end
        if dir > 0 and p > self.page and (not best or p < best) then best = p end
    end
    if not best and dir > 0 then
        local np = self:newPage()
        if np and np > self.page then best = np end
    end
    return best
end

--- Move the selection to page p: any existing page, or the next new one as
--- long as that stays within the page cap. The editor follows it there.
function Session:moveToPage(p)
    local id = self.selected_id
    if not id then return false end
    local pages = Grid.pages(self.boxes)
    local exists = false
    for _i, q in ipairs(pages) do if q == p then exists = true end end
    -- On a host with its own page count every page up to it is real;
    -- elsewhere a page without modules is only the next new one.
    if p < 1 or p > self:_maxPages()
            or (not exists and not self.max_pages and p ~= self:newPage()) then
        return self:_refuse()
    end
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
    local it, i = self:item(id)
    if i then table.remove(self.items, i) end
    -- What the card owned goes with it (a Shelf card's own shelf).
    if it then
        local ok, Modules = pcall(require, "lib/bookshelf_start_menu_modules")
        if ok and Modules and Modules.notifyRemoved then Modules.notifyRemoved(it) end
    end
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

--- Pick a module and place it: at (col, row) when given (a long-pressed empty
--- cell) and it fits there, else at the first free spot on the current page,
--- then the following pages up to the cap. It becomes the selection.
function Session:add(col, row)
    if not self.add_picker then return false end
    self.add_picker(function(entry)
        if not entry then return end
        local w, h = self.size_for(entry)
        w = math.min(w, self.dims.cols)
        h = math.min(h, self.dims.rows)
        if col and row then
            local c = math.max(1, math.min(col, self.dims.cols - w + 1))
            local r = math.max(1, math.min(row, self.dims.rows - h + 1))
            local probe = { id = entry.id, page = self.page, col = c, row = r, w = w, h = h }
            local clash = false
            for _i, b in ipairs(self.boxes) do
                if Grid.overlaps(b, probe) then clash = true; break end
            end
            if not clash then
                self.items[#self.items + 1] = entry
                self.boxes[#self.boxes + 1] = probe
                self.selected_id = entry.id
                self:_render()
                return
            end
        end
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
        for p = self.page, self:_maxPages() do
            if tryPage(p) then return end
        end
        for p = 1, math.min(self.page - 1, self:_maxPages()) do
            if tryPage(p) then return end
        end
        self:_refuse()
    end)
    return true
end

--- The first page (up to the cap) holding no module, for "New page"; nil
--- when every page up to the cap is in use.
function Session:newPage()
    local used = {}
    for _i, b in ipairs(self.boxes) do used[b.page] = true end
    for p = 1, self:_maxPages() do
        if not used[p] then return p end
    end
end

--- The page cap: four, unless the host says otherwise (a shelf's pages are
--- the shelf's own, as many as its books make).
function Session:_maxPages()
    return self.max_pages or MAX_PAGES
end

local function label(fmt, n)
    return (fmt:gsub("%%1", tostring(n)))
end

--- Everything the toolbar and edit footer offer, as rows of
--- { text, callback } for a keys-only device (shown as a dialog).
--- opts.has_settings: the selected module has settings; opts.on_done: Done.
function Session:keyActions(opts)
    opts = opts or {}
    local rows = {}
    local function row(list) if #list > 0 then rows[#rows + 1] = list end end
    local function b(text, fn) return { text = text, callback = fn } end
    if self.selected_id then
        local function chev(glyph, fn)
            local btn = b(glyph, fn)
            btn.font_face, btn.font_size, btn.font_bold = "symbols", 28, false
            return btn
        end
        -- As the toolbar: size on the left, position on the right.
        row{
            b(_("Narrower"), function() self:resize("w", -1) end),
            b(_("Wider"),    function() self:resize("w", 1) end),
            chev(Session.CHEV_LEFT,  function() self:moveBy(-1, 0) end),
            chev(Session.CHEV_RIGHT, function() self:moveBy(1, 0) end),
        }
        row{
            b(_("Shorter"),  function() self:resize("h", -1) end),
            b(_("Taller"),   function() self:resize("h", 1) end),
            chev(Session.CHEV_UP,    function() self:moveBy(0, -1) end),
            chev(Session.CHEV_DOWN,  function() self:moveBy(0, 1) end),
        }
        local r = {}
        if opts.has_settings then r[#r + 1] = b(_("Settings"), function() self:settings() end) end
        r[#r + 1] = b(_("Remove"), function() self:remove() end)
        row(r)
    end
    local pages = {}
    for _i, p in ipairs(self:pageList()) do
        if p ~= self.page then
            pages[#pages + 1] = b(label(_("Page %1"), p), function()
                if self.selected_id then self:moveToPage(p) else self:goPage(p) end
            end)
        end
    end
    local np = self.selected_id and self:newPage()
    if np then pages[#pages + 1] = b(_("New page"), function() self:moveToPage(np) end) end
    row(pages)
    row{
        b(_("Add"), function() self:add() end),
        b(_("Done"), function() if opts.on_done then opts.on_done() end end),
    }
    return rows
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

-- colors(): the selected module's colour menu (the toolbar's palette icon),
-- after the layout so far is saved, as settings() does.
function Session:colors()
    local id = self.selected_id
    if not id or not self.open_colors then return false end
    self:commit()
    self.open_colors(self:item(id))
    return true
end

return Session
