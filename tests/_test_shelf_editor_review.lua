-- tests/_test_shelf_editor_review.lua
-- Fixes from the 2026-10-31 review of the shelf editor.
--
-- Usage (from plugin root): lua tests/_test_shelf_editor_review.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local H = dofile("tests/_helpers.lua")
local t = H.runner()
local src = io.open("lib/bookshelf_chip_editor.lua"):read("*a")
local lm = io.open("lib/bookshelf_library_modal.lua"):read("*a")

local function body(text, head)
    local s = text:find(head, 1, true)
    assert(s, "not found: " .. head)
    local e = text:find("\n    end\n", s, true) or text:find("\nend\n", s, true)
    return text:sub(s, e)
end

-- Re-tapping the source a shelf already has ran its defaults (a Recently
-- read shelf's sort went back to Most recently read on the card) and left
-- that in the working copy for the next change to save.
t.test("the same source again puts the working copy back", function()
    local b = body(src, "local function sourceChosen()")
    assert(b:find("if Editor._sameValue(draft.source, committed.source) then revert(); rebuild(); return end", 1, true),
        "a re-tapped source keeps its defaults' sort")
end)

-- Ticks on a filter page left by the X (or Back) were lost, or stayed in the
-- working copy for the next unrelated change to save.
t.test("closing the editor keeps what the working copy holds", function()
    local b = body(src, "local function finish()")
    assert(b:find("if not Editor._sameValue(draft, committed) then commit() end", 1, true),
        "finish drops the working copy's changes")
end)

t.test("Back on the keys in a page of the editor goes back a page", function()
    local b = body(lm, "function LibraryModal:onClose()")
    assert(b:find("local back = self.config and self.config.over and self:_backAction()", 1, true)
        and b:find("back.on_tap()", 1, true), "Back closes a page of the editor without going back")
end)

-- Each up or down rewrote the whole settings file (~130 ms on a PW5) and
-- rebuilt the shelf at once; rapid taps queued behind it.
t.test("Shelf order keeps its moves in memory and lets the shelf catch up", function()
    local b = body(src, "function Editor:_openShelfOrder(")
    assert(b:find("TabModel.saveDeferred(all)", 1, true), "every move writes the settings file")
    assert(not b:find("TabModel.save(all)", 1, true))
    local caller = src:match("self:_openShelfOrder%(tab_id, (.-), editOther%)")
    assert(caller and caller:find("schedulePreview", 1, true), "every move rebuilds the shelf at once")
end)

-- Perf review 2026-10-31: every editor change dropped the shelf's fetch
-- cache, Shelf order too, which changes no shelf's books or pages.
t.test("Shelf order keeps the shelf's fetch cache; a change to the shelf drops it", function()
    local wsrc = io.open("lib/bookshelf_widget.lua"):read("*a")
    local ace = wsrc:match("\n(function BookshelfWidget:_afterChipEdit%(info%).-\nend)\n")
    assert(ace and ace:find("if not info or info.fetch_changed or info.source_changed then", 1, true),
        "the fetch cache goes on every change")
    assert(body(src, "local function commit("):find("owed_info.fetch_changed = true", 1, true), "a shelf change keeps a stale cache")
    assert(body(src, "local function onArranged()"):find("owed_info.fetch_changed = true", 1, true),
        "a new collection order keeps a stale cache")
end)

-- PW5 timing 2026-10-31: a filter picker opened (no tick kept) left an
-- empty set in the working copy, and the Filters page's back committed on
-- every visit; either cost a settings write and a shelf rebuild (~0.9 s)
-- for nothing.
local function sameValue()
    local s = src:find("local function blank(t)", 1, true)
    local e = src:find("\nend\n", src:find("function Editor._sameValue(a, b)", 1, true), true)
    local chunk = "local Editor = {}\n" .. src:sub(s, e + 4) .. "return Editor._sameValue"
    return assert(load(chunk))()
end

t.test("an empty set is the same as none", function()
    local same = sameValue()
    assert(same({ filter = { genres = {} } }, {}), "an opened picker's empty set reads as a change")
    assert(same({}, { filter = { genres = {}, genres_all = {} } }))
    assert(same({ label = "A", filter = {} }, { label = "A" }))
    assert(not same({ filter = { genres = { Poetry = true } } }, {}), "a tick is a change")
    assert(not same({ filter = { genres = {} } }, { filter = { genres = { Poetry = true } } }),
        "untick the last is a change")
    assert(not same({ label = "A" }, { label = "B" }))
    assert(not same({ hide_add_tile = true }, {}))
end)

t.test("a commit with nothing changed writes nothing", function()
    local b = body(src, "local function commit(")
    assert(b:find("if Editor._sameValue(draft, committed) then return end", 1, true),
        "commit writes and rebuilds the shelf with nothing changed")
end)

-- Maintainer, 2026-10-31: View mode beside Source (both short values),
-- Filters beside Sort: a shorter front page. A narrow screen stacks them.
t.test("the front page pairs Source with View mode, Filters with Sort", function()
    assert(src:find("source_row[#source_row + 1] = view_cell", 1, true), "View mode is not beside Source")
    assert(src:find("for _i, c in ipairs(sort_row or {}) do pair_row[#pair_row + 1] = c end", 1, true),
        "Sort is not beside Filters")
    assert(src:find("if not src_rows then", 1, true), "a source's own rows lose their place")
end)

t.test("a row too narrow for its cards stacks them full width", function()
    local b = body(src, "local function buildCards(")
    assert(b:find("Screen:scaleBySize(160)", 1, true), "narrow screens squeeze two cards side by side")
end)

-- Maintainer, 2026-10-31: the Face out page's line restated the ticks
-- below it ("Face out: Unread, Reading. Check as many..."). It says what the
-- page is for instead, and stays put.
t.test("the Face out page says what it is for, not what is ticked", function()
    assert(src:find('_("Choose which books show their cover facing out on this shelf. The rest show their spines.")', 1, true),
        "no help line on Face out")
    assert(not src:find("Check as many reasons as you like", 1, true), "the ticks are restated at the top")
end)

-- Maintainer, 2026-10-31: the Modules card vanished with modules off on
-- the shelf (or on a List shelf), with nothing to say why; it stays,
-- greyed, saying why.
t.test("the Modules card stays, greyed with a reason, where it can't add", function()
    assert(src:find('why = _("Off in Settings")', 1, true), "modules off on the shelf hides the card")
    assert(src:find('why = _("Not in List view")', 1, true), "a List shelf hides the card")
    assert(src:find("enabled = why == nil,", 1, true), "the card is not greyed")
end)

-- Maintainer, 2026-10-31: the Modules card says how many the shelf has;
-- Filters says what the page is for, not what is set (the rows say that),
-- and its footnote goes.
t.test("Modules says how many are on the shelf", function()
    assert(src:find('T(_("%1 on this shelf"), n_mods)', 1, true), "the card does not count the shelf's modules")
end)

t.test("Filters says what it is for, with no restatement and no footnote", function()
    assert(src:find('_("Books matching the filters you choose below will show in this shelf.")', 1, true), "no help line on Filters")
    assert(not src:find("Showing books that match", 1, true), "the filters are restated at the top")
    assert(not src:find("A book must match every filter; each filter's page", 1, true), "the footnote is still there")
end)

-- Maintainer, 2026-10-31: on a spines shelf with modules, Modules closed
-- the editor and opened nothing (the layout editor is the covers' only). A
-- page lists them, each opening its own menu, and adds another.
t.test("on spines, Modules is a page of the shelf's modules", function()
    local src = io.open("lib/bookshelf_chip_editor.lua"):read("*a")
    assert(src:find("if n_mods > 0 and opts.bw:_isSpineMode() then return modulesPage() end", 1, true),
        "Modules on a spines shelf opens nothing")
    assert(src:find("opts.bw:_spineModuleMenu(m)", 1, true), "a module's row does not open its menu")
end)

t.done()
