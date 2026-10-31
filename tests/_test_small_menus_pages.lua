-- tests/_test_small_menus_pages.lua
-- Small menus as pages (STYLE.md): an OPDS folder's long-press and the
-- Modules chip's long-press. No greyed button used as a label, no Cancel
-- row (the X), each action a card saying what it does.
--
-- Usage (from plugin root): lua tests/_test_small_menus_pages.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local H = dofile("tests/_helpers.lua")
local t, eq = H.runner(), H.eq

local src = io.open("lib/bookshelf_widget.lua"):read("*a")
local function method(name)
    local b = src:match("\n(function BookshelfWidget:" .. name .. "%(.-\nend)\n")
    assert(b, name .. " moved")
    return b
end

local function run(name, bw_fields, args, extra_env)
    local state = {}
    local env = setmetatable({
        BookshelfWidget = {},
        _ = function(s) return s end,
        T = function(s, a) return (s:gsub("%%1", tostring(a))) end,
        UIManager = { close = function() state.closed = (state.closed or 0) + 1 end,
                      setDirty = function() end, show = function() end },
        BookshelfSettings = { save = function() end, delete = function() end, flush = function() end,
            microInStartMenu = function() return false end, microFullscreenButton = function() return false end },
        require = function(n)
            if n == "lib/bookshelf_page_dialog" then
                return { show = function(spec) state.spec = spec; return {} end }
            end
            if n == "ui/widget/buttondialog" then error("still a ButtonDialog") end
            if n == "lib/bookshelf_tab_model" then
                return { getById = function() return { source = { kind = "opds" } } end }
            end
            if n == "lib/bookshelf_hero_modules_model" then
                return { save = function() state.reset = true end, DEFAULTS = function() return {} end }
            end
            return require(n)
        end,
    }, { __index = _G })
    for k, v in pairs(extra_env or {}) do env[k] = v end
    assert(load(method(name), name, "t", env))()
    local bw = setmetatable(bw_fields, { __index = env.BookshelfWidget })
    bw[name](bw, (table.unpack or unpack)(args or {}))
    return state
end

local function options(spec)
    local out = {}
    for _i, b in ipairs(spec.page().blocks) do
        if b.type == "option" then out[#out + 1] = b end
    end
    return out
end

local rec = { label = "Fiction", opds = { feed_url = "u/fiction" } }

t.test("OPDS folder: start here, as a card that says what it does", function()
    local st = run("_openOpdsNavMenu", { _opdsStartFeed = function() return nil end,
        _setOpdsStartFeed = function() end }, { rec })
    eq(st.spec.title, "Fiction")
    local o = options(st.spec)
    eq(#o, 1)
    assert(o[1].desc and #o[1].desc > 0, "no line saying what it does")
    eq(st.spec.footer, nil)
end)

t.test("OPDS folder already the start: said in the strip, Back to the top offered", function()
    local st = run("_openOpdsNavMenu", { _opdsStartFeed = function() return "u/fiction", "Fiction" end,
        _setOpdsStartFeed = function() end }, { rec })
    local m = st.spec.page()
    assert(m.strip[1].text:find("Fiction", 1, true), "the strip does not say where it starts")
    local o = options(st.spec)
    eq(#o, 1)
    assert(o[1].text:find("top", 1, true), "no way back to the top")
end)

t.test("Modules: Reset and Remove as cards, the X to leave", function()
    local st = run("_showModulesOptions", { _rebuildRefreshHeroAndChips = function() end,
        _rebuild = function() end }, {})
    local o = options(st.spec)
    eq(#o, 2)
    for _i, b in ipairs(o) do assert(b.icon and b.desc, "a card without icon or line") end
    o[1].callback()
    eq(st.reset, true)
end)

-- Perf review 2026-10-31: an anchored page repainted every window under it
-- (the whole shelf behind a size page) on every tap, moved or not.
t.test("an anchored page repaints underneath only when its anchor moved", function()
    local pd = io.open("lib/bookshelf_page_dialog.lua"):read("*a")
    local r = pd:match("\n(function PageDialog:refresh%(%).-\nend)\n")
    assert(r and not r:find("or self.anchor) then", 1, true), "every tap of an anchored page repaints the shelf")
    assert(r:find("a.x ~= seen.x or a.y ~= seen.y or a.h ~= seen.h", 1, true), "a moved anchor is not seen")
end)

t.done()
