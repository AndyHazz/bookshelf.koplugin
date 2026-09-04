-- tests/_test_new_chip_source_first.lua
-- Creating a chip opens the source picker straight away.
--
-- A new chip is created holding a placeholder source (kind = "all", which
-- reads as "Home (folders)") and the generic label "New chip". Opening the
-- editor on that presents both as though they had been chosen, when in fact
-- the source is the first decision to make -- and the one that names the chip,
-- since _applySourceDefaults renames a label still reading "New chip".
--
-- SOURCE-SHAPE checks: editTab builds a ButtonDialog over MovableContainer and
-- reads the screen, none of which this suite stubs, so the wiring is asserted
-- against the source. What matters is that BOTH creation routes ask for it and
-- that plain editing does not, which is exactly the asymmetry a source read
-- can see.
package.path = "./?.lua;./?/init.lua;" .. package.path

local t = dofile("tests/_helpers.lua").runner()

local editor   = io.open("lib/bookshelf_chip_editor.lua"):read("*a")
local settings = io.open("lib/bookshelf_settings.lua"):read("*a")

local edit_tab = editor:match("\nfunction Editor:editTab%(tab_id, opts%)\n(.-)\nend\n\n")
assert(edit_tab, "could not find Editor:editTab - renamed?")

t.test("editTab opens the picker only when asked", function()
    assert(edit_tab:match("opts%.pick_source_first"),
        "editTab must gate the picker on an explicit option")
    local guard = edit_tab:match("if opts%.pick_source_first then(.-)end")
    assert(guard, "expected an `if opts.pick_source_first then` block")
    assert(guard:match("Editor:_pickSource%(draft,"),
        "the block must open the source picker on this draft")
end)

t.test("the picker is shown AFTER the editor, so cancelling lands somewhere", function()
    -- Opening it before the editor exists would leave Cancel returning to
    -- nothing, and the picker would be underneath the editor besides.
    local show_at = edit_tab:find("UIManager:show%(dialog")
    local pick_at = edit_tab:find("opts%.pick_source_first")
    assert(show_at and pick_at, "expected both the show and the picker call")
    assert(pick_at > show_at,
        "the source picker must be opened after the editor dialog is shown")
end)

t.test("editing an existing chip does NOT open the picker", function()
    -- The regression that would make the editor unusable: every chip tap
    -- popping a source picker over it.
    for _, call in ipairs({
        settings:match("(Editor:editTab%(tab_id, [^\n]*)"),
    }) do
        assert(not call:match("pick_source_first"),
            "editing an existing chip must not request the picker: " .. call)
    end
end)

t.test("both creation routes ask for it", function()
    -- One route doing it and the other not is the likely half-fix: the chip
    -- strip's "+" and the settings menu's "+ Add new chip" create the same
    -- thing and must behave the same.
    local plus = editor:match("Editor:editTab%(new_id, new_opts%)")
    assert(plus, "the editor's own + must still create a chip")
    assert(editor:match("new_opts%.pick_source_first = true"),
        "the editor's + must request the source picker")

    local footer = settings:match("Editor:editTab%(new_id, %{(.-)%}%)")
    assert(footer, "could not find the settings + Add new chip call")
    assert(footer:match("pick_source_first = true"),
        "+ Add new chip must request the source picker too")
end)

t.test("the editor's + copies opts rather than mutating the caller's", function()
    -- opts belongs to the editor we were opened FROM and outlives this call;
    -- setting the flag on it would make the next thing reading that table
    -- believe it, too.
    local block = editor:match("(local new_opts = %{%}.-Editor:editTab%(new_id, new_opts%))")
    assert(block, "expected the opts copy immediately before the editTab call")
    assert(block:match("for k, v in pairs%(opts%) do new_opts%[k%] = v end"),
        "the copy must carry the caller's options over")
    -- Anchored on a non-identifier char: a bare "opts%." pattern also matches
    -- inside "new_opts.", so the unanchored form passes against the bug AND
    -- fails against the fix.
    assert(not editor:match("[^%w_]opts%.pick_source_first%s*="),
        "the flag must never be written onto the caller's own opts table")
end)

t.done()
