-- tests/_test_theme_sort.lua
-- The Theme library sorts its cards A-Z, newest pack first, or the theme
-- chosen most recently first (maintainer: a sort switch on the theme list).
-- Default theme and a missing pack stay at the top whatever the order; Custom
-- theme and Plain stay at the top of A-Z and Newest (they are not added), and
-- take their place by use in Last used.
-- Usage (from plugin root): lua tests/_test_theme_sort.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
package.loaded["logger"] = { dbg = function() end, info = function() end,
                             warn = function() end, err = function() end }
package.loaded["lib/bookshelf_i18n"] = { gettext = function(s) return s end }
local H = dofile("tests/_helpers.lua")
local t, eq = H.runner(), H.eq

local TL = dofile("lib/bookshelf_theme_library.lua")
TL._tp = { MINE = "mine", PLAIN = "plain" }

local function cards()
    return {
        { same = true, title = "Default theme" },
        { value = "Gone", missing = true, title = "Gone (missing)" },
        { value = "mine", title = "Custom theme" },
        { value = "plain", title = "Plain" },
        { value = "Autumn", title = "Autumn" },
        { value = "Macabre", title = "Macabre" },
        { value = "Ukiyo", title = "Ukiyo-e" },
    }
end
local function titles(items)
    local o = {}
    for _i, it in ipairs(items) do o[#o + 1] = it.title end
    return table.concat(o, ", ")
end
local added = { Ukiyo = 300, Autumn = 100, Macabre = 200 }
local used = { plain = 50, Autumn = 70, mine = 10 }
local when = {
    added = function(it) return added[it.value] end,
    used  = function(it) return used[it.value] end,
}

t.test("the switch: A-Z, Newest, Last used", function()
    local o = {}
    for _i, it in ipairs(TL.orders()) do o[#o + 1] = it.key .. "=" .. it.label end
    eq(table.concat(o, " "), "az=A-Z added=Newest used=Last used")
end)

t.test("A-Z: the list as the theme scan sorts it, built-ins first", function()
    eq(titles(TL.order(cards(), "az", when)),
       "Default theme, Gone (missing), Custom theme, Plain, Autumn, Macabre, Ukiyo-e")
end)

t.test("Newest: the packs most recently added first", function()
    eq(titles(TL.order(cards(), "added", when)),
       "Default theme, Gone (missing), Custom theme, Plain, Ukiyo-e, Macabre, Autumn")
end)

t.test("Last used: the theme chosen last first, built-ins among them; never chosen after, in A-Z order", function()
    eq(titles(TL.order(cards(), "used", when)),
       "Default theme, Gone (missing), Autumn, Plain, Custom theme, Macabre, Ukiyo-e")
end)

t.test("the cards are not reordered in place", function()
    local c = cards()
    TL.order(c, "added", when)
    eq(c[5].title, "Autumn")
end)

-- Last used is a time per choice, written with the other theme settings
-- (deferred while the picker is open).
t.test("a choice's use is kept, and read back", function()
    local saved = {}
    local TP = dofile("lib/bookshelf_theme_pack.lua")
    TP._store = { read = function(k) return saved[k] end,
                  save = function(k, v) saved[k] = v end }
    TP._now = function() return 1234 end
    TP.markUsed("Autumn")
    TP.markUsed("plain")
    TP.markUsed(nil)   -- Default theme: it stands for another
    eq(TP.usedAt("Autumn"), 1234)
    eq(TP.usedAt("plain"), 1234)
    eq(TP.usedAt("Macabre"), nil)
    local n = 0
    for _k in pairs(saved[TP.USED_SETTING]) do n = n + 1 end
    eq(n, 2)
end)

t.test("a pack's added time is its folder's", function()
    local TP = dofile("lib/bookshelf_theme_pack.lua")
    TP._orn = { packDir = function(p) return p == "Autumn" and "/orn/Autumn" or nil end }
    TP._lfs = { attributes = function(path, what)
        if path == "/orn/Autumn" and what == "modification" then return 777 end
    end }
    eq(TP.addedAt("Autumn"), 777)
    eq(TP.addedAt("mine"), nil)
    eq(TP.addedAt("Gone"), nil)
end)

t.test("the picker offers the switch and keeps the order for the session", function()
    local src = io.open("lib/bookshelf_theme_library.lua"):read("*a")
    local i = src:find("function TL.show", 1, true)
    local body = src:sub(i)
    assert(body:find("chip_strip", 1, true), "no switch")
    assert(body:find("TL._order", 1, true), "the order is not kept")
    assert(body:find("markUsed", 1, true), "a choice is not recorded")
    -- Choosing Plain, then Last used: Plain comes first (rig).
    local tap = body:sub((body:find("on_chip_tap = function(key)", 1, true)))
    assert(tap:find("^on_chip_tap = function%(key%)%s+TL._order = key%s+load%(true%)"),
        "the switch orders by the times as the picker opened")
end)

-- A small screen: the strip wraps to two rows, and four cards ran the page
-- row off the bottom (600x800 rig). Fewer cards a page, not shorter ones.
t.test("fewer cards a page when four do not fit the room", function()
    TL.cardHeight = function() return 100 end
    package.loaded["lib/bookshelf_space"] = { px = function() return 10 end }
    eq(TL.areaHeight(500, nil), 430); eq(TL.perPage(), 4)
    eq(TL.areaHeight(500, 1000), 430); eq(TL.perPage(), 4)
    -- Fewer cards share the room: no empty band under them.
    eq(TL.areaHeight(500, 400), 400); eq(TL.perPage(), 3)
    eq(TL.areaHeight(500, 50), 210); eq(TL.perPage(), 2)
    local lm = io.open("lib/bookshelf_library_modal.lua"):read("*a")
    assert(lm:find("self.config.area_height(cw, room)", 1, true), "the modal does not say how much room")
end)

t.done()
