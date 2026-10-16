-- tests/_test_chip_focus_refresh.lua
-- ChipBar:focusCursor / focusCrumb refresh the screen only when the focus
-- actually changes. Every page turn clears the d-pad focus, and an unscoped
-- "ui" refresh each time (issue #124 for chips; the breadcrumb twin on a shelf
-- inside a Shelf of shelves, 2026-10-16) repainted the whole screen behind the
-- page wipe, showing on the PW5 as the shelf and footer going white. The real
-- method bodies, extracted by name.
package.path = "./?.lua;./?/init.lua;" .. package.path
local t  = dofile("tests/_helpers.lua").runner()
local eq = dofile("tests/_helpers.lua").eq
local src = io.open("lib/bookshelf_chip_bar.lua"):read("*a")

local dirty = 0
local function compile(name)
    local arg, body = src:match("\nfunction ChipBar:" .. name .. "%(([%w_]*)%)\n(.-)\nend\n")
    assert(body, "ChipBar:" .. name .. " moved")
    local env = setmetatable({ UIManager = { setDirty = function() dirty = dirty + 1 end } }, { __index = _G })
    local code = "local self, " .. arg .. " = ...\n" .. body
    local f
    if _G.setfenv then f = assert(loadstring(code, name)); setfenv(f, env)
    else f = assert(load(code, name, "t", env)) end
    return f
end
local focusCrumb, focusCursor = compile("focusCrumb"), compile("focusCursor")

local function bar()
    return { _breadcrumb_zones = {}, _chip_dimens = {}, show_parent = {}, dimen = { w = 1 },
             _initBreadcrumb = function() end, _buildChipRow = function() end }
end

t.test("clearing a breadcrumb focus that was not set does not refresh", function()
    dirty = 0
    local b = bar()
    focusCrumb(b, nil); focusCrumb(b, nil)
    eq(dirty, 0)
end)

t.test("moving the breadcrumb focus refreshes once per change", function()
    dirty = 0
    local b = bar()
    focusCrumb(b, 2); focusCrumb(b, 2); focusCrumb(b, nil)
    eq(dirty, 2)
end)

t.test("the chip cursor keeps the same rule (issue #124)", function()
    dirty = 0
    local b = bar()
    focusCursor(b, nil); focusCursor(b, "home"); focusCursor(b, "home")
    eq(dirty, 1)
end)

t.done()
