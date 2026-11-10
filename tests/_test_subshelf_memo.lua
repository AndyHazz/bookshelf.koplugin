-- A shelf of shelves asked every shelf inside it for its books on every
-- build. _subShelfMemo keeps each answer while the repository has dropped no
-- cache (Repo.cacheEpoch) and no shelf has been saved (TabModel.generation).
local H = dofile("tests/_helpers.lua")
local t, eq = H.runner(), H.eq

local src = dofile("tests/_widget_source.lua")
local function method(sig)
    local body = src:match("\nfunction BookshelfWidget:" .. sig .. "\n(.-)\nend\n")
    return assert(body, "could not find BookshelfWidget:" .. sig .. " - renamed?")
end

local epoch, tabgen = 1, 1
local env = setmetatable({
    Repo = { cacheEpoch = function() return epoch end },
    require = function(name)
        assert(name == "lib/bookshelf_tab_model", "unexpected require " .. name)
        return { generation = function() return tabgen end }
    end,
}, { __index = _G })
local function compile(args, body, name)
    local code = "local self, " .. args .. " = ...\n" .. body
    if _G.setfenv then
        local f = assert(_G.loadstring(code, name)); _G.setfenv(f, env); return f
    end
    return assert(load(code, name, "t", env))
end
local memo = compile("slot, tab, compute", method("_subShelfMemo%(slot, tab, compute%)"), "_subShelfMemo")

local function widget()
    local w = { calls = 0 }
    w._subShelfMemo = memo
    return w
end
local function counted(w, value)
    return function() w.calls = w.calls + 1; return value end
end

t.test("the same shelf and slot is worked out once", function()
    local w = widget()
    local list = { "/a", "/b" }
    local a = w:_subShelfMemo("members", { id = "x" }, counted(w, list))
    local b = w:_subShelfMemo("members", { id = "x" }, counted(w, { "/other" }))
    eq(w.calls, 1); assert(a == list and b == list, "the kept list is handed back")
end)

t.test("another shelf, or another slot, is its own answer", function()
    local w = widget()
    w:_subShelfMemo("members", { id = "x" }, counted(w, {}))
    w:_subShelfMemo("members", { id = "y" }, counted(w, {}))
    w:_subShelfMemo("covers4", { id = "x" }, counted(w, {}))
    eq(w.calls, 3)
end)

t.test("an empty list is an answer too, and is kept", function()
    local w = widget()
    w:_subShelfMemo("members", { id = "x" }, counted(w, {}))
    w:_subShelfMemo("members", { id = "x" }, counted(w, {}))
    eq(w.calls, 1)
end)

t.test("the repository dropping a cache asks again", function()
    local w = widget()
    w:_subShelfMemo("members", { id = "x" }, counted(w, { "/a" }))
    epoch = epoch + 1
    local again = w:_subShelfMemo("members", { id = "x" }, counted(w, { "/a", "/new" }))
    eq(w.calls, 2); eq(#again, 2, "the new list, not the kept one")
end)

t.test("a shelf being saved asks again", function()
    local w = widget()
    w:_subShelfMemo("members", { id = "x" }, counted(w, { "/a" }))
    tabgen = tabgen + 1
    w:_subShelfMemo("members", { id = "x" }, counted(w, { "/a" }))
    eq(w.calls, 2)
end)

t.test("an answer worked out while the epoch moved is not kept under the old one", function()
    local w = widget()
    w:_subShelfMemo("members", { id = "x" }, function()
        w.calls = w.calls + 1
        epoch = epoch + 1          -- the walk found new files part-way
        return { "/a" }
    end)
    w:_subShelfMemo("members", { id = "x" }, counted(w, { "/a", "/b" }))
    eq(w.calls, 2, "asked again under the new epoch")
end)

t.test("the tile's count and its covers both go through it", function()
    assert(method("_subShelfMemberFps%(tab%)"):find('self:_subShelfMemo("members", tab', 1, true))
    assert(method("_subShelfCoverFps%(tab, n, depth%)"):find('self:_subShelfMemo("covers" .. tostring(n), tab', 1, true))
end)

t.done()
