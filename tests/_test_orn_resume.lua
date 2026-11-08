-- tests/_test_orn_resume.lua
-- Reopening a spine shelf on a later page takes its ornament deal from the
-- last session instead of laying out every page before it.
--
-- On a PW3 a start on page 5+ spent 0.3-0.45 s in _spinePageFirsts just to
-- find which pieces that page starts with. The state a page was rendered
-- with is remembered (in memory; written with the next settings flush)
-- under a fingerprint of everything it rests on, by content: the shelf and
-- its list, the deck's saved order and level, the theme, the rows and the
-- page's size. On a start with the same fingerprint it is used as is.
package.path = "./?.lua;" .. package.path
local H = dofile("tests/_helpers.lua")
local t, eq = H.runner(), H.eq
local W = io.open("lib/bookshelf_widget.lua"):read("*a")

local function body(sig)
    return assert(W:match("\nfunction BookshelfWidget:" .. sig .. "\n(.-)\nend\n"), sig .. " moved")
end
local START = body("_ornStartState%(dims%)")
local REMEMBER = body("_ornRemember%(key, st, dims%)")
local SAVED = body("_ornSaved%(key, dims%)")

local store = {}
local Deck = {
    newState = function() return { n = 0, shelf = 0, bnd = 0 } end,
    copyState = function(s) return { n = s.n, shelf = s.shelf, bnd = s.bnd } end,
    epoch = function() return 0 end,
}
local env = setmetatable({
    BookshelfWidget = {},
    BookshelfSettings = {
        saveDeferred = function(k, v) store[k] = v end,
        read = function(k) return store[k] end,
    },
    logger = { warn = function() end },
    require = function(n)
        if n == "lib/bookshelf_ornament_deck" then return Deck end
        if n == "lib/bookshelf_ornaments" then return { frequency = function() return 1 end } end
        return require(n)
    end,
}, { __index = _G })
local function compile(code, args)
    local src = "local self" .. args .. " = ...\n" .. code
    if setfenv then local f = assert(loadstring(src)); setfenv(f, env); return f end
    return assert(load(src, "x", "t", env))
end
local startState = compile(START, ", dims")
local remember = compile(REMEMBER, ", key, st, dims")
local saved = compile(SAVED, ", key, dims")

local function shelf(fp)
    local s = { _cursor = 9, builds = 0, fp = fp or "A" }
    s._spine_fetch_cache = { key = "home|", items_sig = "list1", page_orn = {} }
    s._spineSkip = function() return 0 end
    s._ornKey = function(_self, cur, skip) return cur .. ":" .. skip end
    s._ornSig = function() return "session-identity" end
    s._ornFirstState = function() return Deck.newState() end
    s._ornSavedSig = function(self_, key) return self_.fp .. "|" .. key end
    s._spinePageFirsts = function(self_)
        self_.builds = self_.builds + 1
        self_._spine_fetch_cache.page_orn["9:0"] = { n = 7, shelf = 2, bnd = 1 }
    end
    s._ornStartState = function(self_, d) return startState(self_, d) end
    s._ornRemember = function(self_, k, st, d) return remember(self_, k, st, d) end
    s._ornSaved = function(self_, k, d) return saved(self_, k, d) end
    return s
end

t.test("a start on a later page takes the state the last session rendered it with", function()
    store = {}
    local first = shelf()
    local st = first:_ornStartState()
    eq(first.builds, 1)
    eq(st.n, 7)
    assert(store.orn_resume, "the state the page was rendered with was not kept")
    -- A new session: nothing in memory but the settings.
    local again = shelf()
    local st2 = again:_ornStartState()
    eq(again.builds, 0, "every page before it was laid out again")
    eq(st2.n, 7); eq(st2.shelf, 2); eq(st2.bnd, 1)
end)

t.test("anything it rests on changed: laid out as before", function()
    local other = shelf("B")
    other:_ornStartState()
    eq(other.builds, 1, "a state for another deck, list or size was used")
end)

t.test("a page built ahead is not what a start reopens", function()
    assert(REMEMBER:find("if BookshelfWidget._ahead_running then return end", 1, true))
    local cs = body("_pageAheadComposeStep%(job, real%)")
    local a = cs:find("BookshelfWidget._ahead_running = true", 1, true)
    local b = cs:find("BookshelfWidget._ahead_running = nil", 1, true)
    local step = cs:find('require("lib/bookshelf_slice").step(', 1, true)
    assert(a and b and step and a < step and step < b, "the compose ahead is not marked")
end)

t.test("a list's fingerprint names a shelf module by its id, not its table", function()
    -- On a PW3 a module standing among the books put "table: 0x..." in the
    -- list's fingerprint, which no later session matches.
    local SIG = body("_spineItemsSig%(items%)")
    local sigOf
    do
        local src = "local self, items = ...\n" .. SIG
        if setfenv then sigOf = assert(loadstring(src)); setfenv(sigOf, env)
        else sigOf = assert(load(src, "s", "t", env)) end
    end
    local function list() return { { shelf_module = { id = "m7" } }, { filepath = "/b/a.epub" } } end
    local a, b = sigOf({}, list()), sigOf({}, list())
    eq(a, b, "the same list read as another")
    assert(not a:find("table: ", 1, true), a)
    assert(a:find("m7", 1, true))
    local SAVEDSIG = body("_ornSavedSig%(key, dims%)")
    assert(SAVEDSIG:find('c.items_sig:find("table: ", 1, true)', 1, true), "a fingerprint holding an address is kept")
end)

t.test("the fingerprint is by content, and covers what the deal rests on", function()
    local sig = body("_ornSavedSig%(key, dims%)")
    assert(sig:find("return digest(", 1, true), "the whole list's fingerprint goes into the settings file")
    for _i, part in ipairs({ "c.key", "c.items_digest", "Deck.order(", "Deck.levelOf(", "TP.shelfKey",
            "self:_nShelves()", "d.content_w", "d.shelf_h" }) do
        assert(sig:find(part, 1, true), "the fingerprint leaves out " .. part)
    end
    assert(not sig:find("_ornSig", 1, true) and not sig:find("generation", 1, true),
        "the fingerprint uses something that only holds within a session")
end)

t.done()
