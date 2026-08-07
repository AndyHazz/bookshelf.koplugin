-- tests/_test_pagination.lua
-- Pure-Lua tests for the shared pagination control (lib/bookshelf_pagination),
-- covering the closed "Page X of Y" mode (LibraryModal / collection manager
-- today) and the open-ended "Page X of Y+" mode (an unbounded OPDS feed,
-- where the total is only a lower bound and "last" has no meaningful target).
--
-- bookshelf_pagination only `require`s its widget deps at load (never calls
-- them at module scope), so lightweight stubs are enough to load it
-- standalone. The Button stub captures every constructor call's opts table
-- (text/enabled/callback survive on the same table Button:new returns),
-- which is exactly what buildNav wires into the chevrons and the label.

package.path = "./?.lua;./?/init.lua;" .. package.path

-- Captured Button:new{...} opts tables, in construction order. buildNav
-- builds, in order: chevron.first, chevron.left, the label button,
-- chevron.right, chevron.last -- gap() spans don't touch this stub.
local button_calls = {}
local function reset_buttons()
    for i = #button_calls, 1, -1 do button_calls[i] = nil end
end

package.loaded["ui/widget/button"] = {
    new = function(_, o)
        button_calls[#button_calls + 1] = o
        return o
    end,
}
package.loaded["ui/widget/horizontalgroup"] = {
    new = function(_, o) return o end,
}
package.loaded["ui/widget/horizontalspan"] = {
    new = function(_, o) return o end,
}
package.loaded["device"] = {
    screen = { scaleBySize = function(_, x) return x end },
}
package.loaded["ffi/util"] = {
    -- Real ffi/util.template does %1/%2/... positional substitution; this
    -- covers exactly that, which is all buildNav's label needs.
    template = function(s, ...)
        local args = { ... }
        return (s:gsub("%%(%d+)", function(n)
            return tostring(args[tonumber(n)])
        end))
    end,
}
package.loaded["lib/bookshelf_i18n"] = { gettext = function(s) return s end }

local Pagination = dofile("lib/bookshelf_pagination.lua")

local helpers = dofile("tests/_helpers.lua")
local t = helpers.runner()
local eq = helpers.eq

-- Builds nav and returns { label, first, left, right, last, goto_target }
-- where goto_target is set by invoking a chevron's callback (the stub
-- records the same opts table Button:new was given, so callback closes
-- over on_goto and `target` from buildNav directly).
local function build(opts)
    reset_buttons()
    local goto_target
    opts.on_goto = function(target) goto_target = target end
    Pagination.buildNav(opts)
    assert(#button_calls == 5, "expected 5 Button:new calls, got " .. #button_calls)
    return {
        first = button_calls[1],
        left  = button_calls[2],
        label = button_calls[3],
        right = button_calls[4],
        last  = button_calls[5],
        goto_target = function() return goto_target end,
    }
end

-- Closed mode: existing behaviour must stay intact.
t.test("closed mode: label reads 'Page X of Y'", function()
    local nav = build{ page = 2, total_pages = 5 }
    eq(nav.label.text, "Page 2 of 5")
end)

t.test("closed mode: last chevron enabled, targets total_pages", function()
    local nav = build{ page = 2, total_pages = 5 }
    assert(nav.last.enabled == true, "last chevron should be enabled when page < total_pages")
    nav.last.callback()
    eq(nav.goto_target(), 5)
end)

-- Open-ended mode: total_pages is a lower bound, not a real end.
t.test("open-ended: label reads 'Page X of Y+'", function()
    local nav = build{ page = 3, total_pages = 12, open_ended = true }
    eq(nav.label.text, "Page 3 of 12+")
end)

t.test("open-ended: last chevron is disabled even though page < total_pages", function()
    local nav = build{ page = 3, total_pages = 12, open_ended = true }
    assert(nav.last.enabled == false, "last chevron must be disabled in open-ended mode")
    nav.last.callback()  -- disabled callback must be inert
    eq(nav.goto_target(), nil)
end)

t.test("open-ended: next chevron stays enabled at page == total_pages, targets page+1", function()
    local nav = build{ page = 12, total_pages = 12, open_ended = true }
    assert(nav.right.enabled == true, "next chevron should stay enabled -- there is more feed to fetch")
    nav.right.callback()
    eq(nav.goto_target(), 13)
end)

t.done()
