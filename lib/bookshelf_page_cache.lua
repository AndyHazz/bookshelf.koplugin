--[[--
The last few shelf pages a page turn left, kept so turning back to one costs
no rebuild: its row widgets as built (their own render caches with them) and
the page state the build set on the shelf (where the next page starts, the
books shown, the badges). A page turn back and forth is the common case this
serves; one that builds a page from nothing is unchanged.

The cache is only ever right between plain page turns. Anything else that
changes a shelf (a rebuild, a refresh of covers or statuses, a setting, the
selection, a non-turn swap) clears it, and the key carries what a page shows
(the shelf, the drill, the cursor, the items, the data generation, night
mode, the geometry), so a stale page is a miss, never a hit.

  local PageCache = require("lib/bookshelf_page_cache")
  local pc = PageCache.new()
  PageCache.put(pc, { key = k, rows = rows, state = state })
  local e = PageCache.take(pc, k)   -- removed from the cache: it is live again
  PageCache.clear(pc)               -- frees every kept page
]]

local M = {}

-- Six pages: the one just left, the one built ahead of the next turn, and
-- the pages of the shelves switched away from (each switch also builds the
-- new shelf's next page ahead, so four left room for one other shelf).
-- Each holds its row widgets and their renders; a turn's page its pixels
-- too (2 MB on a PW5), a page kept by a switch none.
M.MAX = 6

-- Off switch, for tests and the rig's comparison runs.
M.enabled = true

function M.new()
    return { list = {} }
end

local function free(entry)
    for _i, w in ipairs(entry.rows or {}) do
        if w and w.free then pcall(function() w:free() end) end
    end
    entry.rows = nil
    if entry.px and entry.px.bb and entry.px.bb.free then pcall(function() entry.px.bb:free() end) end
    entry.px = nil
end
M._free = free

-- take(pc, key) -> the entry kept under key, removed from the cache; nil on
-- a miss (or with the cache switched off).
function M.take(pc, key)
    if not (pc and key and M.enabled) then return nil end
    for i, e in ipairs(pc.list) do
        if e.key == key then
            table.remove(pc.list, i)
            return e
        end
    end
    return nil
end

-- has(pc, key) -> true when a page is kept under key (left in the cache).
function M.has(pc, key)
    if not (pc and key and M.enabled) then return false end
    for _i, e in ipairs(pc.list) do
        if e.key == key then return true end
    end
    return false
end

-- put(pc, entry): keep entry (newest first); the oldest beyond MAX is freed.
-- An entry under a key already kept replaces it.
function M.put(pc, entry)
    if not (pc and entry and entry.key and M.enabled) then
        if entry then free(entry) end
        return
    end
    for i = #pc.list, 1, -1 do
        if pc.list[i].key == entry.key then
            free(table.remove(pc.list, i))
        end
    end
    table.insert(pc.list, 1, entry)
    while #pc.list > M.MAX do
        free(table.remove(pc.list))
    end
end

-- clear(pc): free every kept page.
function M.clear(pc)
    if not pc then return end
    for _i, e in ipairs(pc.list) do free(e) end
    pc.list = {}
end

function M.size(pc) return pc and #pc.list or 0 end

return M
