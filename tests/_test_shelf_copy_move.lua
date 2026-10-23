-- tests/_test_shelf_copy_move.lua
-- Copy and Move in the shelf editor (5.6): what readers were doing by hand
-- in the settings file. A copy carries every setting under new ids (a shelf
-- of shelves with its shelves inside, a Shelf module's own shelf with it);
-- a move re-parents a whole tree and keeps the stored list in tree order,
-- and never into itself.
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
local function books(id, parent, extra)
    local t = { id = id, label = id, source = { kind = "all" }, filter = {},
                sort_priority = {}, enabled = true, parent = parent }
    for k, v in pairs(extra or {}) do t[k] = v end
    return t
end
local function ids(list)
    local out = {}
    for _i, t in ipairs(list) do out[#out + 1] = t.id end
    return table.concat(out, ",")
end
local function find(tabs, id)
    for _i, t in ipairs(tabs) do if t.id == id then return t end end
end

-- home, box{ a, inner{ b }, c }, recent
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

test("a copy carries every setting, deep, under a new id", function()
    local tabs = {
        books("custom_1", nil, {
            view_mode = "spines", spine_face_out = { favorites = true, recent = 5 },
            filter = { genres = { "Crime" } }, plank = "p.oak", book_binding = "paperback",
            sort_priority = { { key = "author", reverse = true } },
            shelf_modules = { { id = "sm_1", type = "module", module = "clock", after = 2, w = 1 } },
        }),
    }
    local new_id = TabModel.copyTree(tabs, "custom_1", "custom_1 (copy)")
    assert(new_id and new_id ~= "custom_1", "no new id")
    local src, cp = find(tabs, "custom_1"), find(tabs, new_id)
    assert(cp.label == "custom_1 (copy)", "label")
    for k, v in pairs(src) do
        if k ~= "id" and k ~= "label" then
            assert(cp[k] ~= nil, "lost " .. k)
            if type(v) == "table" then assert(cp[k] ~= v, k .. " is shared, not copied") end
        end
    end
    assert(cp.spine_face_out.recent == 5 and cp.filter.genres[1] == "Crime", "nested values")
    cp.filter.genres[1] = "Horror"
    assert(src.filter.genres[1] == "Crime", "editing the copy changed the original")
    assert(ids(tabs) == "custom_1," .. new_id, "the copy goes right after it")
end)

test("copying a shelf of shelves copies the shelves inside it", function()
    local tabs = tree()
    local new_id = TabModel.copyTree(tabs, "box", "box (copy)")
    local kids = TabModel.childrenOf(new_id, tabs)
    assert(#kids == 3, "children: " .. #kids)
    for _i, k in ipairs(kids) do assert(k.id ~= "a" and k.id ~= "inner" and k.id ~= "c", "a child kept its id") end
    local inner_copy = kids[2]
    assert(inner_copy.label == "inner", "children keep their labels")
    assert(#TabModel.childrenOf(inner_copy.id, tabs) == 1, "the grandchild was not copied")
    assert(#TabModel.childrenOf("box", tabs) == 3, "the original lost a child")
    -- Tree order: the copy's tree sits right after the original's.
    local order = ids(tabs)
    assert(order:match("^home,box,a,inner,b,c," .. new_id .. ","), order)
    assert(order:match(",recent$"), order)
end)

test("a sub-shelf's copy stays in the same shelf of shelves", function()
    local tabs = tree()
    local new_id = TabModel.copyTree(tabs, "a", "a (copy)")
    assert(find(tabs, new_id).parent == "box")
    assert(ids(TabModel.childrenOf("box", tabs)) == "a," .. new_id .. ",inner,c", ids(TabModel.childrenOf("box", tabs)))
end)

test("a Shelf module's own shelf is copied with it, not shared", function()
    local tabs = {
        books("custom_1", nil, { shelf_modules = {
            { id = "sm_1", type = "module", module = "shelf", tab_id = "custom_2", after = 0, w = 3 } } }),
        books("custom_2", nil, { card_only = true }),
    }
    local new_id = TabModel.copyTree(tabs, "custom_1", "copy")
    local m = find(tabs, new_id).shelf_modules[1]
    assert(m.tab_id ~= "custom_2", "the copy's module shows the original's own shelf")
    local own = find(tabs, m.tab_id)
    assert(own and own.card_only, "its shelf was not copied")
    assert(find(tabs, "custom_1").shelf_modules[1].tab_id == "custom_2", "the original's module moved")
end)

test("a copy is never pending", function()
    local tabs = { books("custom_1", nil, { pending = true }) }
    local new_id = TabModel.copyTree(tabs, "custom_1", "copy")
    assert(find(tabs, new_id).pending == nil)
end)

test("moving a shelf into a shelf of shelves takes its tree, in tree order", function()
    local tabs = tree()
    table.insert(tabs, shelves("box2"))
    assert(TabModel.moveTree(tabs, "inner", "box2"))
    assert(find(tabs, "inner").parent == "box2")
    assert(find(tabs, "b").parent == "inner", "the child left its shelf")
    assert(ids(tabs) == "home,box,a,c,recent,box2,inner,b", ids(tabs))
end)

test("moving to the top level clears the parent and goes to the end", function()
    local tabs = tree()
    assert(TabModel.moveTree(tabs, "a", nil))
    assert(find(tabs, "a").parent == nil)
    assert(ids(tabs) == "home,box,inner,b,c,recent,a", ids(tabs))
end)

test("a shelf cannot move into itself, its own shelves, or a shelf of books", function()
    local tabs = tree()
    local before = ids(tabs)
    assert(not TabModel.moveTree(tabs, "box", "box"))
    assert(not TabModel.moveTree(tabs, "box", "inner"))
    assert(not TabModel.moveTree(tabs, "a", "home"))
    assert(ids(tabs) == before and find(tabs, "box").parent == nil, "a refused move changed the list")
end)

test("move targets: every other shelf of shelves, and the top level", function()
    local tabs = tree()
    table.insert(tabs, shelves("box2"))
    table.insert(tabs, shelves("card", { card_only = true }))
    local t = TabModel.moveTargets(tabs, "box")
    local got = {}
    for _i, x in ipairs(t) do got[#got + 1] = x.id or "TOP" end
    assert(table.concat(got, ",") == "TOP,box2", table.concat(got, ","))
    t = TabModel.moveTargets(tabs, "b")
    got = {}
    for _i, x in ipairs(t) do got[#got + 1] = x.id or "TOP" end
    assert(table.concat(got, ",") == "TOP,box,inner,box2", table.concat(got, ","))
end)

-- The "+ Add shelf" tile offers both, and only shelves that could come here.
test("the add tile offers a new shelf or a move, of visible shelves only", function()
    local w = io.open("lib/bookshelf_widget.lua"):read("*a")
    assert(w:find("if folder and folder.add_subshelf then return self:_addOrMoveSubShelf() end", 1, true),
           "the tile's tap does not offer the move")
    local f = w:match("\nfunction BookshelfWidget:_addOrMoveSubShelf%(%)\n(.-)\nend\n")
    assert(f, "_addOrMoveSubShelf not found")
    assert(f:find("if #movable == 0 then return self:_addSubShelf() end", 1, true),
           "no shortcut to a new shelf when nothing could move here")
    assert(f:find("t.enabled ~= false", 1, true), "hidden shelves are offered")
    assert(f:find("TabModel.moveTree(fresh, t.id, here)", 1, true), "the pick does not move the shelf")
end)

io.write(string.format("shelf_copy_move: %d passed, %d failed\n", pass, fail))
if fail > 0 then os.exit(1) end
