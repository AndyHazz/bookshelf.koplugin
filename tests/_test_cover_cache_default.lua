-- tests/_test_cover_cache_default.lua
-- The cover cache's default RAM budget follows the device's memory.
--
-- WHAT NEEDS PINNING. 24 MB holds a 300 dpi greyscale shelf's whole working
-- set (PW5, 2026-09-16: 211 covers, zero evictions), but colour panels store
-- covers at four bytes a pixel, so the same budget holds about fifty and
-- churns, re-decoding covers it just evicted. Devices with a gigabyte or more
-- have the headroom; 512 MB Kindles and Kobos do not. So the default is 24 MB
-- below 1 GiB of total memory and 48 MB from 1 GiB up, the user's own setting
-- always wins, and every place that used to print or apply a literal 24 asks
-- the cache module instead.
--
-- Usage (from plugin root): lua tests/_test_cover_cache_default.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local helpers = dofile("tests/_helpers.lua")
local t  = helpers.runner()
local eq = helpers.eq

package.loaded["logger"] = { dbg = function() end, info = function() end, warn = function() end, err = function() end }
local SCC = dofile("lib/bookshelf_scaled_cover_cache.lua")
local GiB = 1024 * 1024 * 1024

t.test("below one gigabyte the default is 24 MB; from one gigabyte it is 48", function()
    eq(SCC.defaultBudgetMB(485604 * 1024), 24, "PW5, 485 MB")
    eq(SCC.defaultBudgetMB(512 * 1024 * 1024), 24, "512 MB Kobo")
    eq(SCC.defaultBudgetMB(GiB - 1024), 24, "just under")
    eq(SCC.defaultBudgetMB(GiB), 48, "exactly one gigabyte")
    eq(SCC.defaultBudgetMB(2 * GiB), 48, "2 GB Boox")
end)

t.test("an unknown total keeps the conservative default", function()
    eq(SCC.defaultBudgetMB(nil), 24)
    eq(SCC.defaultBudgetMB(0), 24)
    eq(SCC.defaultBudgetMB("lots"), 24)
end)

t.test("the device default reads total memory through KOReader's helper and never throws", function()
    package.loaded["util"] = { calcFreeMem = function() return 100 * 1024 * 1024, 2 * GiB end }
    eq(SCC.deviceDefaultBudgetMB(), 48)
    package.loaded["util"] = { calcFreeMem = function() return nil, nil end }
    eq(SCC.deviceDefaultBudgetMB(), 24)
    package.loaded["util"] = { calcFreeMem = function() error("no meminfo") end }
    eq(SCC.deviceDefaultBudgetMB(), 24)
    package.loaded["util"] = nil
end)

t.test("the widget and the settings rows take the default from the cache module, no literal 24", function()
    local widget = io.open("lib/bookshelf_widget.lua"):read("*a")
    assert(widget:find("deviceDefaultBudgetMB()", 1, true), "widget must ask the cache for its default")
    assert(not widget:find("\nlocal COVER_CACHE_DEFAULT_MB", 1, true), "the widget's own constant should go")
    local settings = io.open("lib/bookshelf_settings.lua"):read("*a")
    assert(not settings:find('read("cover_cache_mb") or 24', 1, true), "settings row still defaults to a literal 24")
    assert(not settings:find("default_value = 24", 1, true), "spin widget still defaults to a literal 24")
    assert(not settings:find("Default 24 MB", 1, true), "help text still names 24 MB")
    local n = select(2, settings:gsub("deviceDefaultBudgetMB%(%)", ""))
    assert(n >= 2, "expected the settings module to ask the cache module at least twice, found " .. n)
end)

t.done()
