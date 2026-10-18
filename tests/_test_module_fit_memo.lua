-- tests/_test_module_fit_memo.lua
-- The micro-module grid searches for each card's size by rendering it again
-- and again (on a PW5, 7 full-screen cards rendered 10 to 12 times each, most
-- of a 0.5s open). The fitted size is now remembered per card and layout, and
-- kept across restarts: an unchanged card renders once. Anything that changes
-- what it draws changes its size, which sends it back to the search.
-- Run from the plugin root: lua tests/_test_module_fit_memo.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local t = dofile("tests/_helpers.lua").runner()
local src = io.open("lib/bookshelf_hero_modules.lua"):read("*a")

-- From the fit constants through the end of _renderFitted: the memo helpers
-- and the search, with their upvalues turned into stubbable globals.
local from = src:find("local FIT_MAX_ITERS", 1, true)
local fn_at = src:find("local function _renderFitted", 1, true)
local to = select(2, src:find("\n    return result\nend\n", fn_at, true))
assert(from and fn_at and to, "the fit engine moved")
local chunk_src = src:sub(from, to) .. "\nreturn _renderFitted\n"

local store = {}
local function load_fit()
    local HM = {}
    local env = setmetatable({
        HeroModules = HM,
        BookshelfSettings = {
            read = function(k) return store[k] end,
            save = function(k, v) store[k] = v end,
        },
        require = function(name)
            if name == "lib/bookshelf_module_kit" then
                return { shape = function() return "wide" end,
                         entryConfig = function() return nil end }
            end
            return require(name)
        end,
    }, { __index = _G })
    local chunk = assert((loadstring or load)(chunk_src, "fit", "t", env))
    if setfenv then setfenv(chunk, env) end
    return chunk(), HM
end

-- A text card: `lines` lines at `scale`% are lines * scale/10 px tall, and it
-- fills the width. With clamp it truncates itself to the cell height.
local function card(lines_ref)
    local def = { key = "fake", renders = 0 }
    def.render = function(ctx)
        def.renders = def.renders + 1
        local h = math.floor(lines_ref.n * ctx.scale / 10)
        if ctx.clamp then h = math.min(h, ctx.height) end
        def.last_clamp = ctx.clamp
        return { getSize = function() return { w = ctx.width, h = h } end }
    end
    return def
end

local entry = { id = "fsm9" }

t.test("an unchanged card renders once on the next open", function()
    local fit = load_fit()
    local lines = { n = 3 }
    local def = card(lines)
    local w1 = fit(def, 200, 100, 100, nil, entry, 100, nil)
    local searched = def.renders
    assert(searched > 1, "the first open should search, rendered " .. searched)
    def.renders = 0
    local w2 = fit(def, 200, 100, 100, nil, entry, 100, nil)
    assert(def.renders == 1, "rendered " .. def.renders .. " times, expected once")
    assert(w2:getSize().h == w1:getSize().h, "the remembered size differs from the searched one")
end)

t.test("a card whose content changed is searched again and fits", function()
    local fit = load_fit()
    local lines = { n = 3 }
    local def = card(lines)
    fit(def, 200, 100, 100, nil, entry, 100, nil)
    lines.n = 5   -- a longer quote
    def.renders = 0
    local w = fit(def, 200, 100, 100, nil, entry, 100, nil)
    assert(def.renders > 1, "a changed card was not searched again")
    assert(w:getSize().h <= 100, "the new content overflows: " .. w:getSize().h)
end)

t.test("a different cell is a different entry", function()
    local fit = load_fit()
    local def = card({ n = 3 })
    fit(def, 200, 100, 100, nil, entry, 100, nil)
    def.renders = 0
    fit(def, 200, 140, 100, nil, entry, 100, nil)
    assert(def.renders > 1, "a taller cell reused the old size")
end)

t.test("the sizes survive a restart", function()
    local fit = load_fit()
    local def = card({ n = 3 })
    fit(def, 180, 90, 100, nil, entry, 100, nil)
    assert(store.module_fit_memo, "nothing was saved")
    local fit2, HM2 = load_fit()      -- a fresh process: nothing in memory
    HM2._resetFitMemo()
    def.renders = 0
    fit2(def, 180, 90, 100, nil, entry, 100, nil)
    assert(def.renders == 1, "after a restart it rendered " .. def.renders .. " times")
end)

t.test("a card that needed the clamp is rendered clamped from memory", function()
    local fit = load_fit()
    local def = card({ n = 40 })   -- too tall even at the legibility floor
    fit(def, 200, 100, 100, nil, entry, 100, nil)
    assert(def.last_clamp, "the search did not end on a clamped render")
    def.renders, def.last_clamp = 0, nil
    local w = fit(def, 200, 100, 100, nil, entry, 100, nil)
    assert(def.renders == 1 and def.last_clamp, "the remembered render was not clamped")
    assert(w:getSize().h <= 100)
end)

t.test("a card with no id is never remembered", function()
    local fit = load_fit()
    local def = card({ n = 3 })
    fit(def, 160, 80, 100, nil, nil, 100, nil)
    def.renders = 0
    fit(def, 160, 80, 100, nil, nil, 100, nil)
    assert(def.renders > 1, "an id-less card should search every time")
end)

t.done()
