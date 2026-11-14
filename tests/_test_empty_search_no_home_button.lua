-- A search with no matches on a Home shelf showed "Set home folder" under
-- "No matches for ...": the button was keyed on the shelf's source alone.
-- _emptyShelfText's second return asks for the button; a search must not.
local H = dofile("tests/_helpers.lua")
local t, eq = H.runner(), H.eq

local src = dofile("tests/_widget_source.lua")
local body = src:match("\nfunction BookshelfWidget:_emptyShelfText%(%)\n(.-)\nend\n")
assert(body, "could not find BookshelfWidget:_emptyShelfText() - renamed?")

local source_id
local function run(source_kind, tip, filtered)
    local env = {
        string = string, select = select,
        _ = function(s) return s end,
        Filter = { isActive = function() return filtered == true end },
        require = function(name)
            if name == "lib/bookshelf_curated" then
                return { exists = function(id) return id == "TBR" end }
            end
            assert(name == "lib/bookshelf_tab_model", "unexpected require " .. name)
            return { getById = function()
                return { label = "Home", filter = {}, source = { kind = source_kind, id = source_id } }
            end }
        end,
    }
    local f
    if _G.setfenv then
        f = assert(_G.loadstring("local self = ...\n" .. body, "_emptyShelfText")); _G.setfenv(f, env)
    else
        f = assert(load("local self = ...\n" .. body, "_emptyShelfText", "t", env))
    end
    local self = { chip = "all", _drilldown_path = { tip }, _chipLabel = function() return "Home" end }
    return f(self)
end

t.test("an empty Home shelf offers Set home folder", function()
    local text, button = run("all", nil)
    assert(text:find("Pick a folder", 1, true), text)
    eq(button, true, "the button is asked for")
end)

t.test("a search with no matches on a Home shelf does not", function()
    local text, button = run("all", { kind = "search", payload = { query = "zz" } })
    eq(text, 'No matches for "zz"')
    eq(button, false, "no home folder button under a search")
    local _text2, button2 = run("library", { kind = "search", payload = { query = "zz" } })
    eq(button2, false, "nor on the flattened Home shelf")
end)

t.test("a search with no matches on a FILTERED shelf still says so", function()
    -- The filter's "Nothing in Home yet" wording used to overwrite it.
    local text = run("all", { kind = "search", payload = { query = "zz" } }, true)
    eq(text, 'No matches for "zz"')
    local plain = run("all", nil, true)
    assert(plain:find("Nothing in Home yet", 1, true), plain)
end)

t.test("an empty shelf on a collection says how books get onto it", function()
    -- The generic wording sends the reader to the shelf editor's source and
    -- filter, where there is nothing to add a book with (issue 390).
    source_id = "TBR"
    local text, button = run("collection", nil)
    source_id = nil
    assert(text:find("Long-press a book", 1, true), text)
    assert(text:find("'Add to a shelf'", 1, true), text)
    -- A long-press on the shelf opens Arrange itself now.
    assert(not text:find("'Arrange'", 1, true), text)
    assert(not text:find("source or filter", 1, true), text)
    eq(button, false)
end)

t.test("a pinned tag's empty shelf keeps the general wording", function()
    -- Kind "collection" too, with no collection to add a book to.
    source_id = "space-opera"
    local text = run("collection", nil)
    source_id = nil
    assert(not text:find("Add to shelf", 1, true), text)
end)

t.test("a shelf that is not Home never asked for it", function()
    local _text, button = run("series", nil)
    eq(button, false)
end)

t.done()
