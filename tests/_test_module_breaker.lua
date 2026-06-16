-- Circuit-breaker for start-menu micro-modules. A module's render can crash
-- the whole menu (a Lua error in the unguarded getSize/assembly, or a C-level
-- text-shaping segfault no pcall can catch), and because _build runs on every
-- open the user is then locked out and cannot even long-press to remove the
-- offending module (issue #163).
--
-- The breaker persists an "in-flight" marker (the key currently rendering)
-- before each render and clears it after. A Lua error is caught and the marker
-- cleared, so the module is NOT permanently blocked -- it just falls back this
-- session. A hard crash (segfault) never reaches the clear, so the marker
-- survives on disk; the NEXT open promotes that stuck key to a persistent
-- blocklist and skips it, giving the user a removable fallback row.
--
-- The store is injected (read/save/delete) so this logic is unit-testable
-- without KOReader's LuaSettings or any widget infrastructure.
package.path = "./?.lua;./?/init.lua;" .. package.path

local Breaker = dofile("lib/bookshelf_module_breaker.lua")
local helpers = dofile("tests/_helpers.lua")
local t = helpers.runner()

-- In-memory stand-in for lib/bookshelf_settings_store (read/save/delete).
local function fakeStore()
    local data = {}
    return {
        _data = data,
        read = function(key, default)
            local v = data[key]
            if v == nil then return default end
            return v
        end,
        save = function(key, value) data[key] = value end,
        delete = function(key) data[key] = nil end,
    }
end

t.test("a healthy guard runs fn, returns its value, and clears the in-flight marker", function()
    local store = fakeStore()
    local armed_during_fn
    local ok, res = Breaker.guard(store, "clock", function()
        armed_during_fn = Breaker.inflightKey(store)
        return "widget"
    end)
    assert(ok == true, "healthy guard must report success")
    assert(res == "widget", "guard must return fn's result")
    assert(armed_during_fn == "clock",
        "the module key must be armed in-flight WHILE fn runs")
    assert(Breaker.inflightKey(store) == nil,
        "the in-flight marker must be cleared after a successful render")
    assert(Breaker.isBlocked(store, "clock") == false,
        "a module that rendered cleanly must not be blocked")
end)

t.test("a hard crash leaves the marker set; the next open blocks that key", function()
    local store = fakeStore()
    -- Simulate a segfault mid-render: the marker is armed and guard never
    -- returns, so the disarm never runs. We model that by arming directly.
    store.save(Breaker.INFLIGHT_KEY, "trivia")
    -- Next menu open:
    Breaker.beginOpen(store)
    assert(Breaker.isBlocked(store, "trivia") == true,
        "a key still in-flight at open promotes to the persistent blocklist")
    assert(Breaker.inflightKey(store) == nil,
        "beginOpen must clear the stuck in-flight marker after promoting it")
end)

t.test("a blocked module's guard short-circuits and never calls fn", function()
    local store = fakeStore()
    store.save(Breaker.INFLIGHT_KEY, "trivia")
    Breaker.beginOpen(store)
    local called = false
    local ok, res = Breaker.guard(store, "trivia", function()
        called = true
        return "widget"
    end)
    assert(called == false, "a blocked module must not be rendered again")
    assert(ok == false, "guard must report failure for a blocked module")
    assert(res == nil)
end)

t.test("a caught Lua error falls back this session but does NOT persist-block", function()
    local store = fakeStore()
    local ok, res = Breaker.guard(store, "weather", function()
        error("boom in render")
    end)
    assert(ok == false, "a render that throws must report failure")
    assert(Breaker.inflightKey(store) == nil,
        "a caught error must still clear the in-flight marker")
    assert(Breaker.isBlocked(store, "weather") == false,
        "a catchable error is transient; the module must be retried next open")
end)

t.test("retry clears a block so the module renders again", function()
    local store = fakeStore()
    store.save(Breaker.INFLIGHT_KEY, "trivia")
    Breaker.beginOpen(store)
    assert(Breaker.isBlocked(store, "trivia") == true)
    Breaker.retry(store, "trivia")
    assert(Breaker.isBlocked(store, "trivia") == false,
        "retry must remove the key from the blocklist")
    local called = false
    Breaker.guard(store, "trivia", function() called = true end)
    assert(called == true, "after retry the module is rendered again")
end)

t.test("beginOpen is a no-op when nothing was in-flight", function()
    local store = fakeStore()
    Breaker.beginOpen(store)
    assert(Breaker.inflightKey(store) == nil)
    -- A second open after a clean session must not invent blocks.
    Breaker.guard(store, "clock", function() return "w" end)
    Breaker.beginOpen(store)
    assert(Breaker.isBlocked(store, "clock") == false,
        "a cleanly-disarmed module must never be blocked on a later open")
end)

t.done()
