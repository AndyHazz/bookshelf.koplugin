-- tests/_test_module_min_widths.lua
-- Text micro-modules can't be read one grid column wide (about 160px on a
-- PW5's full-screen grid): they truncate to "N..." or break words across
-- lines. They declare min_w = 2 so the layout editor never sizes them below
-- that and new ones start at least that wide.
package.path = "./?.lua;./?/init.lua;" .. package.path
package.loaded["lib/bookshelf_i18n"] = { gettext = function(s) return s end }
package.loaded["ffi/util"] = { template = function(s) return s end }
package.loaded["logger"] = { dbg = function() end, info = function() end,
    warn = function() end, err = function() end }

local t = dofile("tests/_helpers.lua").runner()

local TEXT_MODULES = {
    "clock", "countdown", "daily_fun", "on_this_day", "quote_of_day",
    "reading_goal", "reading_stats", "reading_streak", "shelf_size",
    "trivia", "weather",
}

for _i, name in ipairs(TEXT_MODULES) do
    t.test(name .. " is at least two columns wide", function()
        local ok, spec = pcall(dofile, "micromodules/" .. name .. ".lua")
        assert(ok, "could not load: " .. tostring(spec))
        assert(type(spec.min_w) == "number" and spec.min_w >= 2,
            "min_w = " .. tostring(spec.min_w))
    end)
end

t.done()
