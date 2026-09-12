-- tests/_test_spine_flatten.lua
-- SpineShelf._flattenItems: one entry per spine, and the three pieces of
-- bookkeeping that decide how a shelf reads.
--
--   item_idx        what the cursor counts
--   run_idx         the visual run: wider gaps either side, a name badge under
--   first_of_group  the head of a run, which the "first in series" face-out
--                   mode stands cover-forward
--
-- A group arrives as ONE item carrying its members. A Home-folders shelf does
-- not: its items are the books, tagged with the folder they live in, because a
-- folder with more books than fit a page could never be paged through if the
-- folder were the item. Both shapes have to produce the same three answers,
-- and the second one did not -- the first book of a folder never faced out.
--
-- Usage (from plugin root): lua tests/_test_spine_flatten.lua
package.path = "./?.lua;./?/init.lua;" .. package.path

local H = dofile("tests/_helpers.lua")
local t = H.runner()

local src  = io.open("lib/bookshelf_spine_shelf.lua"):read("*a")
local body = src:match("\nfunction SpineShelf._flattenItems%(items%)\n(.-)\nend\n")
assert(body, "could not find SpineShelf._flattenItems(items) - renamed?")

local function compile(code, env)
    if _G.setfenv then
        local f = assert(_G.loadstring(code, "_flattenItems"))
        _G.setfenv(f, env)
        return f
    end
    return assert(load(code, "_flattenItems", "t", env))
end

local function flatten(items)
    local env = { ipairs = ipairs, pairs = pairs, type = type, next = next }
    return compile("local items = ... ; " .. body, env)(items)
end

-- A book as the Home-folders source hands it over: the book IS the item, and
-- it carries the folder it belongs to.
local function tagged(name, section)
    return { filepath = "/b/" .. name .. ".epub", shelf_section = section }
end

local function heads(flat)
    local out = {}
    for i = 1, #flat do
        if flat[i].first_of_group then
            out[#out + 1] = flat[i].book.filepath
        end
    end
    return out
end

t.test("flatten: a group's first member is the head of its run", function()
    local flat = flatten({
        { books = { { filepath = "/b/1.epub" }, { filepath = "/b/2.epub" },
                    { filepath = "/b/3.epub" } } },
    })
    assert(#flat == 3, "got " .. #flat)
    assert(flat[1].first_of_group == true, "the first member should be the head")
    assert(not flat[2].first_of_group, "a later member is not the head")
    assert(not flat[3].first_of_group, "a later member is not the head")
end)

t.test("flatten: a group of one has no head to face out", function()
    local flat = flatten({ { books = { { filepath = "/b/1.epub" } } } })
    assert(not flat[1].first_of_group,
        "a run of one is a lone book, not a section with a head")
end)

t.test("flatten: the first book of a folder section is the head of its run", function()
    -- The bug: these books never carried first_of_group, so "first in series"
    -- faced nothing out on a Home-folders shelf.
    local flat = flatten({
        tagged("d1", "Discworld"), tagged("d2", "Discworld"), tagged("d3", "Discworld"),
        tagged("c1", "Culture"),   tagged("c2", "Culture"),
    })
    assert(#flat == 5, "got " .. #flat)
    local h = heads(flat)
    assert(#h == 2, "expected one head per folder, got " .. #h)
    assert(h[1] == "/b/d1.epub", "got " .. tostring(h[1]))
    assert(h[2] == "/b/c1.epub", "got " .. tostring(h[2]))
end)

t.test("flatten: a folder holding one book has no head", function()
    local flat = flatten({
        tagged("a", "Solo"),
        tagged("b", "Pair"), tagged("c", "Pair"),
    })
    local h = heads(flat)
    assert(#h == 1 and h[1] == "/b/b.epub",
        "only the two-book folder has a head; got " .. tostring(h[1]) .. " x" .. #h)
end)

t.test("flatten: untagged books are each their own run, and none is a head", function()
    local flat = flatten({
        { filepath = "/b/1.epub" }, { filepath = "/b/2.epub" },
    })
    assert(#heads(flat) == 0, "loose books have no run to head")
    assert(flat[1].run_idx ~= flat[2].run_idx,
        "loose books must not share a run, or they would badge as a section")
end)

t.test("flatten: a folder's books share a run but count as separate items", function()
    -- The separation the cursor depends on: one item per BOOK, so pagination
    -- can stop anywhere, while the run stays one badged section.
    local flat = flatten({
        tagged("d1", "Discworld"), tagged("d2", "Discworld"),
    })
    assert(flat[1].run_idx == flat[2].run_idx, "same folder, same run")
    assert(flat[1].item_idx ~= flat[2].item_idx,
        "the cursor counts books, so item_idx must differ")
end)

t.test("flatten: two folders of the same name in a row do not merge", function()
    -- Runs are consecutive: a tag change starts a new one. Two different
    -- folders that happen to share a name are still one run here, which is
    -- correct -- they are adjacent and identically labelled, so a reader sees
    -- one section. What must NOT happen is a run continuing across a gap.
    local flat = flatten({
        tagged("a", "Extras"), tagged("b", "Other"), tagged("c", "Extras"),
    })
    assert(flat[1].run_idx ~= flat[3].run_idx,
        "a run must not resume after something else interrupted it")
end)

t.done()
