-- tests/_test_footer_step.lua
-- Footer chevron taps arm the same wipe + preload the swipe path arms.
--
-- THE ARTIFACT. step() used to call _swapShelvesInPlace() bare: no
-- _wipe_dir, so the turn fell through to the non-wipe branch (which also
-- split the refresh into two disjoint rects), and no _schedulePreload, so
-- the next page's covers stayed cold on every chevron tap. Swipe and
-- hardware-key turns already armed both in _paginateNext/_paginatePrev.
--
-- Driven against the real method body, extracted by name and run under a
-- stub self (the same trick as _test_preload_arming).
package.path = "./?.lua;./?/init.lua;" .. package.path

local t   = dofile("tests/_helpers.lua").runner()
local src = io.open("lib/bookshelf_widget.lua"):read("*a")

local body = src:match("\nfunction BookshelfWidget:_footerStep%(direction%)\n(.-)\nend\n")
assert(body, "could not find BookshelfWidget:_footerStep - renamed?")

local function compile(code, env, name)
    if _G.setfenv then
        local f = assert(_G.loadstring(code, name))
        _G.setfenv(f, env)
        return f
    end
    return assert(load(code, name, "t", env))
end

local function harness()
    local log = {}
    local self_ = {
        _markOpdsNav       = function() log[#log + 1] = "opds" end,
        _advanceCursor     = function(s, d) log[#log + 1] = "adv:" .. d end,
        _syncPageFromCursor = function() log[#log + 1] = "sync" end,
        _swapShelvesInPlace = function(s)
            -- Consume _wipe_dir the way the real swap does, and record
            -- what was armed at the moment of the turn.
            log[#log + 1] = "swap:wipe=" .. tostring(s._wipe_dir)
            s._wipe_dir = nil
        end,
        _schedulePreload   = function(s, d) log[#log + 1] = "preload:" .. d end,
    }
    local env = { tostring = tostring }
    env._G = env
    local fn = compile("local self, direction = ...\n" .. body, env, "_footerStep")
    return self_, log, function(dir) fn(self_, dir) end
end

t.test("forward step arms wipe +1 and preloads forward", function()
    local _s, log, step = harness()
    step(1)
    local joined = table.concat(log, " ")
    assert(joined:find("adv:1", 1, true), "cursor did not advance: " .. joined)
    assert(joined:find("swap:wipe=1", 1, true),
        "_swapShelvesInPlace ran without wipe direction +1: " .. joined)
    assert(joined:find("preload:1", 1, true),
        "next-page covers were not preloaded: " .. joined)
end)

t.test("backward step arms wipe -1 and preloads backward", function()
    local _s, log, step = harness()
    step(-1)
    local joined = table.concat(log, " ")
    assert(joined:find("adv:-1", 1, true), "cursor did not step back: " .. joined)
    assert(joined:find("swap:wipe=-1", 1, true),
        "_swapShelvesInPlace ran without wipe direction -1: " .. joined)
    assert(joined:find("preload:-1", 1, true),
        "prev-page covers were not preloaded: " .. joined)
end)

t.test("wipe is armed before the swap and consumed by it", function()
    local self_, log, step = harness()
    step(1)
    -- Order matters: wipe must be set before _swapShelvesInPlace reads it.
    local i_swap, i_preload
    for i, entry in ipairs(log) do
        if entry:find("swap:", 1, true) then i_swap = i end
        if entry:find("preload:", 1, true) then i_preload = i end
    end
    assert(i_swap and i_preload and i_swap < i_preload,
        "preload must run after the swap (table.concat order): " .. table.concat(log, " "))
    assert(self_._wipe_dir == nil, "wipe direction was not consumed by the swap")
end)

t.test("source: step() delegates to _footerStep", function()
    -- The nested step() closure in _buildPaginationFooter must not grow
    -- its own bare _swapShelvesInPlace again.
    local footer = src:match("local function step%(direction%)\n(.-)\n    end\n")
    assert(footer, "could not find nested step() in _buildPaginationFooter")
    assert(footer:find("_footerStep", 1, true),
        "step() no longer delegates to _footerStep")
    assert(not footer:find("_swapShelvesInPlace", 1, true),
        "step() calls _swapShelvesInPlace directly again (bypasses wipe/preload)")
end)

t.done()
