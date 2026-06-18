-- Open-crash breaker for the start menu.
--
-- Two responsibilities, both cheap:
--   * guard(fn): run a module render under pcall so a Lua error degrades to a
--     fallback row instead of taking down the whole build. NO disk writes -
--     this is the hot path (once per module per open) and flushing bookshelf.lua
--     here was the dominant cost of opening the menu on e-ink.
--   * armOpen/endOpen/openCrashed: a single persisted "open in progress" marker.
--     Armed before the menu is shown, cleared after the first paint. If still
--     set at the next open, the previous open crashed before painting (a paint
--     segfault, or a render hard-crash that safeText didn't prevent) -> open in
--     safe mode. This is the recovery layer; safeText is the prevention layer.
--
-- The store is injected (read/save/delete) so this is unit-testable without
-- KOReader's LuaSettings.
package.path = "./?.lua;./?/init.lua;" .. package.path

local Breaker = dofile("lib/bookshelf_module_breaker.lua")
local helpers = dofile("tests/_helpers.lua")
local t = helpers.runner()

-- In-memory store that counts writes, so we can assert guard() touches no disk.
local function fakeStore()
    local data = {}
    local writes = 0
    return {
        _data = data,
        writes = function() return writes end,
        read = function(key, default)
            local v = data[key]
            if v == nil then return default end
            return v
        end,
        save = function(key, value) data[key] = value; writes = writes + 1 end,
        delete = function(key) data[key] = nil; writes = writes + 1 end,
    }
end

t.test("guard runs fn and returns its value", function()
    local ok, res = Breaker.guard(function() return "widget" end)
    assert(ok == true and res == "widget")
end)

t.test("guard catches a Lua error and reports failure", function()
    local ok, err = Breaker.guard(function() error("boom") end)
    assert(ok == false, "a thrown render must report failure")
    assert(tostring(err):find("boom"), "the error should be returned")
end)

t.test("guard performs NO store writes (hot path stays off disk)", function()
    local store = fakeStore()
    Breaker.guard(function() return "w" end)
    Breaker.guard(function() error("x") end)
    assert(store.writes() == 0,
        "guard must not flush settings; got " .. store.writes() .. " writes")
end)

t.test("a clean open arms then ends; nothing looks crashed", function()
    local store = fakeStore()
    Breaker.armOpen(store)
    assert(Breaker.openCrashed(store) == true,
        "while armed and not ended, an open is in-flight")
    Breaker.endOpen(store)
    assert(Breaker.openCrashed(store) == false,
        "a completed paint clears the open marker")
end)

t.test("an open that armed but never ended is detected as crashed", function()
    local store = fakeStore()
    Breaker.armOpen(store)
    -- ...paint segfaults before endOpen. Next open sees the stuck marker:
    assert(Breaker.openCrashed(store) == true)
end)

t.test("openCrashed is false on a fresh store", function()
    assert(Breaker.openCrashed(fakeStore()) == false)
end)

t.test("open lifecycle costs exactly two writes (arm + end)", function()
    local store = fakeStore()
    Breaker.armOpen(store)
    Breaker.endOpen(store)
    assert(store.writes() == 2,
        "one arm + one clear per open; got " .. store.writes())
end)

-- File-marker variant for the home-screen hero (lib/bookshelf_widget). The hero
-- repaints far more often than the menu opens, so its marker is a 0-byte
-- sentinel FILE (a directory-entry write) rather than a settings-store flush.
-- Same arm/clear/crashed semantics, exercised against a real temp path.
local HERO_MARK = os.tmpname()
os.remove(HERO_MARK) -- tmpname creates the file; start from "not armed"

t.test("fileCrashed is false before arming", function()
    assert(Breaker.fileCrashed(HERO_MARK) == false)
end)

t.test("a clean hero paint arms then ends; nothing looks crashed", function()
    Breaker.armFile(HERO_MARK)
    assert(Breaker.fileCrashed(HERO_MARK) == true,
        "while armed and not ended, a hero paint is in-flight")
    Breaker.endFile(HERO_MARK)
    assert(Breaker.fileCrashed(HERO_MARK) == false,
        "a survived paint clears the sentinel")
end)

t.test("an armed-but-never-ended hero paint is detected as crashed", function()
    Breaker.armFile(HERO_MARK)
    -- ...paint segfaults before endFile. Next launch sees the stuck sentinel:
    assert(Breaker.fileCrashed(HERO_MARK) == true)
    Breaker.endFile(HERO_MARK) -- cleanup
end)

t.test("file-marker calls tolerate a nil path (DataStorage unavailable)", function()
    -- heroMarkerPath returns nil under the standalone runner; the helpers must
    -- no-op rather than error so the widget's pcall-wrapped calls stay quiet.
    Breaker.armFile(nil)
    Breaker.endFile(nil)
    assert(Breaker.fileCrashed(nil) == false)
end)

t.done()
