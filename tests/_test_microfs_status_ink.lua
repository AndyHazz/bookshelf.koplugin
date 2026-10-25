-- tests/_test_microfs_status_ink.lua
-- The full-screen module view's status line is drawn in ink that reads on
-- the view's own ground. Opened from a book, the view has no wallpaper and
-- stands on plain white, while a dark theme's ink is white: the line was
-- there but invisible (maintainer, PW5). On the white fallback the line is
-- built with black ink; HeroCard.buildStatusRow takes the ink to use.
--
-- Usage (from plugin root): lua tests/_test_microfs_status_ink.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local t  = dofile("tests/_helpers.lua").runner()
local eq = dofile("tests/_helpers.lua").eq

local mf = io.open("lib/bookshelf_micro_fullscreen.lua"):read("*a")
local hc = io.open("lib/bookshelf_hero_card.lua"):read("*a")

t.test("the minute refresh rebuilds the line in the view's ink", function()
    local body = mf:match("\n(function MicroFullscreen:refreshStatus%(.-\nend)\n")
    assert(body, "refreshStatus moved")
    local got
    local env = setmetatable({
        MicroFullscreen = {},
        UIManager = { setDirty = function() end, nextTick = function() end },
        require = function(name)
            if name == "lib/bookshelf_hero_card" then
                return { buildStatusRow = function(_b, _s, _w, _h, _j, ink) got = ink; return {} end }
            end
            return require(name)
        end,
    }, { __index = _G })
    assert(load(body, "refreshStatus", "t", env))()
    local v = setmetatable({ _status_ink = "BLACK", _status_rec = { group = { {} }, idx = 1, content_w = 10 },
                             bw = {} }, { __index = env.MicroFullscreen })
    assert(v:refreshStatus())
    eq(got, "BLACK", "the refresh went back to the theme's ink")
end)

t.test("on the white fallback ground the view asks for black ink", function()
    assert(mf:find("self._status_ink = (not wall) and Blitbuffer.COLOR_BLACK or nil", 1, true),
        "the ink does not follow the ground")
    assert(mf:find("HeroCard.buildStatusRow, current, state, content_w, true, nil, self._status_ink", 1, true),
        "the first build ignores the ink")
    -- The ground is decided before the line is built.
    local ground_at = mf:find("local wall", 1, true)
    local build_at  = mf:find("HeroCard.buildStatusRow, current, state, content_w", 1, true)
    assert(ground_at and build_at and ground_at < build_at, "the line is built before its ground is known")
end)

t.test("buildStatusRow's ink is the one every text in the row takes", function()
    assert(hc:find("function HeroCard.buildStatusRow(book, state, width, with_hairline, allow_job, ink)", 1, true))
    assert(hc:find('if type(_ink_override) ~= "nil" then return _ink_override end', 1, true), "_ink ignores the override")
    -- A Blitbuffer colour raises on a compare with nil (Color8 __eq): the
    -- override is never compared, only typed.
    local body = hc:match("\nfunction HeroCard%.buildStatusRow%(.-\nend\n")
    assert(body and not body:find("ink == nil", 1, true) and not body:find("ink ~= nil", 1, true), "compares the colour with nil")
end)

t.done()
