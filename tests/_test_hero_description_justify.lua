-- tests/_test_hero_description_justify.lua
-- The hero description is the one region whose alignment cycle offers
-- Justify. The editor stores that as alignment = "justify"; the renderer has
-- to translate it into TextBoxWidget's justified = true plus a start-edge
-- alignment (left in LTR, automatically mirrored to right for RTL paragraphs
-- by TextBoxWidget's own para-direction handling).
--
-- The widget itself cannot be built in this standalone suite (it pulls the
-- full KOReader UI), so this pins the two halves of the translation the way
-- the other hero-card source tests do.
package.path = "./?.lua;./?/init.lua;" .. package.path
local H = dofile("tests/_helpers.lua")
local t = H.runner()

local function read(path)
    local f = assert(io.open(path, "r"), "missing " .. path)
    local s = f:read("*a")
    f:close()
    return s
end

t.test("the description region opts into the Justify alignment state", function()
    local src = read("lib/bookshelf_hero_line_editor.lua")
    assert(src:find('justify%s*=%s*region_key%s*==%s*"description"'),
        "the description no longer opts into Justify")
end)

t.test("the hero renderer turns Justify into justified text with a start edge", function()
    local src = read("lib/bookshelf_hero_card.lua")
    assert(src:find('desc_alignment%s*==%s*"justify"'),
        "the renderer does not recognise the Justify state")
    assert(src:find('desc_justified%s+and%s+"left"%s+or%s+desc_alignment'),
        "Justify is not mapped to a start-edge alignment")
    assert(src:find("justified%s*=%s*desc_justified"),
        "the description TextBoxWidget is not told to justify")
end)

t.done()
