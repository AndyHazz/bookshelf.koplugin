-- tests/_test_shelf_of_shelves.lua
-- "Shelf of shelves" (5.4): a shelf whose source is { kind = "shelves" }
-- holds sub-shelves -- ordinary tab records carrying `parent`. These tests
-- pin the model: sub-shelves never reach the chip strip, the parent chain
-- reads outermost first, deleting a shelf takes its shelves with it, and new
-- children land after the parent's last descendant.
package.path = "./?.lua;./?/init.lua;" .. package.path

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
    nilOrTrue = function(key)       return stored[key] == nil or stored[key] == true end,
}

local TabModel = dofile("lib/bookshelf_tab_model.lua")

local pass, fail = 0, 0
local function test(name, fn)
    stored = {}
    TabModel.clearOverride()
    local ok, err = pcall(fn)
    if ok then pass = pass + 1
    else fail = fail + 1; io.stderr:write("FAIL  " .. name .. "\n  " .. tostring(err) .. "\n") end
end

local function shelves(id, extra)
    local t = { id = id, label = id, source = { kind = "shelves" }, filter = {},
                sort_priority = {}, enabled = true }
    for k, v in pairs(extra or {}) do t[k] = v end
    return t
end
local function books(id, parent)
    return { id = id, label = id, source = { kind = "all" }, filter = {},
             sort_priority = {}, enabled = true, parent = parent }
end

local function ids(list)
    local out = {}
    for _i, t in ipairs(list) do out[#out + 1] = t.id end
    return table.concat(out, ",")
end

-- A tree:   home, box{ a, inner{ b }, c }, recent
local function tree()
    return {
        books("home"),
        shelves("box"),
        books("a", "box"),
        shelves("inner", { parent = "box" }),
        books("b", "inner"),
        books("c", "box"),
        books("recent"),
    }
end

test("getActive: sub-shelves never reach the chip strip", function()
    TabModel.save(tree())
    assert(ids(TabModel.getActive()) == "home,box,recent", ids(TabModel.getActive()))
end)

test("getActive: an override of a sub-shelf stays out of the strip", function()
    TabModel.save(tree())
    TabModel.setOverride("a", books("a", "box"))
    assert(ids(TabModel.getActive()) == "home,box,recent")
end)

test("isShelves: only the shelves kind", function()
    assert(TabModel.isShelves(shelves("x")))
    assert(not TabModel.isShelves(books("y")))
    assert(not TabModel.isShelves(nil))
end)

test("childrenOf: direct children only, in stored order", function()
    TabModel.save(tree())
    assert(ids(TabModel.childrenOf("box")) == "a,inner,c", ids(TabModel.childrenOf("box")))
    assert(ids(TabModel.childrenOf("inner")) == "b")
    assert(ids(TabModel.childrenOf("home")) == "")
end)

test("childrenOf: an editor override shows its live label", function()
    TabModel.save(tree())
    local o = books("a", "box"); o.label = "renamed"
    TabModel.setOverride("a", o)
    assert(TabModel.childrenOf("box")[1].label == "renamed")
end)

test("ancestorsOf / rootOf: outermost first; top level has none", function()
    TabModel.save(tree())
    assert(ids(TabModel.ancestorsOf("b")) == "box,inner", ids(TabModel.ancestorsOf("b")))
    assert(ids(TabModel.ancestorsOf("a")) == "box")
    assert(ids(TabModel.ancestorsOf("home")) == "")
    assert(TabModel.rootOf("b") == "box")
    assert(TabModel.rootOf("home") == "home")
end)

test("ancestorsOf: a missing parent ends the chain", function()
    TabModel.save({ books("orphan", "gone") })
    assert(ids(TabModel.ancestorsOf("orphan")) == "")
    assert(TabModel.rootOf("orphan") == "orphan")
end)

test("ancestorsOf: a hand-made cycle cannot spin", function()
    TabModel.save({ shelves("p", { parent = "q" }), shelves("q", { parent = "p" }) })
    local chain = TabModel.ancestorsOf("p")
    assert(#chain <= 32, "chain " .. #chain)
end)

test("removeTree: a shelf of shelves takes every level inside it", function()
    local t = tree()
    TabModel.removeTree(t, "box")
    assert(ids(t) == "home,recent", ids(t))
end)

test("removeTree / descendantIds: a hand-made cycle terminates", function()
    local t = { shelves("p", { parent = "q" }), shelves("q", { parent = "p" }), books("home") }
    local d = TabModel.descendantIds("p", t)
    assert(d.q and not d.p, "descendants of p")
    TabModel.removeTree(t, "p")
    assert(ids(t) == "home", ids(t))
end)

test("removeTree: a leaf goes alone", function()
    local t = tree()
    TabModel.removeTree(t, "a")
    assert(ids(t) == "home,box,inner,b,c,recent", ids(t))
end)

test("insertChild: lands after the parent's last descendant", function()
    local t = tree()
    TabModel.insertChild(t, "box", books("d"))
    assert(ids(t) == "home,box,a,inner,b,c,d,recent", ids(t))
    assert(t[7].parent == "box")
    TabModel.insertChild(t, "inner", books("e"))
    assert(ids(t) == "home,box,a,inner,b,e,c,d,recent", ids(t))
end)

test("insertChild: an empty shelf of shelves gets its first child next to it", function()
    local t = { books("home"), shelves("box"), books("recent") }
    TabModel.insertChild(t, "box", books("first"))
    assert(ids(t) == "home,box,first,recent", ids(t))
end)

test("insertAfter: a top-level shelf added from inside a sub-shelf lands after the whole tree", function()
    local t = tree()
    TabModel.insertAfter(t, "b", books("pinned"))
    assert(ids(t) == "home,box,a,inner,b,c,pinned,recent", ids(t))
    assert(t[7].parent == nil)
end)

test("insertAfter: a top-level anchor still inserts right after itself", function()
    local t = tree()
    TabModel.insertAfter(t, "home", books("x"))
    assert(ids(t) == "home,x,box,a,inner,b,c,recent", ids(t))
end)

test("newId: the first free custom_N", function()
    assert(TabModel.newId({ books("custom_1"), books("custom_3") }) == "custom_2")
    assert(TabModel.newId({}) == "custom_1")
end)

test("isSibling: same parent or both top level", function()
    assert(TabModel.isSibling(books("a", "box"), books("c", "box")))
    assert(TabModel.isSibling(books("home"), books("recent")))
    assert(not TabModel.isSibling(books("a", "box"), books("home")))
end)

test("prunePending: a shelf still being created when KOReader stopped is removed", function()
    local t = tree()
    t[#t + 1] = books("half", nil); t[#t].pending = true
    t[#t + 1] = shelves("halfbox", { pending = true })
    t[#t + 1] = books("kid", "halfbox")
    TabModel.save(t)
    assert(TabModel.prunePending() == true, "nothing pruned")
    assert(ids(TabModel.load()) == "home,box,a,inner,b,c,recent", ids(TabModel.load()))
    assert(TabModel.prunePending() == false, "a second prune should find nothing")
end)

test("newTab: a new shelf has no source and is pending until saved", function()
    local t = TabModel.newTab({}, "My shelf")
    assert(t.id == "custom_1" and t.label == "My shelf")
    assert(t.source.kind == "none", tostring(t.source.kind))
    assert(t.pending == true and t.enabled == true)
end)

io.write(string.format("shelf_of_shelves: %d passed, %d failed\n", pass, fail))
if fail > 0 then os.exit(1) end
