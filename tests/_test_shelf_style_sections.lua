-- tests/_test_shelf_style_sections.lua
-- Which density sections the "Shelf style" picker offers for each mode.
--
-- The picker has four modes across the top (Auto / List / Covers / Spines)
-- and three optional blocks under them: the list's column and row nudges,
-- the spine block, and the "Folder tiles" cycle row. Three one-line flags in
-- Editor:_pickGroupDisplay decide which blocks appear.
--
-- ── THE BUG THIS PINS ───────────────────────────────────────────────────────
--
-- COVERS IS STORED AS ABSENCE. Picking Covers writes nil, not "covers" -- it
-- is the default, so a chip nobody has touched looks exactly as it did before
-- list view existed. That was cf885a1 ("Covers is the default everywhere;
-- Auto is a choice"), which moved nil from Auto to Covers and gave Auto a
-- stored value of its own.
--
-- The gate flags were written under the OLD model, where nil meant Auto, and
-- were never updated:
--
--     local show_list = (mode ~= ViewMode.COVERS and mode ~= ViewMode.SPINES)
--
-- mode is nil for Covers, so `nil ~= "covers"` is true and a Covers chip was
-- offered "List columns" and "List rows" -- controls for a view it is pinned
-- away from. The Covers radio itself already handled the absence
-- (`mode == ViewMode.COVERS or mode == nil`); only the gates missed it.
--
-- Reading the flags out of the source and evaluating them is the point: a
-- test that re-implemented the rule would have agreed with the bug.
--
-- Usage (from plugin root): lua tests/_test_shelf_style_sections.lua
package.path = "./?.lua;./?/init.lua;" .. package.path

local H = dofile("tests/_helpers.lua")
local t = H.runner()

local ViewMode = require("lib/bookshelf_view_mode")

local src = io.open("lib/bookshelf_chip_editor.lua"):read("*a")
-- The three consecutive `local show_* = ...` lines, taken verbatim.
local gates = src:match("(local pin = .-local show_spines = .-\n.-)\n%s*local bw")
assert(gates, "could not find the show_covers/show_list/show_spines block "
    .. "in Editor:_pickGroupDisplay - renamed or reordered?")

local function compile(code, env)
    if _G.setfenv then
        local f = assert(_G.loadstring(code, "gates"))
        _G.setfenv(f, env)
        return f
    end
    return assert(load(code, "gates", "t", env))
end

-- Evaluate the real lines for one stored chip value.
local function sections(stored, is_opds)
    local env = { ViewMode = ViewMode }
    local body = "local mode, chrome = ... ; " .. gates
        .. " ; return show_covers, show_list, show_spines, show_auto_note"
    local mode = ViewMode.chipOverride(stored)
    local c, l, s, n = compile(body, env)(mode, { is_opds = is_opds })
    return { covers = c and true or false, list = l and true or false,
             spines = s and true or false, auto_note = n and true or false }
end

local function check(name, stored, want)
    t.test(name, function()
        local got = sections(stored)
        for _, k in ipairs({ "covers", "list", "spines", "auto_note" }) do
            assert(got[k] == want[k], string.format(
                "%s: expected %s=%s, got %s", name, k,
                tostring(want[k]), tostring(got[k])))
        end
    end)
end

-- Covers: folder tiles yes (they are the tiles it draws), list nudges NO.
check("sections: Covers, stored as absence, offers no list controls",
      nil, { covers = true, list = false, spines = false , auto_note = false })

-- The same chip written explicitly, e.g. by an older build that stored the
-- string before the default flipped. Must read identically.
check("sections: Covers stored explicitly behaves the same as absence",
      ViewMode.COVERS, { covers = true, list = false, spines = false , auto_note = false })

-- List: the list nudges, and no folder tiles -- a list's group rows draw a
-- deck of member covers, not the tile cards.
check("sections: List offers list controls and no folder tiles",
      ViewMode.LIST, { covers = false, list = true, spines = false , auto_note = false })

-- Auto is genuinely both: covers collapsed, a list expanded or drilled in,
-- so both sets of controls apply to it.
check("sections: Auto offers both, because it uses both",
      ViewMode.AUTO, { covers = true, list = true, spines = false , auto_note = true })

-- Spines: its own block only.
check("sections: Spines offers only the spine block",
      ViewMode.SPINES, { covers = false, list = false, spines = true , auto_note = false })

t.test("sections: a catalogue is never offered the spine block", function()
    -- Spines never apply to OPDS: a remote record has no local file, no page
    -- count and no stable identity for the style to stand on.
    local got = sections(ViewMode.SPINES, true)
    assert(got.spines == false, "an OPDS chip was offered spine density")
end)

t.test("sections: an unrecognised stored value falls back to Covers", function()
    -- A chip written by a later release, or hand-edited. chipOverride maps it
    -- to nil, and nil must read as Covers here exactly as it does in the
    -- renderer.
    local got = sections("teleportation")
    assert(got.covers == true and got.list == false,
        "an unknown mode should degrade to the covers default")
end)

-- ── The row order, which is a maintainer ruling ────────────────────────────
--
-- Covers leads the three styles: it is the default, so it is what most chips
-- are actually showing. Auto keeps the front because it is not a style, it is
-- the choice to let the shelf pick between the two that follow it.

t.test("order: Auto, then Covers before List, then Spines", function()
    local block = src:match('header%(_%("Show as"%)%)(.-)%-%- Which density rows')
    assert(block, "could not find the Show as radio block")
    local seen = {}
    for label in block:gmatch('radio%(_%("(%a+)"%)') do
        seen[#seen + 1] = label
    end
    local want = { "Auto", "Covers", "List", "Spines" }
    assert(#seen == #want, "expected " .. #want .. " radios, found " .. #seen
        .. " (" .. table.concat(seen, ", ") .. ")")
    for i = 1, #want do
        assert(seen[i] == want[i], string.format(
            "radio %d should be %s, is %s (row reads: %s)",
            i, want[i], seen[i], table.concat(seen, ", ")))
    end
end)

t.done()
