-- Unit tests for the user-icons folder scan + opt-in SVG chip / search-union
-- in lib/bookshelf_icons_library.lua. Pure-Lua: stubs datastorage + lfs so the
-- scan runs against a fake directory listing, plus the widget/runtime deps the
-- module requires at load.
-- Usage: cd into the plugin dir, then `lua tests/_test_icon_library.lua`.

package.path = "./?.lua;./?/init.lua;" .. package.path

-- Fake filesystem: filename -> mode ("file"/"directory").
local FAKE = {
    ["heart.svg"]   = "file",
    ["star.png"]    = "file",
    ["dup.svg"]     = "file",
    ["dup.png"]     = "file",   -- same base as dup.svg; svg must win
    ["bad].svg"]    = "file",   -- ']' in name: excluded (breaks tag grammar)
    [".hidden.svg"] = "file",   -- dotfile: excluded (e.g. macOS ._ sidecars)
    ["sub"]         = "directory",
    ["."]           = "directory",
    [".."]          = "directory",
}

package.loaded["datastorage"] = {
    getDataDir = function() return "/fake" end,
}
package.loaded["libs/libkoreader-lfs"] = {
    attributes = function(path, what)
        if what ~= "mode" then return nil end
        if path == "/fake/icons" then return "directory" end
        local name = path:match("/fake/icons/(.+)$")
        return name and FAKE[name] or nil
    end,
    dir = function(_)
        local names, i = {}, 0
        for k in pairs(FAKE) do names[#names + 1] = k end
        return function() i = i + 1; return names[i] end
    end,
}

-- Minimal stubs for the rest of icons_library.lua's load-time requires.
local function noop_tbl() return setmetatable({}, { __index = function() return function() end end }) end
package.loaded["ffi/blitbuffer"] = {}
package.loaded["ui/widget/container/centercontainer"] = noop_tbl()
package.loaded["device"] = { screen = {
    scaleBySize = function(_, n) return n end,
    getWidth = function() return 600 end, getHeight = function() return 800 end } }
package.loaded["ui/widget/container/framecontainer"] = noop_tbl()
package.loaded["ui/geometry"] = { new = function(_, t) return t end }
package.loaded["lib/bookshelf_library_modal"] = noop_tbl()
package.loaded["ui/widget/notification"] = noop_tbl()
package.loaded["ui/size"] = setmetatable({}, { __index = function() return setmetatable({}, { __index = function() return 4 end }) end })
package.loaded["ui/uimanager"] = noop_tbl()
package.loaded["ui/widget/verticalgroup"] = noop_tbl()
package.loaded["ui/widget/verticalspan"] = noop_tbl()
package.loaded["lib/bookshelf_icons_catalogue"] = { CHIPS = {}, CURATED_BY_CHIP = {}, PATTERNS_BY_CHIP = {}, PATTERN_EXCLUDES = {} }
package.loaded["lib/bookshelf_i18n"] = { gettext = function(s) return s end }
package.loaded["ffi/util"] = { template = function(s) return s end }
-- Small nerd-font index so the search-union test can prove the union without
-- loading the real ~2,800-entry data file. "heart" matches "heartbeat" here.
package.loaded["lib/bookshelf_nerdfont_names"] = { { code = 0xF21E, name = "heartbeat" } }

local IconsLibrary = dofile("lib/bookshelf_icons_library.lua")

local helpers = dofile("tests/_helpers.lua")
local t = helpers.runner()

t.test("scan lists svg+png, dedups by basename (svg wins), excludes ']' and dirs", function()
    local cells = IconsLibrary._scanUserIcons()
    local byname = {}
    for _, c in ipairs(cells) do byname[c.label] = c end
    assert(byname["heart"], "heart.svg listed")
    assert(byname["star"], "star.png listed")
    assert(byname["dup"], "dup listed")
    assert(byname["bad]"] == nil, "filename with ']' excluded")
    assert(byname["sub"] == nil, "subdirectory excluded")
    assert(byname["."] == nil and byname[".."] == nil, "dot entries excluded")
    assert(byname[".hidden"] == nil, "dotfile excluded")
    assert(#cells == 3, "expected 3 cells (heart, star, dup); got " .. #cells)
end)

t.test("cells carry icon name, image flag and [icon=NAME] insert value", function()
    local cells = IconsLibrary._scanUserIcons()
    local heart
    for _, c in ipairs(cells) do if c.label == "heart" then heart = c end end
    assert(heart.is_image == true, "is_image flag")
    assert(heart.icon == "heart", "icon name")
    assert(heart.insert_value == "[icon=heart]", "insert value: " .. tostring(heart.insert_value))
end)

t.test("results are sorted alphabetically by label", function()
    local cells = IconsLibrary._scanUserIcons()
    for i = 2, #cells do
        assert(cells[i-1].label:lower() <= cells[i].label:lower(), "sorted at index " .. i)
    end
end)

t.test("svg chip returns the scanned user icons", function()
    local items = IconsLibrary._itemList("svg", nil, true)
    assert(#items > 0, "svg chip non-empty")
    assert(items[1].is_image, "svg chip yields image cells")
end)

t.test("search surfaces matching user icons by filename when allow_svg", function()
    local items = IconsLibrary._itemList("all", "heart", true)
    local found = false
    for _, c in ipairs(items) do
        if c.is_image and c.label == "heart" then found = true end
    end
    assert(found, "user icon 'heart' present in search results for 'heart'")
end)

t.test("search excludes user icons when not allow_svg", function()
    local items = IconsLibrary._itemList("all", "heart", false)
    for _, c in ipairs(items) do
        assert(not c.is_image, "no image cells when allow_svg is false")
    end
end)

t.done()
