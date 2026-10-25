-- tests/_test_footer_panel_ink.lua
-- The footer's page buttons take the panel's text colour (Colors > Panel
-- text, or the ink a panel colour brings), as the hamburger and grid glyphs
-- already did. They were recoloured only for a dark shelf the panel does not
-- invert, so a theme pack's panel text left the page count and chevrons
-- black on a dark panel (maintainer, PW5).
--
-- Usage (from plugin root): lua tests/_test_footer_panel_ink.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local t  = dofile("tests/_helpers.lua").runner()
local eq = dofile("tests/_helpers.lua").eq

local src = io.open("lib/bookshelf_widget.lua"):read("*a")
local body = src:match("\n(function BookshelfWidget:_themeButton%(.-\nend)\n")
assert(body, "_themeButton moved")

local function themeButton(flips, panel_ink)
    local env = setmetatable({
        BookshelfWidget = {},
        Blitbuffer = { COLOR_WHITE = "WHITE", COLOR_BLACK = "BLACK" },
        require = function(name)
            if name == "lib/bookshelf_cover_progress" then
                return { panelInk = function() return panel_ink end, ink = function() return "THEME_INK" end }
            end
            return require(name)
        end,
    }, { __index = _G })
    assert(load(body, "themeButton", "t", env))()
    local bw = setmetatable({ _themeFlips = function() return flips end }, { __index = env.BookshelfWidget })
    local btn = { label_widget = { fgcolor = "BLACK" } }
    bw:_themeButton(btn)
    return btn.label_widget.fgcolor
end

t.test("a panel text colour reaches the page count on a light shelf", function()
    eq(themeButton(false, "PANEL_INK"), "PANEL_INK")
end)

t.test("without one, a light shelf keeps KOReader's black", function()
    eq(themeButton(false, nil), "BLACK")
end)

t.test("a flipping dark shelf still takes its ink", function()
    eq(themeButton(true, nil), "THEME_INK")
end)

t.test("the chevrons are recoloured when the panel has a text colour too", function()
    assert(src:find("if self:_themeFlips() or self:_panelInk() then\n        require(\"lib/bookshelf_wallpaper\").recolourIcons(true, self:_chromeInk(),", 1, true),
        "the footer icons only follow a dark shelf")
end)

t.done()
