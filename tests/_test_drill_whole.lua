-- tests/_test_drill_whole.lua
-- A group opened from book details stays whole after a book closes.
--
-- The pills in book details (author, series, collections, genres) open the
-- whole group on whichever shelf is underneath; the drill carries `whole` so
-- the shelf's filter is not applied (GitHub issue 480). Closing a book rebuilds
-- the shelf from the SAVED drill path, so the flag has to survive
-- _serializeDrillPath and _restoreDrillPath, or the 480 bug comes straight back
-- the first time the reader opens a book from the group.
package.path = "./?.lua;./?/init.lua;" .. package.path
local h  = dofile("tests/_helpers.lua")
local t  = h.runner()
local eq = h.eq

local src = dofile("tests/_widget_source.lua")
local function body(sig)
    local b = src:match("\nfunction BookshelfWidget:" .. sig:gsub("[%(%)]", "%%%0") .. "\n(.-)\nend\n")
    assert(b, sig .. " not found - renamed?")
    return b
end
local function compile(code, env, name)
    if _G.setfenv then
        local f = assert(_G.loadstring(code, name)); _G.setfenv(f, env); return f
    end
    return assert(load(code, name, "t", env))
end

local ser = compile("local self = ... ; " .. body("_serializeDrillPath()"), { ipairs = ipairs }, "ser")
local res = compile("local self, saved = ... ; " .. body("_restoreDrillPath(saved)"), {
    ipairs = ipairs, pairs = pairs, type = type,
    Repo = { findGroup = function(kind, label) return { kind = kind, series_name = label, books = {} } end },
    require = function(name)
        if name == "readcollection" then
            return { coll = { ["To read"] = { ["/a.epub"] = { file = "/a.epub" } } } }
        end
        error("unexpected require " .. name)
    end,
}, "res")

t.test("whole survives a save and restore, for groups and collections", function()
    local saved = ser({ _drilldown_path = {
        { kind = "series", label = "Dune", whole = true },
        { kind = "tag", label = "To read", whole = true },
    } })
    eq(saved[1].whole, true, "series saved whole")
    eq(saved[2].whole, true, "collection saved whole")
    local w = { _drilldown_path = {} }
    res(w, saved)
    eq(w._drilldown_path[1].whole, true, "series restored whole")
    eq(w._drilldown_path[2].whole, true, "collection restored whole")
end)

t.test("a stack tapped on the shelf is saved without it", function()
    local saved = ser({ _drilldown_path = { { kind = "series", label = "Dune" } } })
    eq(saved[1].whole, nil, "no flag")
end)

t.test("every book-details pill opens its group whole", function()
    -- Each pill closes the popup (_navResetAndClose) and then drills.
    local n = 0
    -- Not the folder pill: a folder drill has inherited the shelf's filter
    -- since before 5.3, by design (subfolders inherit it too), so it is not
    -- part of the 480 regression.
    for call in src:gmatch("_navResetAndClose%(%)%s*\n[^\n]-(_expand%a+%b())") do
        if call:find("^_expandFolder") then goto continue end
        n = n + 1
        assert(call:find(",%s*true%s*%)$"), call .. " in book details does not pass whole")
        ::continue::
    end
    for call in src:gmatch("%-%- `whole`[^\n]*\n[^\n]*\n%s*bw:(_expand%a+%b())") do
        n = n + 1
        assert(call:find(",%s*true%s*%)$"), call .. " does not pass whole")
    end
    -- The Tags tab's genre pills reset the path themselves.
    local tags = src:match("self%._drilldown_path = {}%s*\n%s*self:(_expandGenre%b())")
    assert(tags and tags:find(",%s*true%s*%)$"), "Tags tab genre pill does not pass whole")
    assert(n >= 4, "expected the author, series, collection and genre pills, found " .. n)
end)

t.done()
