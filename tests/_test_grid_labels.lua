-- tests/_test_grid_labels.lua
-- The label strip is budgeted only for a chip that will print a label.
--
-- WHAT NEEDS PINNING. With "text below covers" on, every tile reserves a strip
-- under itself so cover bottoms line up across a row that mixes books and
-- folders. A chip whose tiles ALL carry their name inside (a folder chip in
-- the divider or text style) reserved the strip for nothing: a blank band
-- under every row, and the bottom gap the height of a label bigger than the
-- top one. Now _shelfLabelMode answers nil for such a chip, and every budget
-- (the collapsed split, the expanded title block, the row builder) follows.
--
-- The items are only known after the fetch, which runs after the layout has
-- already sized the rows. So the layout assumes what it knew last time (or
-- "labels" when it knows nothing about this chip yet), the fetch notes the
-- truth, and when the two disagree the rebuild runs once more.
--
-- Bodies are extracted by name (see _test_chip_bar_border); _rebuild itself
-- is pinned at source level.
package.path = "./?.lua;./?/init.lua;" .. package.path
local helpers = dofile("tests/_helpers.lua")
local t  = helpers.runner()
local eq = helpers.eq
local src = io.open("lib/bookshelf_widget.lua"):read("*a")

local function compile(code, env, name)
    if _G.setfenv then
        local f = assert(_G.loadstring(code, name)); _G.setfenv(f, env); return f
    end
    return assert(load(code, name, "t", env))
end
local function method(name)
    local body = src:match("\nfunction BookshelfWidget:" .. name .. "%((.-)%)\n(.-)\nend\n")
    assert(body, "could not find BookshelfWidget:" .. name)
    local params, code = src:match("\nfunction BookshelfWidget:" .. name .. "%((.-)%)\n(.-)\nend\n")
    return params, code
end
local function bind(env, name)
    local params, code = method(name)
    local f = compile("return function(self" .. (params ~= "" and (", " .. params) or "") .. ")\n" .. code .. "\nend", env, name)
    return f()
end

-- One environment: the settings store and StackDisplay are the two outside
-- collaborators; everything else is arithmetic on self.
local stored = {}
local any_label = true
local repo_has_books = nil     -- what Repo.allHasBooks answers; nil = nothing cached
local repo_asked_path = false
local env = {
    type = type, tostring = tostring, pairs = pairs, ipairs = ipairs, math = math,
    BookshelfSettings = { read = function(k) return stored[k] end },
    require = function(name)
        if name == "lib/bookshelf_stack_display" then
            return { anyExternalLabel = function(items, override) return any_label end }
        elseif name == "lib/bookshelf_book_repository" then
            return { allHasBooks = function(path) repo_asked_path = path or "<root>"; return repo_has_books end }
        end
        error("unexpected require " .. name)
    end,
}
local shelfLabelMode  = bind(env, "_shelfLabelMode")
local gridDrawsLabels = bind(env, "_gridDrawsLabels")
local gridLabelsKey   = bind(env, "_gridLabelsKey")
local noteGridLabels  = bind(env, "_noteGridLabels")

-- The bodies call each other through self, so the fake shelf carries them.
local function shelf()
    return { chip = "home", _drilldown_path = {},
             _groupDisplayMode = function() return nil end,
             _gridDrawsLabels = gridDrawsLabels, _gridLabelsKey = gridLabelsKey,
             _noteGridLabels = noteGridLabels, _shelfLabelMode = shelfLabelMode }
end

t.test("with nothing known about the chip, the layout assumes labels", function()
    local w = shelf()
    stored.expanded_shelf_label = "title"
    eq(gridDrawsLabels(w), true)
    eq(shelfLabelMode(w), "title")
end)

t.test("a chip noted as label-free answers no label mode at all", function()
    local w = shelf()
    stored.expanded_shelf_label = "title"
    any_label = false
    eq(noteGridLabels(w, { { kind = "folder", label = "A" } }), false)
    eq(gridDrawsLabels(w), false)
    eq(shelfLabelMode(w), nil, "the strip must not be budgeted for a chip that prints no label")
    any_label = true
end)

t.test("the note is per chip and per drill level", function()
    local w = shelf()
    stored.expanded_shelf_label = "title"
    any_label = false
    noteGridLabels(w, {})
    eq(gridDrawsLabels(w), false)
    w.chip = "recent"
    eq(gridDrawsLabels(w), true, "another chip starts from the assumption again")
    w.chip = "home"
    w._drilldown_path = { { kind = "folder", payload = { path = "/x" } } }
    eq(gridDrawsLabels(w), true, "drilling into a folder is another item set")
    assert(gridLabelsKey(w) ~= gridLabelsKey(shelf()), "the key must carry the drill tip")
    any_label = true
end)

t.test("labels off in settings stays off whatever the chip holds", function()
    local w = shelf()
    stored.expanded_shelf_label = "none"
    any_label = true
    eq(shelfLabelMode(w), nil)
end)

t.test("a windowed fetch showing only folders asks the repository about the whole set", function()
    -- all/folder sources page in the repository: all_items is one PAGE. A
    -- first page of folder cards says nothing about the books that follow,
    -- and the strip must not come and go with the page (the rows would
    -- change height on a page turn). The repository has the whole shape
    -- list cached from the fetch it just served.
    local w = shelf()
    stored.expanded_shelf_label = "title"
    any_label = false
    repo_has_books = true; repo_asked_path = false
    eq(noteGridLabels(w, { { kind = "folder", label = "A" } }, true), true)
    eq(repo_asked_path, "<root>", "no drill: the library root")
    repo_has_books = false
    eq(noteGridLabels(w, { { kind = "folder", label = "A" } }, true), false,
        "a set of folders alone reserves no strip")
    repo_has_books = nil
    eq(noteGridLabels(w, { { kind = "folder", label = "A" } }, true), true,
        "nothing cached: assume labels, the safe side")
    any_label = true
end)

t.test("a page that already shows a label never troubles the repository", function()
    local w = shelf()
    any_label = true; repo_asked_path = false; repo_has_books = false
    eq(noteGridLabels(w, { { filepath = "/a.epub" } }, true), true)
    eq(repo_asked_path, false)
end)

t.test("a complete (unwindowed) fetch is judged on its own items", function()
    local w = shelf()
    any_label = false; repo_asked_path = false; repo_has_books = true
    eq(noteGridLabels(w, { { kind = "folder", label = "A" } }, false), false)
    eq(repo_asked_path, false, "the items ARE the whole set; nothing to ask")
    any_label = true
end)

t.test("drilled into a folder, the repository is asked about that folder", function()
    local w = shelf()
    w._drilldown_path = { { kind = "folder", payload = { path = "/lib/Discworld" } } }
    any_label = false; repo_asked_path = false; repo_has_books = true
    noteGridLabels(w, { { kind = "folder", label = "A" } }, true)
    eq(repo_asked_path, "/lib/Discworld")
    any_label = true
end)

t.test("_rebuild notes the labels after the fetch and re-runs once when the layout guessed wrong", function()
    local body = src:match("\nfunction BookshelfWidget:_rebuild%(%)\n(.-)\nend\n")
    assert(body, "no _rebuild")
    local assumed_at = body:find("local grid_labels_assumed = self:_gridDrawsLabels()", 1, true)
    local shelves_at = body:find("local n_shelves     = self:_nShelves()", 1, true)
    assert(assumed_at and shelves_at and assumed_at < shelves_at,
        "the assumption must be recorded before the row count is decided")
    local note_at = body:find("self:_noteGridLabels(all_items, _total_hint ~= nil)", 1, true)
    local fetch_at = body:find("self:_fetchChipItems(MAX_FETCH)", 1, true)
    assert(note_at and fetch_at and note_at > fetch_at, "the note must follow the fetch")
    assert(body:find("return self:_rebuild()", 1, true), "no re-run when the guess was wrong")
    assert(body:find("_grid_labels_retry", 1, true), "the re-run has no guard against looping")
end)

t.done()
