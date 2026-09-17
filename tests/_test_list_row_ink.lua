-- tests/_test_list_row_ink.lua
-- Every line of a list row paints in the ink colour.
--
-- WHAT CHANGED AND WHY. The first line took the row's ink and every line below
-- it a grey two thirds of the way from paper to ink -- the muted half of
-- "smaller and secondary", landing on the plugin's declared MUTED role. That
-- was a considered rule, and it stopped being right when the ink became the
-- reader's to choose: "listing text colour should all use ink colour,
-- currently everything except the first line is faded".
--
-- A chosen ink that only the first line obeys is not a setting, it is a
-- suggestion. The size difference still separates the subject from the notes
-- under it, which was always the other half of the treatment and the half that
-- survives a device ignoring fgcolor.
--
-- The muted colour is NOT gone: the off-state tick still uses it, and the
-- divider is derived through the same interpolation. This pins that the TEXT
-- stopped using it, not that the idea was deleted.
--
-- Usage (from plugin root): lua tests/_test_list_row_ink.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local helpers = dofile("tests/_helpers.lua")
local t  = helpers.runner()
local src = io.open("lib/bookshelf_list_row.lua"):read("*a")

t.test("every line takes the row's ink, not just the first", function()
    assert(not src:find("(i == 1) and ListRow.ROW_FG or secondaryColor()", 1, true),
        "lines below the first are still muted, so a chosen ink reaches only "
        .. "the title")
    -- From the table the lines are collected into: there is more than one
    -- loop over `styles`, and the other one builds geometry.
    local loop = src:match("local lines = {}\n(.-)\n    end\n")
    assert(loop, "the per-line resolution moved")
    assert(loop:find("template", 1, true), "captured the wrong block")
    assert(loop:find("fgcolor   = ListRow.ROW_FG", 1, true),
        "the line's colour is no longer the row's ink")
end)

t.test("the muted colour survives for what is not text", function()
    -- Deleting it would take the off-tick and the divider's ceiling test with
    -- it. The rule changed for TEXT; the surface still needs a muted role.
    assert(src:find("function ListRow.tickCell", 1, true), "tickCell moved")
    local tick = src:match("function ListRow.tickCell(.-)\nend\n")
    assert(tick and tick:find("secondaryColor()", 1, true),
        "the off-state tick should stay muted; it is an affordance, not text")
    assert(src:find("local SECONDARY_INK", 1, true),
        "SECONDARY_INK is still the one interpolation the divider is checked against")
end)

t.test("the size difference still does the separating", function()
    -- The other half of "smaller and secondary". If this ever goes too, the
    -- subject and its notes become indistinguishable.
    assert(src:find("styles", 1, true), "per-line styles are gone")
    local geom = io.open("lib/bookshelf_list_geom.lua"):read("*a")
    assert(geom:find("secondary", 1, true),
        "the geometry no longer knows about a secondary line at all")
end)

t.done()
