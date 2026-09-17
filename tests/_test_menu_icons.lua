-- tests/_test_menu_icons.lua
-- The glyphs in front of menu labels: where they may come from, and that
-- every top-level entry has one.
--
-- WHY THE RANGE IS THE RULE. KOReader bundles nerdfonts/symbols.ttf, which
-- covers the Private Use Area (U+E000..U+F8FF) and is listed as font fallback
-- 6 -- so a plain label renders one of these with no per-item font face. Reach
-- outside that range and two things go wrong: the glyph may not resolve at
-- all, and, far worse, a non-PUA arrow (U+21BB) once segfaulted the
-- start-menu render on a PW5, twice, with no Lua traceback. That broadening
-- was reverted rather than solved and the cause was never pinned, so this test
-- treats the PUA as a hard boundary rather than a preference.
--
-- The glyph also has to stay OUT of the translatable string. A private-use
-- codepoint is invisible in most .po editors and would be lost by the first
-- translator to retype the line.
--
-- Usage (from plugin root): lua tests/_test_menu_icons.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local helpers = dofile("tests/_helpers.lua")
local t  = helpers.runner()
local eq = helpers.eq
local Icons = dofile("lib/bookshelf_menu_icons.lua")
local main  = io.open("main.lua"):read("*a")

local function codepoint(g)
    local b1, b2, b3 = g:byte(1, 3)
    assert(b1 and b2 and b3, "not a three-byte sequence")
    return (b1 - 0xE0) * 0x1000 + (b2 - 0x80) * 0x40 + (b3 - 0x80)
end

local NAMES = { "RESET", "SHELF", "SHELF_SIZE", "SHELVES", "APPEARANCE",
                "HARDCOVER", "SETTINGS", "UPDATES", "ABOUT" }

t.test("every glyph sits inside the Private Use Area", function()
    for _i, name in ipairs(NAMES) do
        local g = Icons[name]
        assert(type(g) == "string" and g ~= "", "missing glyph: " .. name)
        local cp = codepoint(g)
        assert(cp >= 0xE000 and cp <= 0xF8FF, string.format(
            "%s is U+%04X, outside the PUA -- the bundled symbols face does "
            .. "not cover it and a non-PUA glyph has segfaulted this render "
            .. "path before", name, cp))
    end
end)

t.test("no two entries share a glyph", function()
    local seen = {}
    for _i, name in ipairs(NAMES) do
        local cp = codepoint(Icons[name])
        assert(not seen[cp], string.format(
            "%s and %s are both U+%04X; two menu rows would look the same",
            name, seen[cp], cp))
        seen[cp] = name
    end
end)

t.test("the spacing is applied in one place, not at each call site", function()
    eq(Icons.label("G", "Thing"), "G  Thing", "two spaces, as the module documents")
    eq(Icons.label(nil, "Thing"), "Thing", "a missing glyph must not print 'nil'")
    eq(Icons.label("", "Thing"), "Thing")
end)

t.test("every top-level menu entry carries one", function()
    -- The canonical order is the list of entries; each must reach the table.
    local order = main:match("Bookshelf%.MENU_ORDER = {(.-)\n}")
    assert(order, "MENU_ORDER moved")
    for key in order:gmatch('"([%w_]+)"') do
        local row = main:match("(menu_items%." .. key .. " = {.-\n    }\n)")
            or main:match("(menu_items%." .. key .. " = {.-\n            }\n)")
        assert(row, "could not read the row for " .. key)
        assert(row:find("MenuIcons.", 1, true),
            key .. " has no icon; every top-level entry should carry one")
    end
end)

t.test("the glyphs live in the table and nowhere else", function()
    -- The strongest form of "it never enters a msgid": the bytes exist in one
    -- file, and that file has no gettext call in it at all. A glyph copied
    -- into a label elsewhere would be a second definition anyway.
    --
    -- Note this rule is about PRIVATE-USE glyphs, not about symbols in
    -- general: the colour menu's day/night header carries ◐ and ☀ inside its
    -- msgid on purpose, and those are ordinary BMP characters a translator can
    -- see and keep.
    local mod = io.open("lib/bookshelf_menu_icons.lua"):read("*a")
    assert(not mod:find("_(", 1, true),
        "the icon table now calls gettext; glyphs must stay out of msgids")
    for _i, path in ipairs({ "main.lua", "lib/bookshelf_settings.lua" }) do
        local src = io.open(path):read("*a")
        for _j, name in ipairs(NAMES) do
            assert(not src:find(Icons[name], 1, true),
                name .. "'s raw bytes appear in " .. path .. "; use the table")
        end
    end
end)

t.test("the bundled font actually has them", function()
    -- Skipped where KOReader is not installed beside the checkout; on the dev
    -- laptop it is, and a glyph the face lacks renders as a tofu box.
    local f = io.open("/usr/lib/koreader/fonts/nerdfonts/symbols.ttf", "rb")
    if not f then return t.skip("no KOReader font tree here") end
    f:close()
    local cps = {}
    for _i, name in ipairs(NAMES) do cps[#cps + 1] = codepoint(Icons[name]) end
    local py = io.popen("python3 -c \"import sys\ntry:\n from fontTools.ttLib import TTFont\nexcept ImportError:\n print('skip'); sys.exit()\nc=TTFont('/usr/lib/koreader/fonts/nerdfonts/symbols.ttf',fontNumber=0).getBestCmap()\nprint(' '.join(str(x) for x in ["
        .. table.concat(cps, ",") .. "] if x not in c) or 'ok')\" 2>/dev/null")
    local out = py and py:read("*a") or ""
    if py then py:close() end
    out = (out or ""):gsub("%s+$", "")
    if out == "" or out == "skip" then return t.skip("fontTools not available") end
    eq(out, "ok", "codepoints missing from the bundled symbols face: " .. out)
end)

t.done()
