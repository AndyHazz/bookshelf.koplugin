-- tests/_test_derived_cache.lua
-- Things derived from pack files (a plank strip, a plank's measured reach)
-- kept between sessions, keyed on the files as they are.
--
-- Usage (from plugin root): lua tests/_test_derived_cache.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local t  = dofile("tests/_helpers.lua").runner()
local eq = dofile("tests/_helpers.lua").eq

local function fresh()
    package.loaded["lib/bookshelf_derived_cache"] = nil
    local D = dofile("lib/bookshelf_derived_cache.lua")
    local files = { ["/p/mid.png"] = { 5, 100 }, ["/p/end.png"] = { 7, 50 } }
    D._lfs = { attributes = function(p, a)
        local f = files[p]; if not f then return nil end
        return a == "modification" and f[1] or f[2]
    end }
    local saved, pics = {}, {}
    D._store = { read = function(k) return saved[k] end, save = function(k, v) saved[k] = v end }
    D._dc = { load = function(k) return pics[k] end, store = function(k, bb) pics[k] = bb; return true end }
    return D, files, saved, pics
end

t.test("a stamp names the files as they are; an edit changes it", function()
    local D, files = fresh()
    local a = D.stamp("/p/mid.png", nil, "/p/end.png")
    assert(a and a:find("/p/mid.png@5/100", 1, true) and a:find(";-;", 1, true), a)
    files["/p/mid.png"][1] = 6
    assert(D.stamp("/p/mid.png", nil, "/p/end.png") ~= a, "an edited file kept its stamp")
    eq(D.stamp("/p/gone.png"), nil, "a missing file has no stamp")
end)

t.test("values and pictures come back in a later session", function()
    local D, _f, saved, pics = fresh()
    D.put("k", { 3, 9 })          -- no UIManager here: written at once
    D.putBB("k", "pixels")
    package.loaded["lib/bookshelf_derived_cache"] = nil
    local D2 = dofile("lib/bookshelf_derived_cache.lua")
    D2._store = { read = function(k) return saved[k] end, save = function() end }
    D2._dc = { load = function(k) return pics[k] end }
    eq(D2.get("k")[2], 9)
    eq(D2.bb("k"), "pixels")
end)

t.test("the plank strip and the plank's reach are kept, keyed on their files", function()
    local src = io.open("lib/bookshelf_spine_shelf.lua"):read("*a")
    assert(src:find('local stamp = Derived.stamp(design.middle, design.left, design.right)', 1, true))
    assert(src:find('Derived.putBB(dkey, strip)', 1, true), "the strip isn't kept")
    assert(src:find('Derived.put(dkey, { top_h = l.top_h, regions = regions })', 1, true))
    assert(src:find('if dkey and info then Derived.put(dkey, { rows, B0 }) end', 1, true), "the reach isn't kept")
end)

t.done()
