-- bookshelf_collection_order.lua
-- Arranging a KOReader collection by hand, from the shelf.
--
-- The collection-order sort key (issue 441) files a collection shelf the way
-- KOReader does. Changing that order meant leaving for KOReader's collections
-- view: the collection > its menu > Arrange books in collection > Manual
-- sorting. This puts the same window one tap from the key it drives.
--
-- Why not just call KOReader's. FileManagerCollection:showArrangeBooksDialog
-- reads the file manager's open booklist (self.booklist_menu.item_table and
-- .path), which does not exist while the shelf is showing, so it cannot be
-- reached from here. Its manual-sort branch is three steps, though, and this
-- is those three steps done the same way:
--
--   1. a SortWidget over the collection's books, in their current order;
--   2. on confirm, each book's position becomes its `order`;
--   3. the collection is marked manually collated, and written.
--
-- Step 3 is not optional. ReadCollection:write persists `order` ONLY for a
-- manually collated collection, so arranging one that still carried a collate
-- of its own would write nothing and lose the arrangement at the next restart.
--
-- Two deliberate departures, both for readers on older KOReader than the one
-- this was written against: positions are written straight onto each item
-- (exactly what ReadCollection:updateCollectionOrder does) instead of calling
-- that method, and coll_settings is guarded, since both arrived with the same
-- collections rework.
--
-- ReadCollection, the repository and the widgets are required inside the
-- functions, so the module loads with nothing but its own file and is
-- testable as it stands.

local _ = require("lib/bookshelf_i18n").gettext

local CollectionOrder = {}

local function collections()
    return require("readcollection")
end

local function basename(path)
    return (tostring(path):gsub(".*/", ""))
end

-- CollectionOrder.exists(name) -> true when a KOReader collection of that name
-- exists.
--
-- Not the same question as "is this a collection chip". The editor maps
-- "Specific tag..." to kind = "collection" with the TAG as the id, and there
-- is rarely a collection behind a tag -- so nothing to arrange.
function CollectionOrder.exists(name)
    if type(name) ~= "string" or name == "" then return false end
    local coll = collections().coll
    return type(coll) == "table" and type(coll[name]) == "table"
end

-- CollectionOrder.items(name) -> { { file, text }, ... } in the order KOReader
-- files the collection, which is where the window has to open.
--
-- `text` is the basename, which is what KOReader's own window lists. A
-- collection with no manual order -- one with a collate of its own, for which
-- KOReader saved no `order` -- starts in name order. KOReader starts from
-- whatever its collate showed; name order is its default, and the nearest
-- thing that does not need a copy of every collate in KOReader's BookList.
function CollectionOrder.items(name)
    local out = {}
    if not CollectionOrder.exists(name) then return out end
    for key, item in pairs(collections().coll[name]) do
        if type(item) == "table" then
            local file = item.file or key
            out[#out + 1] = { file = file, text = basename(file),
                              _order = item.order }
        end
    end
    table.sort(out, function(a, b)
        local ao, bo = a._order, b._order
        if ao ~= nil and bo ~= nil and ao ~= bo then return ao < bo end
        if (ao == nil) ~= (bo == nil) then return ao ~= nil end
        local at, bt = a.text:lower(), b.text:lower()
        if at ~= bt then return at < bt end
        return a.file < b.file
    end)
    for _i, it in ipairs(out) do it._order = nil end
    return out
end

-- CollectionOrder.save(name, items) -> true when written.
--
-- Positions follow `items`. A book that has left the collection since the
-- window opened is skipped rather than indexed blind -- updateCollectionOrder
-- would raise on it. A book that has JOINED since keeps its place relative to
-- any other latecomer, after everything the reader arranged; left with its
-- old order it would collide with a new position.
function CollectionOrder.save(name, items)
    if not CollectionOrder.exists(name) then return false end
    local rc   = collections()
    local coll = rc.coll[name]
    local placed = {}
    local pos = 0
    for _i, it in ipairs(items or {}) do
        local entry = type(it) == "table" and coll[it.file]
        if entry and not placed[it.file] then
            pos = pos + 1
            entry.order = pos
            placed[it.file] = true
        end
    end
    local late = {}
    for key, entry in pairs(coll) do
        if type(entry) == "table" and not placed[entry.file or key] then
            late[#late + 1] = entry
        end
    end
    table.sort(late, function(a, b)
        local ao, bo = a.order or math.huge, b.order or math.huge
        if ao ~= bo then return ao < bo end
        return tostring(a.file) < tostring(b.file)
    end)
    for _i, entry in ipairs(late) do
        pos = pos + 1
        entry.order = pos
    end
    local settings = rc.coll_settings and rc.coll_settings[name]
    if settings then
        settings.collate         = nil
        settings.collate_reverse = nil
    end
    rc:write({ [name] = true })
    -- The shelf's per-source result cache is keyed on (source, filter, sort),
    -- and an arrangement changes none of the three -- so without this the next
    -- render of the shelf was served the OLD order from that cache, and the
    -- maintainer had to swipe down to see it. Only the per-shelf results go:
    -- the walk and the light metadata do not depend on a collection's order.
    local Repo = require("lib/bookshelf_book_repository")
    if Repo.invalidateBookCache then
        Repo.invalidateBookCache("collection arranged: " .. name)
    end
    return true
end

-- CollectionOrder.arrange(name, on_saved) -> true when the window opened.
--
-- Titled with KOReader's own string, so KOReader's catalogue translates it in
-- every language and it reads as the window it is. on_saved runs only after a
-- confirm: SortWidget calls back on its tick alone, and closing it any other
-- way changes nothing.
function CollectionOrder.arrange(name, on_saved)
    if not CollectionOrder.exists(name) then return false end
    local SortWidget = require("ui/widget/sortwidget")
    local UIManager  = require("ui/uimanager")
    local widget
    widget = SortWidget:new{
        title      = _("Arrange books in collection"),
        item_table = CollectionOrder.items(name),
        callback   = function()
            CollectionOrder.save(name, widget.item_table)
            if on_saved then on_saved() end
        end,
    }
    UIManager:show(widget)
    return true
end

return CollectionOrder
