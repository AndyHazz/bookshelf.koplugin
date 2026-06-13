-- Loader/registry behaviour for start-menu modules (micromodules/*.lua
-- spec files). Uses a stub lfs over real temp files so pcall(dofile) is
-- exercised for valid, broken, and invalid-spec modules.
package.path = "./?.lua;./?/init.lua;" .. package.path
package.loaded["logger"] = { dbg = function() end, info = function() end,
                             warn = function() end, err = function() end }
package.loaded["lib/bookshelf_i18n"] = { gettext = function(s) return s end }
package.loaded["ffi/util"] = { template = function(s) return s end }

-- Temp module dir with one file per case.
local tmpdir = "/tmp/bookshelf-modtest-" .. tostring(os.time())
os.execute("mkdir -p '" .. tmpdir .. "'")
local names = {}
local function put(name, body)
    local f = assert(io.open(tmpdir .. "/" .. name, "w"))
    f:write(body)
    f:close()
    names[#names + 1] = name
end
put("good.lua", [[return { key = "good", title = "Good",
    render = function() return nil end }]])
put("broken.lua", "this is not lua (")
put("crashes.lua", [[error("boom at load time")]])
put("no_render.lua", [[return { key = "norender", title = "No render" }]])
put("not_a_table.lua", [[return "just a string"]])
put("dup.lua", [[return { key = "good", title = "Duplicate of good",
    render = function() end }]])
put("bad_settings.lua", [[return { key = "badset", title = "Bad settings",
    render = function() end, show_settings = "not a function" }]])
put("good_settings.lua", [[return { key = "goodset", title = "Good settings",
    render = function() end, show_settings = function() end }]])
put("bad_keepopen.lua", [[return { key = "badkeep", title = "Bad keep_open",
    render = function() end, on_tap = function() end,
    keep_open = "not boolean or function" }]])
put("fn_keepopen.lua", [[return { key = "fnkeep", title = "Function keep_open",
    render = function() end, on_tap = function() end,
    keep_open = function() return true end }]])
names[#names + 1] = "README.md" -- non-lua entries must be ignored
put("README.md", "not a module")

package.loaded["libs/libkoreader-lfs"] = {
    attributes = function(path, what)
        if what == "mode" then
            return path == tmpdir and "directory" or nil
        end
    end,
    dir = function(_d)
        local i = 0
        return function()
            i = i + 1
            return names[i]
        end
    end,
}

local M = dofile("lib/bookshelf_start_menu_modules.lua")
local helpers = dofile("tests/_helpers.lua")
local t = helpers.runner()

t.test("scan registers valid specs and skips broken/invalid ones", function()
    M._test.scanDir(tmpdir)
    local reg = M._test.registry
    assert(reg["good"], "valid spec must register")
    assert(reg["good"].title == "Good")
    assert(reg["norender"] == nil, "spec without render must be skipped")
    assert(reg["good"].title ~= "Duplicate of good", "first key registration wins")
    assert(reg["badset"] == nil,
        "non-function show_settings must be skipped")
    assert(reg["goodset"] ~= nil
        and type(reg["goodset"].show_settings) == "function",
        "function show_settings must register")
    assert(reg["badkeep"] == nil,
        "non-boolean/function keep_open must be skipped")
    assert(reg["fnkeep"] ~= nil
        and type(reg["fnkeep"].keep_open) == "function",
        "function keep_open must register")
    local n = 0
    for _k in pairs(reg) do n = n + 1 end
    assert(n == 3, "exactly three modules must have registered, got " .. n)
end)

t.test("menu-open generation hook", function()
    assert(type(M.menu_generation) == "number",
        "loader must export menu_generation")
    assert(type(M.bumpGeneration) == "function",
        "loader must export bumpGeneration")
    local before = M.menu_generation
    M.bumpGeneration()
    assert(M.menu_generation == before + 1,
        "bumpGeneration must increment menu_generation by 1")
end)

t.test("public API resolves the stored key (back-compat for saved menus)", function()
    -- Stored user menus reference modules by key; "good" stands in for the
    -- shipped "stats" key here. get/title/keys must all resolve it.
    assert(M.get("good") ~= nil)
    assert(M.title("good") == "Good")
    local keys = M.keys()
    assert(#keys >= 1)
    local found = false
    for _i, k in ipairs(keys) do if k == "good" then found = true end end
    assert(found, "keys() must include the registered key")
end)

t.test("every shipped micromodules/*.lua is a valid spec", function()
    -- Stored user menus reference modules by key, so each shipped key is
    -- frozen API: list them here and never change one.
    local expected_keys = {
        ["reading_stats.lua"]  = "stats",
        ["quote_of_day.lua"]   = "quote_of_day",
        ["random_unread.lua"]  = "random_unread",
        ["clock.lua"]          = "clock",
        ["analogue_clock.lua"] = "analogue_clock",
        ["shelf_size.lua"]     = "shelf_size",
        ["reading_goal.lua"]   = "reading_goal",
    }
    local p = io.popen("ls micromodules/*.lua")
    local n = 0
    for path in p:lines() do
        n = n + 1
        local fname = path:match("([^/]+)$")
        local spec = dofile(path)
        assert(type(spec) == "table", fname .. ": must return a spec table")
        assert(type(spec.key) == "string" and spec.key ~= "",
            fname .. ": key must be a non-empty string")
        assert(expected_keys[fname] == spec.key,
            fname .. ": shipped key changed or file not registered in test")
        assert(type(spec.title) == "string" and spec.title ~= "",
            fname .. ": title must be a non-empty string")
        assert(type(spec.render) == "function",
            fname .. ": render must be a function")
        assert(spec.on_tap == nil or type(spec.on_tap) == "function",
            fname .. ": on_tap must be nil or a function")
        assert(spec.keep_open == nil or type(spec.keep_open) == "boolean"
                or type(spec.keep_open) == "function",
            fname .. ": keep_open must be nil, a boolean, or a function")
        assert(not spec.keep_open or spec.on_tap,
            fname .. ": keep_open without on_tap is meaningless")
        assert(spec.show_settings == nil
                or type(spec.show_settings) == "function",
            fname .. ": show_settings must be nil or a function")
    end
    p:close()
    local want = 0
    for _k in pairs(expected_keys) do want = want + 1 end
    assert(n == want, "expected " .. want .. " shipped modules, found " .. n)
end)

t.test("missing directory is a silent no-op", function()
    M._test.scanDir("/tmp/bookshelf-modtest-definitely-missing")
    assert(M._test.registry["good"], "existing registrations must survive")
end)

os.execute("rm -rf '" .. tmpdir .. "'")
t.done()
