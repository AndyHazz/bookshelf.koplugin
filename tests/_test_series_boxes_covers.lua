-- tests/_test_series_boxes_covers.lua
-- Series boxes in Covers and List (issue 503): inside an author, genre or
-- any other opened group, and at the top level of a shelf of books (Home,
-- Latest added, Favourites...), a series' books share one series tile,
-- which opens the series. Spines keeps its own boxes; an opened series, a
-- top level of groups or folders and a paged source stay as they are.
package.path = "./?.lua;" .. package.path
local H = dofile("tests/_helpers.lua")
local t, eq = H.runner(), H.eq
local src = io.open("lib/bookshelf_widget.lua"):read("*a")
local function compile(code, env)
    setmetatable(env, {__index=_G})
    if setfenv then local f=assert(loadstring(code)); setfenv(f,env); return f end
    return assert(load(code,"covers series boxes","t",env))
end
local function method(name, env)
    local args, body = src:match("function BookshelfWidget:"..name.."%((.-)%)\n(.-)\nend")
    assert(body,name)
    return compile("return function(self"..(args~="" and ","..args or "")..")\n"..body.."\nend",env)()
end
local tab, metas, built = {}, {}, {}
local Repo = {
    lightMetaFor=function(fp) return metas[fp] end,
    buildBookMeta=function(fp)
        built[#built+1] = fp
        local m = metas[fp] or {filepath=fp}
        local c = {}; for k,v in pairs(m) do c[k]=v end
        c.cover_bb = "bb:"..fp
        return c
    end,
}
package.loaded["lib/bookshelf_tab_model"] = {getById=function() return tab end,
    isShelves=function(t) return t and t.source and t.source.kind == "shelves" end}
package.loaded["lib/bookshelf_scaled_cover_cache"] = {has=function() return false end}
local env = {Repo=Repo}
local function book(n, series, title)
    local b = {filepath="/lib/"..n..".epub",filename=n..".epub",title=title or "Book "..n,
        series_name=series,series_num=series and tostring(n) or nil}
    metas[b.filepath] = b
    return b
end
local function widget(tip, spine)
    local w = {chip="authors",_drilldown_path={tip},_cursor=1,
        _isSpineMode=function() return spine or false end, _opdsEffectiveTab=function() end,
        _viewSize=function() return 12 end, _applyWithinGroupSort=function() end}
    w._coverSeriesBoxes = method("_coverSeriesBoxes", env)
    w._fetchChipItems = method("_fetchChipItems", env)
    w._seriesBoxPage = method("_seriesBoxPage", env)
    return w
end
local function authorTip()
    local stubs = {}
    for _i, b in ipairs({book(1,nil,"Alone"), book(2,"Saga"), book(3,"Saga"), book(4,"Other")}) do
        stubs[#stubs+1] = {filepath=b.filepath}
    end
    return {kind="author", label="Writer", payload={series_name="Writer", books=stubs}}
end

t.test("on, inside an author: a series' books share a tile; one-book series stay books", function()
    tab = {series_boxes=true}; built = {}
    local items, total = widget(authorTip()):_fetchChipItems(12)
    eq(#items, 3); eq(total, 3)
    eq(items[1].filepath, "/lib/1.epub")
    eq(items[2].kind, "series"); eq(items[2].series_name, "Saga"); eq(#items[2].books, 2)
    assert(items[2]._series_box, "not a series box")
    eq(items[3].filepath, "/lib/4.epub")
    -- The tile shows its first book's cover: that one is built, with its cover.
    eq(items[2].books[1].cover_bb, "bb:/lib/2.epub")
    eq(items[2].books[2].cover_bb, nil)
end)

t.test("off, in Spines, inside a series or a group opened from book details: unchanged", function()
    tab = {}
    eq(#widget(authorTip()):_fetchChipItems(12), 4)
    tab = {series_boxes=true}
    local w = widget(authorTip(), true)
    eq(w:_coverSeriesBoxes(), false)
    local tip = authorTip(); tip.whole = true
    eq(#widget(tip):_fetchChipItems(12), 4)
    local s = {kind="series", label="Saga", payload={series_name="Saga", books={{filepath="/lib/2.epub"},{filepath="/lib/3.epub"}}}}
    eq(#widget(s):_fetchChipItems(12), 2)
end)

-- The top level of a shelf of books (Home flattened, Latest added...): the
-- whole list is read light, boxed, and the page cut from the tiles.
local shelf_items, shelf_hint
Repo.getBySource = function(_src, _filter, _sort, offset, limit, opts)
    if opts and opts.light_only then
        local all = {}
        for i, it in ipairs(shelf_items) do all[i] = it end
        return all, shelf_hint
    end
    local page = {}
    for i = offset + 1, math.min(offset + limit, #shelf_items) do page[#page + 1] = shelf_items[i] end
    return page, #shelf_items
end
local function topShelf(kind)
    local w = widget(nil)
    w._drilldown_path = {}
    w.chip = "all"
    tab = {series_boxes=true, source={kind=kind or "all"}}
    return w
end
local function lightBooks()
    local out = {}
    for _i, b in ipairs({book(11,nil,"Alone"), book(12,"Saga"), book(13,"Saga"), book(14,"Other"), book(15,"Saga")}) do
        out[#out+1] = {filepath=b.filepath}
    end
    return out
end

t.test("the top level of a shelf of books: a series' books share a tile", function()
    shelf_items, shelf_hint, built = lightBooks(), nil, {}
    local w = topShelf()
    eq(w:_coverSeriesBoxes(), true)
    local items, total = w:_fetchChipItems(12)
    eq(total, 3, "the page did not count tiles")
    eq(items[1].filepath, "/lib/11.epub")
    eq(items[2].kind, "series"); eq(#items[2].books, 3)
    eq(items[2].books[1].cover_bb, "bb:/lib/12.epub", "the box's front was not built")
    eq(items[3].filepath, "/lib/14.epub")
    eq(items[1].cover_bb, "bb:/lib/11.epub", "a book on the page was not built")
end)

t.test("the top level pages by tiles", function()
    shelf_items, shelf_hint = lightBooks(), nil
    local w = topShelf()
    w._viewSize = function() return 2 end
    w._cursor = 3
    local items, total = w:_fetchChipItems(2)
    eq(total, 3); eq(#items, 1); eq(items[1].filepath, "/lib/14.epub")
end)

t.test("a top level of groups or folders, a paged source, one series, Spines: as before", function()
    -- groups at the top (Authors, Home as folders)
    shelf_items, shelf_hint = lightBooks(), nil
    table.insert(shelf_items, 2, {kind="folder", path="/lib/sub", label="sub"})
    local items, total = topShelf():_fetchChipItems(12)
    eq(#items, 6, "a top level with a folder on it was boxed"); eq(total, 6)
    -- a paged source: only part of the list comes back
    shelf_items, shelf_hint = lightBooks(), 500
    items = topShelf():_fetchChipItems(12)
    eq(#items, 5, "a paged source was boxed from one window")
    -- a single series' shelf is the series
    shelf_items, shelf_hint = lightBooks(), nil
    eq(topShelf("single_series"):_coverSeriesBoxes(), false)
    -- a shelf of shelves
    eq(topShelf("shelves"):_coverSeriesBoxes(), false)
    -- Spines draws its own
    local w = topShelf(); w._isSpineMode = function() return true end
    eq(w:_coverSeriesBoxes(), false)
end)

t.test("paging counts tiles, not books", function()
    tab = {series_boxes=true}
    local w = widget(authorTip())
    w._viewSize = function() return 2 end
    w._cursor = 3
    local items, total = w:_fetchChipItems(2)
    eq(total, 3); eq(#items, 1); eq(items[1].filepath, "/lib/4.epub")
end)

-- Authors > Writer > Saga: the series opened inside an author is not a
-- cross-kind drill, so the first crumb stays the shelf's own (the first
-- drill decides, not the deepest).
t.test("a series opened inside an author keeps the shelf's own first crumb", function()
    local i = src:find("local DRILL_LABEL = {", 1, true)
    assert(i, "no drill label override")
    local before = src:sub(i - 2500, i)
    assert(before:find("local tip = self._drilldown_path[1]\n", 1, true),
        "the deepest drill relabels the first crumb")
end)

t.done()
