-- tests/_test_shelf_of_shelves_nav.lua
-- The widget side of "Shelf of shelves" (5.4), driven against the real method
-- bodies (extracted by name, run under stubs, as _test_list_view_gesture
-- does): the tiles a shelf of shelves shows, going into a sub-shelf, and the
-- breadcrumb's numbering on the way back up -- the top-level shelf, then one
-- crumb per shelf below it, then the drills on the shelf on screen.
package.path = "./?.lua;./?/init.lua;" .. package.path
local H = dofile("tests/_helpers.lua")
local t, eq = H.runner(), H.eq

package.loaded["logger"] = { dbg = function() end, info = function() end,
                              warn = function() end, err = function() end }
local stored = {}
package.loaded["lib/bookshelf_settings_store"] = {
    read   = function(key, default) local v = stored[key]; if v == nil then return default end; return v end,
    save   = function(key, value)   stored[key] = value end,
    saveDeferred = function(key, value) stored[key] = value end,
    delete = function(key)          stored[key] = nil end,
    flush  = function() end,
    isTrue = function(key)          return stored[key] == true end,
}
local TabModel = dofile("lib/bookshelf_tab_model.lua")
package.loaded["lib/bookshelf_tab_model"] = TabModel
package.loaded["lib/bookshelf_scaled_cover_cache"] = { has = function() return false end }

local src = io.open("lib/bookshelf_widget.lua"):read("*a")

local function compile(code, env, chunkname)
    if _G.setfenv then
        local f = assert(_G.loadstring(code, chunkname))
        _G.setfenv(f, env)
        return f
    end
    return assert(load(code, chunkname, "t", env))
end

-- BookshelfWidget:name(args) as a function of (self, args...).
local function methodOf(name, env)
    local args, body = src:match("\nfunction BookshelfWidget:" .. name
        .. "%(([^)]*)%)\n(.-)\nend\n")
    assert(body, "could not find BookshelfWidget:" .. name .. " - renamed?")
    local params = (args ~= "" and ("self, " .. args) or "self")
    return compile("return function(" .. params .. ")\n" .. body .. "\nend", env, name)()
end

local function tab(id, kind, parent)
    return { id = id, label = id:upper(), source = { kind = kind }, filter = {},
             sort_priority = {}, enabled = true, parent = parent }
end
local function seed()
    stored = {}
    TabModel.clearOverride()
    TabModel.save({
        tab("home", "all"),
        tab("box", "shelves"),
        tab("a", "authors", "box"),
        tab("inner", "shelves", "box"),
        tab("b", "all", "inner"),
        tab("recent", "recent"),
    })
end

local fetched = {}
local Repo = {
    getBySource = function(source)
        fetched[#fetched + 1] = source.kind
        if source.kind == "authors" then
            return { { kind = "author", series_name = "X", books = { { filepath = "/l/x1.epub" } } } }
        end
        return { { filepath = "/l/1.epub" }, { filepath = "OPDS://k/2" }, { filepath = "/l/3.epub" } }
    end,
    buildBookMeta = function(fp) return { filepath = fp, title = fp } end,
}

local env = setmetatable({
    require = function(name) return package.loaded[name] or require(name) end,
    Repo = Repo,
    _ = function(s) return s end,
    BookshelfSettings = package.loaded["lib/bookshelf_settings_store"],
    UIManager = { setDirty = function() end },
}, { __index = _G })

local W = {}
for _i, name in ipairs({ "_shelfChain", "_shelfCrumbCount", "_navDepth", "_navBackTo",
                         "_openShelf", "_enterSubShelf", "_subShelfItems",
                         "_subShelfCoverFps", "_chipNeighbour" }) do
    W[name] = methodOf(name, env)
end

-- A widget stand-in carrying the real methods and recording what they did.
local function widget(chip, drill)
    local w = { chip = chip, _cursor = 7, _drilldown_path = drill or {}, log = {} }
    for k, f in pairs(W) do w[k] = f end
    w._markOpdsNav = function() end
    w._clearDpadFocus = function() end
    w._syncPageFromCursor = function() end
    w._rebuild = function(self) self.log[#self.log + 1] = "rebuild:" .. self.chip end
    w._drillBackTo = function(self, d) self.log[#self.log + 1] = "drill:" .. d end
    return w
end

t.test("a shelf of shelves shows its shelves, then the + tile", function()
    seed()
    local w = widget("box")
    local items, total = w:_subShelfItems(TabModel.getById("box"), 0, 10)
    eq(total, 3)
    eq(items[1].subshelf_id, "a"); eq(items[1].kind, "folder"); eq(items[1].label, "A")
    eq(items[2].subshelf_id, "inner")
    assert(items[3].add_subshelf == true and items[3].kind == "folder", "no + tile last")
    assert(items[1].path == nil, "a sub-shelf tile must carry no folder path")
end)

t.test("the tiles page like any other listing", function()
    seed()
    local w = widget("box")
    local items, total = w:_subShelfItems(TabModel.getById("box"), 2, 2)
    eq(total, 3); eq(#items, 1)
    assert(items[1].add_subshelf, "page 2 is the + tile")
end)

t.test("a tile's covers come from what its shelf opens on; remote records skipped", function()
    seed()
    local w = widget("box")
    local fps = w:_subShelfCoverFps(TabModel.getById("b"), 4)
    eq(table.concat(fps, ","), "/l/1.epub,/l/3.epub")
    -- a grouped shelf lends its groups' lead books
    eq(table.concat(w:_subShelfCoverFps(TabModel.getById("a"), 4), ","), "/l/x1.epub")
    -- a shelf of shelves borrows from its own shelves
    eq(table.concat(w:_subShelfCoverFps(TabModel.getById("box"), 2), ","), "/l/x1.epub,/l/1.epub")
end)

t.test("an empty shelf of shelves is just the + tile", function()
    seed()
    local tabs = TabModel.load(); tabs[#tabs + 1] = tab("empty", "shelves"); TabModel.save(tabs)
    local items, total = widget("empty"):_subShelfItems(TabModel.getById("empty"), 0, 8)
    eq(total, 1); assert(items[1].add_subshelf)
end)

t.test("going in makes the sub-shelf the active chip and remembers the parent's page", function()
    seed()
    local w = widget("box")
    w:_enterSubShelf("inner")
    eq(w.chip, "inner"); eq(w._cursor, 1)
    eq(w._shelf_cursors.box, 7)
    eq(stored.active_chip, "inner")
end)

t.test("an unknown sub-shelf is not entered", function()
    seed()
    local w = widget("box")
    w:_enterSubShelf("nope")
    eq(w.chip, "box"); eq(#w.log, 0)
end)

t.test("crumbs: one per level below the top-level shelf", function()
    seed()
    eq(widget("box"):_navDepth(), 0)
    eq(widget("a"):_navDepth(), 1)
    eq(widget("b"):_navDepth(), 2)
    eq(widget("b", { { kind = "folder" } }):_navDepth(), 3)
    -- search shows only its query
    eq(widget("b", { { kind = "search" } }):_navDepth(), 1)
end)

t.test("back up the chain: pill = top-level shelf, crumb k = k-th shelf below", function()
    seed()
    local w = widget("b")
    w._shelf_cursors = { inner = 4 }
    w:_navBackTo(1)
    eq(w.chip, "inner"); eq(w._cursor, 4, "the parent's page is not restored")
    w = widget("b")
    w:_navBackTo(0)
    eq(w.chip, "box")
end)

t.test("a crumb inside the drills pops drills, not shelves", function()
    seed()
    local w = widget("b", { { kind = "folder" }, { kind = "folder" } })
    w:_navBackTo(3)
    eq(w.chip, "b"); eq(w.log[1], "drill:1")
    w = widget("b", { { kind = "folder" } })
    w:_navBackTo(2)
    eq(w.log[1], "drill:0")
end)

t.test("climbing out of a sub-shelf drops its drills", function()
    seed()
    local w = widget("b", { { kind = "folder" } })
    w:_navBackTo(1)
    eq(w.chip, "inner"); eq(#w._drilldown_path, 0)
end)

t.test("chip neighbours from inside a sub-shelf are its top-level shelf's", function()
    seed()
    local w = widget("b")
    w._active_chip_keys = { "home", "box", "recent" }
    eq(w:_chipNeighbour(1), "recent")
    eq(w:_chipNeighbour(-1), "home")
end)

t.test("the fetch, the tap and the long-press know a sub-shelf tile", function()
    assert(src:find("if not tip and TabModel.isShelves(tab) then\n        return self:_subShelfItems(", 1, true),
        "_fetchChipItems does not route a shelf of shelves to its tiles")
    local exp = src:match("\nfunction BookshelfWidget:_expandFolder%(folder%)\n(.-)\nend\n")
    assert(exp and exp:find("folder.subshelf_id", 1, true) and exp:find("folder.add_subshelf", 1, true),
        "_expandFolder does not open sub-shelves / the + tile")
    local menu = src:match("\nfunction BookshelfWidget:_openGroupMenu%(group, kind%)\n(.-)\nend\n")
    assert(menu and menu:find("group.subshelf_id", 1, true), "long-press does not edit a sub-shelf")
end)

t.test("the breadcrumb and the back gestures count shelves as well as drills", function()
    local _, n = src:gsub("self:_navBackTo%(", "")
    assert(n >= 3, "breadcrumb tap, page-1 back and device Back should all climb shelves (" .. n .. ")")
    assert(src:find("local nav_n = self:_navDepth()", 1, true), "page-1 back ignores the shelf chain")
end)

t.test("the editor deletes a shelf's whole tree and moves among siblings", function()
    local ed = io.open("lib/bookshelf_chip_editor.lua"):read("*a")
    assert(ed:find("TabModel.removeTree(del_tabs, tab_id)", 1, true),
        "delete leaves a shelf of shelves' shelves behind")
    local _, n = ed:gsub("TabModel%.isSibling%(", "")
    assert(n >= 2, "the move arrows and their enabled state do not both walk siblings")
    assert(ed:find('btn("shelves", _("Shelf of shelves"))', 1, true), "no Shelf of shelves source")
end)

t.test("go home climbs out of a shelf of shelves on both paths", function()
    assert(src:find('self.chip = require("lib/bookshelf_tab_model").rootOf(self.chip)', 1, true),
        "a fresh widget's go-home leaves the reader in the sub-shelf")
    local m = io.open("main.lua"):read("*a")
    assert(m:find("_live_widget.chip = TabModel.rootOf(_live_widget.chip)", 1, true),
        "a live widget's go-home leaves the reader in the sub-shelf")
end)

t.test("changing a shelf of shelves' source asks, then deletes its shelves", function()
    local ed = io.open("lib/bookshelf_chip_editor.lua"):read("*a")
    local _, n = ed:gsub("withShelvesResolved%(function%(drop%)", "")
    eq(n, 2, "Save and + must both ask before hiding a shelf of shelves' shelves")
    local _, d = ed:gsub("if drop then dropShelves%(save_tabs%) end", "")
    eq(d, 2, "an OK must delete the shelves on both paths")
end)

t.test("sub-shelves stay out of the strip's shelf list in settings", function()
    local s = io.open("lib/bookshelf_settings.lua"):read("*a")
    assert(s:find("        if not tab.parent then\n        items[#items + 1] = {", 1, true),
        "the settings shelf list shows sub-shelves")
end)

t.done()
