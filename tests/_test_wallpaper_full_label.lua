-- tests/_test_wallpaper_full_label.lua
-- "Full screen shelves image" has three states: unset (Same as default),
-- false (None) and a picture. The row showed None as "Same as default" (it
-- treated every non-string as unset), so a reader who had picked None, and
-- then a pack theme, read "Same as default" and got no picture in full
-- screen: black on a dark shelf (PW5, Halloween, 2026-10-02). In v5.2.3 too.
-- Usage (from plugin root): lua tests/_test_wallpaper_full_label.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local H = dofile("tests/_helpers.lua")
local t, eq = H.runner(), H.eq
local src = io.open("lib/bookshelf_settings.lua"):read("*a")
local body = src:match("\n(    local function wallpaperLabel%(setting, fallback%)\n.-\n    end)\n")
assert(body, "wallpaperLabel moved")

local function label(store, setting, fallback)
    local env = setmetatable({
        _ = function(s) return s end,
        T = function(f, ...) local a = { ... }; return (f:gsub("%%(%d)", function(i) return tostring(a[tonumber(i)]) end)) end,
        BookshelfSettings = { read = function(k) return store[k] end },
        Wallpaper = { FULL_SETTING = "wallpaper_full", SETTING = "wallpaper_default",
                      pathFor = function(n) return "/w/" .. n end },
        require = function(m)
            if m == "lib/bookshelf_theme_pack" then
                -- The editing seam: the reader's own keys (a My theme shelf).
                return { isPackName = function(n) return type(n) == "string" and n:sub(1, 11) == "theme-pack\1" end,
                         variantName = function(n) return n end,
                         partRead = function(k) return store[k] end,
                         partEdited = function() return false end }
            end
            return require(m)
        end,
    }, { __index = _G })
    local chunk = assert((loadstring or load)(body .. "\nreturn wallpaperLabel", "=label", "t", env))
    if setfenv then setfenv(chunk, env) end
    return chunk()(setting, fallback)
end

t.test("full screen None reads None, not Same as default", function()
    eq(label({ wallpaper_full = false }, "wallpaper_full", "Same as default"), "None")
end)

t.test("full screen unset reads Same as default", function()
    eq(label({}, "wallpaper_full", "Same as default"), "Same as default")
end)

t.test("a picture reads its name, a pack's its pack", function()
    eq(label({ wallpaper_full = "sea.png" }, "wallpaper_full", "Same as default"), "sea")
    eq(label({ wallpaper_default = "theme-pack\1Halloween\1wallpaper.jpg" }, "wallpaper_default", "None"), "Halloween pack")
end)

t.done()
