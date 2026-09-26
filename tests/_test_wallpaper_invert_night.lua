-- tests/_test_wallpaper_invert_night.lua
-- "Invert wallpaper in night mode" (off by default): the picture shows as its
-- negative whenever the shelf has its night LOOK -- the theme's answer, so a
-- pinned Dark inverts it with KOReader in day mode and a pinned Light keeps it
-- as drawn with KOReader in night mode. preInvert is what the cached buffer
-- holds: the frame's own inversion undone, one more when a negative is wanted.
package.path = "./?.lua;./?/init.lua;" .. package.path
package.loaded["logger"] = { dbg = function() end, info = function() end,
                              warn = function() end, err = function() end }
package.loaded["lib/bookshelf_i18n"] = { gettext = function(s) return s end }
local store = {}
package.loaded["lib/bookshelf_settings_store"] = {
    read = function(k) return store[k] end,
    save = function(k, v) store[k] = v end, delete = function(k) store[k] = nil end,
    isTrue = function(k) return store[k] == true end,
}
local t  = dofile("tests/_helpers.lua").runner()
local eq = dofile("tests/_helpers.lua").eq
package.loaded["lib/bookshelf_wallpaper"] = nil
local W = require("lib/bookshelf_wallpaper")

local function case(on, theme, frame)
    store = { wallpaper_invert_night = on or nil, shelf_theme = theme }
    return W.showsNegative(frame), W.preInvert(frame)
end

t.test("off: the picture looks the same day and night, whatever the theme", function()
    for _i, theme in ipairs({ "auto", "dark", "light" }) do
        for _j, frame in ipairs({ false, true }) do
            local neg, pre = case(false, theme, frame)
            eq(neg, false); eq(pre, frame, "the cache undoes exactly the frame's inversion")
        end
    end
end)

t.test("on, auto theme: a negative in KOReader's night mode only", function()
    local neg, pre = case(true, "auto", false); eq(neg, false); eq(pre, false)
    neg, pre = case(true, "auto", true);        eq(neg, true);  eq(pre, false,
        "the frame does the inverting, so the cache holds the file as drawn")
end)

t.test("on, pinned Dark in day mode: the shelf inverts it itself", function()
    local neg, pre = case(true, "dark", false); eq(neg, true); eq(pre, true)
end)

t.test("on, pinned Light in night mode: as drawn", function()
    local neg, pre = case(true, "light", true); eq(neg, false); eq(pre, true)
end)

t.done()
