-- tests/_test_chip_editor.lua
-- Pure-Lua tests for the chip editor's source/sort configuration tables and
-- the defaults-applier. These are the tables contributors extend when adding a
-- new chip source (e.g. PR #114's "Languages"), so a typo here -- a bad sort
-- key, a missing reverse flag, a group kind with no defaults -- is exactly the
-- kind of regression worth catching cheaply.
--
-- chip_editor is a UI module; it only `require`s its widget deps at load (never
-- calls them), so empty stubs are enough to load it standalone. The config
-- tables + _applySourceDefaults are exposed via Editor._test.

package.path = "./?.lua;./?/init.lua;" .. package.path

for _, m in ipairs({
    "ui/widget/buttondialog", "ui/widget/confirmbox", "ui/uimanager",
    "ui/geometry", "ui/size",
    "lib/bookshelf_tab_model",   -- only used in methods, not at load
}) do
    package.loaded[m] = {}
end
package.loaded["device"] = { screen = {} }
package.loaded["logger"] = {
    dbg = function() end, info = function() end,
    warn = function() end, err = function() end,
}
package.loaded["lib/bookshelf_i18n"] = { gettext = function(s) return s end }
package.loaded["ffi/util"] = {
    -- Real ffi/util.template does %1/%2/... positional substitution; the
    -- source-label formatter needs exactly that.
    template = function(s, ...)
        local args = { ... }
        return (s:gsub("%%(%d+)", function(n)
            return tostring(args[tonumber(n)])
        end))
    end,
}

-- Fake OPDS servers (Task 5's bookshelf_opds_source contract): two catalogues,
-- keyed the way the real module keys them (a stable hash of the URL) but with
-- readable fake keys here since only the lookup-by-key behaviour is exercised.
local FAKE_OPDS_SERVERS = {
    { key = "k1", title = "Server One", url = "http://one.example/opds" },
    { key = "k2", title = "Server Two", url = "http://two.example/opds" },
}
package.loaded["lib/bookshelf_opds_source"] = {
    servers = function() return FAKE_OPDS_SERVERS end,
    getServer = function(key)
        for _, s in ipairs(FAKE_OPDS_SERVERS) do
            if s.key == key then return s end
        end
        return nil
    end,
    isAvailable = function() return #FAKE_OPDS_SERVERS > 0 end,
}

local Editor = dofile("lib/bookshelf_chip_editor.lua")
local D = assert(Editor._test, "chip_editor did not expose _test internals")

local helpers = dofile("tests/_helpers.lua")
local t = helpers.runner()
local eq = helpers.eq

-- Known sort keys the engine understands; any default referencing something
-- outside this set is almost certainly a typo.
local VALID_SORT_KEYS = {
    filename = true, title = true, author_surname = true, author_name = true,
    series_name = true, series_index = true, series_combined = true, series_or_title = true,
    last_opened = true, date_added = true, percent_read = true,
    read_status = true, read_status_active = true, favorites_first = true, rating = true,
    page_count = true, book_count = true, size = true,
    collection_order = true, published = true,
}

t.test("every SOURCE_SORT_DEFAULTS entry is a non-empty list of {key,reverse}, except fixed-order sources", function()
    -- "opds" is a deliberate exception: the feed order is fixed
    -- (server-defined), so its defaults are an empty list -- see the
    -- "no sort levels" test below. "shelves" (a shelf of shelves) is the
    -- other: its shelves stand in the order the reader arranges them.
    local FIXED_ORDER_KINDS = { opds = true, shelves = true }
    for kind, levels in pairs(D.SOURCE_SORT_DEFAULTS) do
        if FIXED_ORDER_KINDS[kind] then
            eq(levels, {})
        else
            assert(type(levels) == "table" and #levels > 0,
                kind .. ": defaults must be a non-empty list")
            for i, lv in ipairs(levels) do
                assert(type(lv.key) == "string",
                    kind .. "[" .. i .. "]: key must be a string")
                assert(VALID_SORT_KEYS[lv.key],
                    kind .. "[" .. i .. "]: unknown sort key '" .. tostring(lv.key) .. "'")
                assert(type(lv.reverse) == "boolean",
                    kind .. "[" .. i .. "]: reverse must be a boolean")
            end
        end
    end
end)

t.test("PR #114 language sources have their expected defaults", function()
    -- Languages group: most-populated language first, then within-group order.
    eq(D.SOURCE_SORT_DEFAULTS.languages, {
        { key = "book_count",   reverse = true },
        { key = "series_name",  reverse = false },
        { key = "series_index", reverse = false },
    })
    -- Specific language: a filtered book list.
    eq(D.SOURCE_SORT_DEFAULTS.language, {
        { key = "author_surname", reverse = false },
        { key = "series_name",    reverse = false },
        { key = "series_index",   reverse = false },
    })
end)

t.test("GROUP_KINDS is exactly the expected set", function()
    eq(D.GROUP_KINDS, {
        series = true, authors = true, genres = true,
        tags = true, formats = true, languages = true,
        decades = true,
    })
end)

t.test("every group kind has a SOURCE_SORT_DEFAULTS entry", function()
    for kind in pairs(D.GROUP_KINDS) do
        assert(D.SOURCE_SORT_DEFAULTS[kind],
            "group kind '" .. kind .. "' has no sort defaults")
    end
end)

t.test("applySourceDefaults copies the kind's sort priority (deep copy)", function()
    local draft = { source = { kind = "authors" }, label = "Keep me" }
    D.applySourceDefaults(draft)
    eq(draft.sort_priority, D.SOURCE_SORT_DEFAULTS.authors)
    -- Mutating the draft must NOT bleed into the shared defaults table.
    draft.sort_priority[1].reverse = true
    assert(D.SOURCE_SORT_DEFAULTS.authors[1].reverse == false,
        "applySourceDefaults shared the defaults table by reference")
end)

t.test("applySourceDefaults leaves a user-edited label alone", function()
    local draft = { source = { kind = "genres" }, label = "My Genres" }
    D.applySourceDefaults(draft)
    eq(draft.label, "My Genres")
end)

t.test("applySourceDefaults relabels an untouched 'New chip' to the source label", function()
    local draft = { source = { kind = "genres" }, label = "New shelf" }
    D.applySourceDefaults(draft)
    -- SOURCE_LABEL.genres() -> _("Genres") -> identity in tests.
    eq(draft.label, "Genres")
end)

t.test("applySourceDefaults uses a specific source id as the label", function()
    local draft = { source = { kind = "author", id = "Ursula K. Le Guin" }, label = "New shelf" }
    D.applySourceDefaults(draft)
    eq(draft.label, "Ursula K. Le Guin")
end)

t.test("applySourceDefaults uses the folder basename for folder sources", function()
    local draft = { source = { kind = "folder", id = "/mnt/us/ebooks/Sci-Fi" }, label = "New shelf" }
    D.applySourceDefaults(draft)
    eq(draft.label, "Sci-Fi")
end)

t.test("applySourceDefaults is a no-op for an unknown source kind", function()
    local draft = { source = { kind = "totally_unknown" }, label = "New shelf" }
    D.applySourceDefaults(draft)
    eq(draft.sort_priority, nil)   -- no defaults applied
end)

-- Task 12: OPDS catalogue sources ------------------------------------------

t.test("resolveSourceLabel resolves an OPDS server title via OpdsSource.getServer", function()
    local D2 = assert(Editor._test.resolveSourceLabel,
        "chip_editor did not expose _resolveSourceLabel for testing")
    eq(D2({ kind = "opds", id = "k1" }), "OPDS: Server One")
    eq(D2({ kind = "opds", id = "k2" }), "OPDS: Server Two")
end)

t.test("resolveSourceLabel falls back to the raw key for a vanished OPDS server", function()
    local D2 = Editor._test.resolveSourceLabel
    eq(D2({ kind = "opds", id = "deleted-server-key" }), "OPDS: deleted-server-key")
end)

t.test("resolveSourceLabel handles an OPDS source with no id yet without erroring", function()
    local D2 = Editor._test.resolveSourceLabel
    eq(D2({ kind = "opds" }), "OPDS catalog")
end)

-- ── A collection keeps the order KOReader files it in (issue #441) ────────

t.test("a new collection chip defaults to the collection's own order", function()
    eq(D.SOURCE_SORT_DEFAULTS.collection, {
        { key = "collection_order", reverse = false },
        { key = "last_opened",      reverse = true  },
    })
end)

t.test("the second level carries a collection KOReader stores no order for", function()
    -- Only a manually collated collection persists an item order, so the
    -- pairing is the whole design: with no manual order every book ties on
    -- level one and the shelf still comes out most-recently-opened first,
    -- which is what a collection chip did before this key existed.
    local levels = D.SOURCE_SORT_DEFAULTS.collection
    assert(#levels == 2, "expected a fallback level, got " .. #levels)
    assert(levels[2].key == "last_opened" and levels[2].reverse == true,
        "the fallback is no longer the old default")
end)

t.test("sourceSortDefaults hands out a copy, never the table itself", function()
    local a = Editor.sourceSortDefaults("collection")
    a[1].key = "clobbered"
    assert(D.SOURCE_SORT_DEFAULTS.collection[1].key == "collection_order",
        "the defaults table was handed out by reference and got mutated")
    assert(Editor.sourceSortDefaults("collection")[1].key == "collection_order",
        "a later caller saw the first caller's edit")
end)

t.test("sourceSortDefaults is nil for a kind with no defaults", function()
    assert(Editor.sourceSortDefaults("not_a_real_kind") == nil)
end)

t.test("pinning a collection from the manager uses the same defaults", function()
    -- The manager builds its own tab row rather than going through the
    -- editor's draft, so it carried a SECOND copy of the collection default
    -- and the two could drift. It asks for them now. Checked in the source
    -- because the manager is a UI module with no standalone harness.
    local src = assert(io.open("lib/bookshelf_collection_manager.lua")):read("*a")
    local pin = src:match("local function _pinAsChip.-\nend")
    assert(pin, "_pinAsChip moved or was renamed")
    assert(pin:match('sourceSortDefaults%("collection"%)'),
        "the pinned chip does not take its sort from the editor's defaults")
    assert(not pin:match('sort_priority%s*=%s*{%s*{'),
        "the pinned chip still carries a literal sort_priority")
end)

t.test("the sort picker offers Collection order on a collection chip only", function()
    -- The default only reaches chips made from now on, so a chip that already
    -- exists needs the key in the picker or the reader cannot ask for it.
    -- Offered nowhere else: off a collection source every book's
    -- collection_order is nil, so the row would be a no-op that still costs a
    -- slot in a grid the file's own comment keeps compact.
    local BD = package.loaded["ui/widget/buttondialog"]
    local UI = package.loaded["ui/uimanager"]
    local captured
    BD.new   = function(_self, t) captured = t; return t end
    UI.show  = function() end
    UI.close = function() end
    local function offered(kind)
        captured = nil
        Editor:_openSort({ source = { kind = kind }, sort_priority = {} })
        local texts = {}
        for _i, row in ipairs(captured and captured.buttons or {}) do
            for _j, btn in ipairs(row) do texts[#texts + 1] = btn.text end
        end
        return table.concat(texts, " | ")
    end
    assert(offered("collection"):find("Collection order", 1, true),
        "a collection chip cannot pick its own order: " .. offered("collection"))
    assert(not offered("all"):find("Collection order", 1, true),
        "Collection order offered on a source that has none")
end)

-- Picking a level in the strip changes nothing saved: it redraws the page
-- only. It went through the commit too, so the shelf behind was rebuilt and
-- the whole screen refreshed again after every pick (maintainer, PW5).
t.test("picking a sort level does not save the shelf", function()
    local BD = package.loaded["ui/widget/buttondialog"]
    local UI = package.loaded["ui/uimanager"]
    local captured
    BD.new   = function(_self, o) captured = o; return o end
    UI.show  = function() end
    UI.close = function() end
    local saves = 0
    Editor:_openSort({ source = { kind = "all" },
        sort_priority = { { key = "title" }, { key = "date_added" } } },
        function() saves = saves + 1 end)
    local level2
    for _i, row in ipairs(captured.buttons) do
        if row[1].text and row[1].text:find("^.-2 ") then level2 = row[1] end
    end
    assert(level2, "no level 2 in the strip")
    level2.callback()
    eq(saves, 0, "picking level 2 saved the shelf")
end)

-- ── Arranging the collection from beside its key ───────────────────────────
--
-- The maintainer's request, straight after trying the key on a device:
-- changing a collection's order meant leaving for KOReader's collections view.
-- The button opens the arrange window over the picker, so confirming or
-- backing out lands the reader back on the picker, where the key is.

local function pickerFor(source, order_stub)
    local BD = package.loaded["ui/widget/buttondialog"]
    local UI = package.loaded["ui/uimanager"]
    local captured
    local calls = { closed = 0 }
    BD.new   = function(_self, o) captured = o; return o end
    UI.show  = function() end
    UI.close = function() calls.closed = calls.closed + 1 end
    package.loaded["lib/bookshelf_collection_order"] = order_stub or {
        exists  = function(name) return name == "discworld" end,
        arrange = function(name, on_saved)
            calls.arranged = name; calls.on_saved = on_saved; return true
        end,
    }
    calls.on_arranged = function() calls.arranged_fired = true end
    Editor:_openSort({ source = source, sort_priority = {} }, nil, calls.on_arranged)
    return captured, calls
end

-- The row of the page holding the Collection order key.
local function keyRow(d)
    for _i, row in ipairs(d.buttons) do
        if row[1].text and row[1].text:find("Collection order", 1, true) then return row end
    end
    error("no Collection order row")
end

t.test("a collection chip can arrange its collection from beside the key", function()
    local d, calls = pickerFor({ kind = "collection", id = "discworld" })
    local row = keyRow(d)
    eq(#row, 2, "the edit button is not beside the Collection order key")
    assert(row[1].text:find("Collection order", 1, true), "row 1 is not the key")
    assert(row[2].text:find("Edit collection order", 1, true),
        "no Edit collection order button: " .. tostring(row[2] and row[2].text))
    row[2].callback()
    eq(calls.arranged, "discworld", "the button did not open that collection")
    eq(calls.closed, 0,
        "opening the arrange window closed the picker the reader comes back to")
end)

t.test("a confirmed arrangement is reported back to the editor", function()
    -- The arrangement is written to KOReader at once, not held in the draft,
    -- so the editor has to hear about it to repaint the shelf -- Cancel
    -- included, because backing out of the editor does not undo it.
    local d, calls = pickerFor({ kind = "collection", id = "discworld" })
    keyRow(d)[2].callback()
    assert(calls.on_saved, "the picker gave the arrange window nothing to call")
    calls.on_saved()
    eq(calls.arranged_fired, true, "the editor was never told the order changed")
end)

-- The editor's close paths are behaviour-tested in _test_chip_editor_live_apply.
local editor_src = io.open("lib/bookshelf_chip_editor.lua"):read("*a")

t.test("a confirmed arrangement repaints the shelf straight away", function()
    -- The maintainer, on the PW5: the order is saved the moment the arrange
    -- window closes, so the shelf behind should show it then, not only once
    -- the whole editor is closed. Through the editor's own debounced preview,
    -- so the confirm tap is not held up by a shelf rebuild.
    -- schedulePreview marks the rebuild owed, which every close path runs
    -- if it has not run yet.
    local body = editor_src:match("local function onArranged%(%)(.-)\n    end\n")
    assert(body, "onArranged is gone, or became a one-liner again")
    assert(body:find("schedulePreview()", 1, true),
        "the shelf still waits for the editor to close")
end)

t.test("onArranged is declared below the preview it schedules", function()
    -- A local function body resolves names at load: declared ABOVE
    -- `local function schedulePreview`, it would read a nil GLOBAL at the
    -- moment of the confirm and raise, with nothing at load time to warn.
    local sched = editor_src:find("local function schedulePreview", 1, true)
    local arr   = editor_src:find("local function onArranged", 1, true)
    assert(sched and arr, "one of the two moved")
    assert(arr > sched, "onArranged would call a nil schedulePreview")
end)

t.test("the Sort page is handed the arrangement hook", function()
    local n = select(2, editor_src:gsub(
        "Editor:_openSort%(draft, function%(%) commit%(%) end, onArranged", ""))
    eq(n, 1, "the Sort page opens without the arrangement hook")
end)

t.test("no edit button when there is no collection behind the chip", function()
    -- A pinned TAG is kind "collection" with the tag as its id. The key still
    -- shows -- it ties harmlessly -- but there is nothing to arrange.
    local d = pickerFor({ kind = "collection", id = "sci-fi" })
    eq(#keyRow(d), 1, "an arrange button was offered for a tag")
end)

t.test("no edit button off a collection source", function()
    local d = pickerFor({ kind = "all" })
    for _i, row in ipairs(d.buttons) do
        for _j, btn in ipairs(row) do
            assert(not btn.text:find("Edit collection order", 1, true),
                "the arrange button leaked onto a non-collection shelf")
        end
    end
end)

t.test("SOURCE_SORT_DEFAULTS.opds is the empty list (fixed feed order, no sort levels)", function()
    eq(D.SOURCE_SORT_DEFAULTS.opds, {})
end)

-- Kindle library source (issue #355) -----------------------------------------

t.test("resolveSourceLabel names the Kindle library source", function()
    local D2 = Editor._test.resolveSourceLabel
    eq(D2({ kind = "kindle" }), "Kindle Virtual Library")
end)

t.test("SOURCE_SORT_DEFAULTS.kindle sorts by title", function()
    -- Deliberately title and not filename: a Kindle source file is named
    -- "01. The Colour of Magic - Terry Pratchett_127FE891….kfx" while the shelf
    -- shows the catalogue title, so a filename sort would look random.
    eq(D.SOURCE_SORT_DEFAULTS.kindle, { { key = "title", reverse = false } })
end)

t.test("applySourceDefaults sets up a Kindle draft", function()
    local draft = { source = { kind = "kindle" }, label = "New shelf" }
    D.applySourceDefaults(draft)
    eq(draft.sort_priority, { { key = "title", reverse = false } })
    eq(draft.label, "Kindle Virtual Library")
end)

t.test("applySourceDefaults leaves sort_priority = {} for an opds draft", function()
    local draft = { source = { kind = "opds", id = "k1" }, label = "New shelf" }
    D.applySourceDefaults(draft)
    eq(draft.sort_priority, {})
end)

t.test("applySourceDefaults uses the OPDS server title (not the raw key) as the label", function()
    local draft = { source = { kind = "opds", id = "k1" }, label = "New shelf" }
    D.applySourceDefaults(draft)
    eq(draft.label, "Server One")
end)

t.test("applySourceDefaults leaves a user-edited label alone for an opds draft", function()
    local draft = { source = { kind = "opds", id = "k1" }, label = "My catalogue" }
    D.applySourceDefaults(draft)
    eq(draft.label, "My catalogue")
end)

t.test("series filter picker marks what UNSET actually does (#350)", function()
    -- On a series chip an absent series_membership means stacks-only, but the
    -- picker marked "both" - claiming a state the shelf was not in, so the
    -- pre-ticked option had to be tapped to take effect. Drive the real
    -- picker with a stubbed ButtonDialog and read which row got the filled
    -- radio marker.
    local shown_buttons
    package.loaded["ui/widget/buttondialog"] = {
        new = function(_self, opts)
            shown_buttons = opts.buttons
            return { _stub = true }
        end,
    }
    -- The editor captured UIManager as a load-time local pointing at the
    -- suite's empty stub table: MUTATE that table rather than replacing the
    -- package.loaded slot. ButtonDialog is required at call time, so the
    -- slot swap above does reach it. Filter is the real module.
    local UM = package.loaded["ui/uimanager"]
    UM.show, UM.close = function() end, function() end
    local function markedValue(draft)
        shown_buttons = nil
        Editor._pickChoiceFilter(Editor, draft, "series_membership", function() end)
        assert(shown_buttons, "the picker never built its dialog")
        -- The page's card in force is ticked in its button form.
        for _i, row in ipairs(shown_buttons) do
            local text = row[1].text
            if text and text:find("\xE2\x9C\x93", 1, true) then return text end
        end
        return nil
    end

    -- A series chip with NO stored value: unset behaves stacks-only, so the
    -- filled marker must sit on "Only books in series".
    local marked = markedValue({ source = { kind = "series" }, filter = {} })
    assert(marked and marked:find("Only books in series", 1, true),
        "series chip unset must mark in_series, got: " .. tostring(marked))

    -- A book-list chip with NO stored value: unset compiles to no effect,
    -- which is "both" - that marker stays.
    marked = markedValue({ source = { kind = "all" }, filter = {} })
    assert(marked and marked:find("Standalone and books", 1, true),
        "book-list chip unset must mark both, got: " .. tostring(marked))

    -- An explicit stored value always wins over either default.
    marked = markedValue({ source = { kind = "series" },
                           filter = { series_membership = "both" } })
    assert(marked and marked:find("Standalone and books", 1, true),
        "an explicit both must mark both, got: " .. tostring(marked))
end)

-- ── Every picker sits above the shelf it is about ─────────────────────────
--
-- SOURCE-SHAPE, because placement is a constructor field: nothing a picker
-- RETURNS says where it was drawn, and the only alternative is a screenshot.
--
-- The shelf-style picker had the high anchor to itself. The maintainer's
-- point is that the reason generalises: a chip's source, filters, sort and
-- face-out are all settings about the shelf, and a dialog centred over the
-- shelf hides the thing being set.

local editor_src = assert(io.open("lib/bookshelf_chip_editor.lua")):read("*a")

-- The body of one Editor: method, so a dialog in a neighbouring function
-- cannot satisfy an assertion about this one.
local function bodyOf(name)
    local body = editor_src:match("\nfunction Editor:" .. name .. "%b()(.-)\nend\n")
    assert(body, "Editor:" .. name .. " is gone or was renamed")
    return body
end

for _, name in ipairs({
    "_pickSource", "_openFilters", "_pickChoiceFilter",
    "_pickFolderFilter", "_openSort",
}) do
    t.test(name .. " anchors its dialog above the shelf", function()
        local body = bodyOf(name)
        -- Editor._menu: a page inside the shelf editor while it is open,
        -- else this anchored ButtonDialog.
        assert(body:find("Editor._menu{", 1, true), "no dialog in " .. name)
        assert(body:find("_highAnchor", 1, true),
            name .. " went back to a centred dialog, which covers the shelf "
            .. "it is configuring")
    end)
end

-- The value pickers share one searchable grid (Editor._searchGrid), always a
-- page of the editor: the ButtonDialog fallbacks went (LibraryModal is ours
-- and always loads, as the folder picker found).
t.test("the filter and source pickers are the shared grid, as pages of the editor", function()
    local body = bodyOf("_pickMultiFilter")
    assert(body:find("Editor._searchGrid{", 1, true), "the filter picker builds its own grid")
    assert(body:find("over     = Editor._over(", 1, true), "the filter picker is not a page of the editor")
    assert(not body:find("Editor._menu{", 1, true), "the ButtonDialog fallback is back")
    local src = io.open("lib/bookshelf_chip_editor.lua"):read("*a")
    local pick = src:match("local function pickById%(.-\n    end\n")
    assert(pick and pick:find("Editor._searchGrid{", 1, true), "the source picker builds its own grid")
end)

t.test("the editor itself anchors above the shelf, like its pickers", function()
    -- The editor opened in the bottom third, on the reasoning that the chip
    -- strip had to stay visible for its Move-left / Move-right chevrons. Every
    -- picker it opens has since moved high, over the hero, and a dialog that
    -- sits somewhere else from the ones it spawns reads as a different kind of
    -- thing (maintainer report). The high anchor leaves the strip visible
    -- anyway -- it clears the hero, which is above the strip.
    local body = bodyOf("editTab")
    assert(body:find("_highAnchor", 1, true),
        "the editor is still placing itself by hand instead of sharing the anchor")
    assert(not body:find("sh %* 2 / 3"),
        "the old bottom-third placement is still there")
end)

t.test("the placement is shared, not copy-pasted per dialog", function()
    -- The anchor carries four separate load-bearing details (prefers_pop_down,
    -- the laid-out width, the un-clamped x, w=dw for RTL). Seven copies of
    -- that drift; one does not.
    local defs = select(2, editor_src:gsub("local function _highAnchor", ""))
    eq(defs, 1, "a second copy of the anchor maths appeared")
    local uses = select(2, editor_src:gsub("_highAnchor%(", ""))
    assert(uses >= 7, "expected every picker to use it, found " .. uses)
end)

-- ── Face out, a page of toggles ────────────────────────────────────────────
-- The real face-out shape helpers, pulled out of the spine shelf (which needs
-- widgets to load).
local function spineFaceHelpers()
    local ss = io.open("lib/bookshelf_spine_shelf.lua"):read("*a")
    local a = ss:find("SpineShelf.FACE_REASONS = ", 1, true)
    local b = ss:find("\nend\n", ss:find("function SpineShelf.faceOutEmpty", a, true), true)
    local chunk = "local SpineShelf = {}\n"
        .. ss:sub(a, b + 4):gsub("function SpineShelf%.faceOutFor.-\nend\n", "")
        .. "\nreturn SpineShelf"
    return assert(load(chunk))()
end

-- Open the page on a host that records it: the spec, and how many times it
-- was laid out again.
local function openFaceOut(draft)
    package.loaded["lib/bookshelf_spine_shelf"] = spineFaceHelpers()
    local spec, refreshed, changes = nil, 0, 0
    Editor._host = { push = function(sp)
        spec = sp
        return { refresh = function() refreshed = refreshed + 1 end }
    end }
    Editor:_openFaceOut(draft, function() changes = changes + 1 end)
    Editor._host = nil
    local function chip(text)
        for _i, b in ipairs(spec.page().blocks) do
            for _j, it in ipairs(b.items or {}) do
                if it.text == text then return it end
            end
        end
        error("no " .. text .. " chip")
    end
    return { spec = spec, chip = chip,
             refreshed = function() return refreshed end,
             changes = function() return changes end }
end

t.test("face out: a tap toggles a reason, saves it and lays the page out in place", function()
    local draft = {}
    local p = openFaceOut(draft)
    eq(p.spec.title, "Face out")
    assert(p.chip("Favorites").on, "Favorites is the default and not shown on")
    p.chip("Reading").callback()
    eq(type(draft.spine_face_out), "table", "two reasons are stored as a set")
    assert(draft.spine_face_out.reading and draft.spine_face_out.favorites)
    eq(p.refreshed(), 1, "the page was not laid out again")
    eq(p.changes(), 1, "the change was not saved")
    p.chip("Favorites").callback()
    eq(draft.spine_face_out, "reading", "one reason is stored as the plain string")
end)

t.test("face out: All and None are the whole-shelf answers", function()
    local draft = { spine_face_out = "reading" }
    local p = openFaceOut(draft)
    p.chip("All books").callback()
    eq(draft.spine_face_out, "all")
    assert(not p.chip("Reading").on, "a reason still shows on under All")
    p.chip("None").callback()
    eq(draft.spine_face_out, false)
    p.chip("Unread").callback()
    eq(draft.spine_face_out, "unread", "a reason picked after None is not stored on its own")
end)

t.test("face out: no tap closes the page", function()
    local body = bodyOf("_openFaceOut")
    assert(not body:find("Editor._closeMenu(", 1, true), "a toggle closes and reopens the page")
    assert(body:find("_highAnchor", 1, true), "not anchored above the shelf")
end)

-- ── Shelf style, a page of controls ────────────────────────────────────────
-- Opened on a host that records the page; each control is driven the way a
-- tap would, and the draft checked.
local function openStyle(draft, chrome, section)
    package.loaded["lib/bookshelf_stack_display"] = {
        pinned = function(v) return v end, FOLLOW_DEFAULT = "default",
        CHIP_OPTIONS = { { value = "default", label_func = function() return "Default setting" end },
                         { value = "ribbon", label_func = function() return "Ribbon" end } },
    }
    package.loaded["lib/bookshelf_theme_pack"] = {
        followOf = function() return nil end, choiceLabel = function() return "Default theme" end,
    }
    package.loaded["lib/bookshelf_book_binding"] = {
        label = function(v) return v == "paperback" and "Paperback" or "Hardback" end,
    }
    package.loaded["lib/bookshelf_ornaments"] = { FREQ_DEFAULT = 1 }
    package.loaded["lib/bookshelf_spine_shelf"] = spineFaceHelpers()
    package.loaded["lib/bookshelf_tab_model"].isShelves = function() return false end
    local spec, changes = nil, 0
    Editor._host = { push = function(sp) spec = sp; return { refresh = function() end } end }
    Editor:_pickGroupDisplay(draft, function() changes = changes + 1 end, chrome)
    -- Under Auto, a level's settings: the page its card opens ("Top level:
    -- Spines"). A shelf with one style has them on the main page.
    if section then
        for _i, b in ipairs(spec.page().blocks) do
            if b.type == "option" and b.text:find(section, 1, true) == 1 then b.callback(); break end
        end
    end
    Editor._host = nil
    local p = {}
    function p.blocks() return spec.page().blocks end
    function p.find(label)
        for _i, b in ipairs(p.blocks()) do
            if b.label == label or b.text == label then return b end
        end
    end
    function p.changes() return changes end
    return p
end

t.test("shelf style: binding and series boxes are independent, applied as picked", function()
    local draft = { view_mode = "spines" }
    local p = openStyle(draft, nil, "Spines")
    p.find("Book binding").on_pick("paperback")
    eq(draft.book_binding, "paperback"); eq(draft.series_boxes, nil)
    p.find("Series boxes").on_pick("cover")
    eq(draft.series_boxes, true); eq(draft.book_binding, "paperback")
    p.find("Book binding").on_pick("hardcover")
    eq(draft.book_binding, nil, "the default binding is stored as absence")
    p.find("Series boxes").on_pick("off")
    eq(draft.series_boxes, nil)
    eq(p.changes(), 4, "a pick was not applied")
end)

t.test("shelf style: series boxes can be Plain, and an old stored value reads as Cover (577)", function()
    local draft = { view_mode = "spines" }
    local p = openStyle(draft, nil, "Spines")
    eq(p.find("Series boxes").active, "off")
    p.find("Series boxes").on_pick("plain")
    eq(draft.series_boxes, "plain")
    eq(openStyle(draft, nil, "Spines").find("Series boxes").active, "plain")
    eq(openStyle({ view_mode = "spines", series_boxes = "slipcase" }, nil, "Spines")
        .find("Series boxes").active, "cover", "a test build's value lost its box")
end)

-- Issue 503: Covers and List group an opened group's series too, with the
-- same stored setting; On keeps a Spines style already chosen.
t.test("shelf style: Covers and List have Series boxes, on or off, the same setting", function()
    for _i, mode in ipairs({ "covers", "list" }) do
        local draft = { view_mode = mode }
        local p = openStyle(draft)
        local row = p.find("Series boxes")
        assert(row, mode .. " has no Series boxes")
        eq(row.active, false)
        row.on_pick(true)
        eq(draft.series_boxes, true)
        eq(openStyle(draft).find("Series boxes").active, true)
        p.find("Series boxes").on_pick(false)
        eq(draft.series_boxes, nil)
        draft.series_boxes = "plain"
        openStyle(draft).find("Series boxes").on_pick(true)
        eq(draft.series_boxes, "plain", mode .. " On lost the Spines page's style")
    end
end)

t.test("shelf style: an Auto level's card says when Covers or List has series boxes", function()
    local draft = { view_mode = "auto", series_boxes = true }
    local descs = {}
    for _i, b in ipairs(openStyle(draft).blocks()) do
        if b.type == "option" and b.desc then descs[#descs + 1] = b.desc end
    end
    assert(#descs == 2, "no level cards")
    for _i, d in ipairs(descs) do
        assert(d:find("series boxes", 1, true), "a level card left series boxes out: " .. d)
    end
end)

t.test("shelf style: series boxes can be Spines, stored as its own value", function()
    local draft = { view_mode = "spines" }
    local p = openStyle(draft, nil, "Spines")
    p.find("Series boxes").on_pick("spines")
    eq(draft.series_boxes, "spines")
    eq(openStyle(draft, nil, "Spines").find("Series boxes").active, "spines")
    p.find("Series boxes").on_pick("cover")
    eq(draft.series_boxes, true)
end)

t.test("shelf style: Book sizes stores only Equal height and Same", function()
    local draft = { view_mode = "spines" }
    local p = openStyle(draft, nil, "Spines")
    eq(p.find("Book sizes").active, "varied")
    local keys = {}
    for i, it in ipairs(p.find("Book sizes").items) do keys[i] = it.key end
    eq(table.concat(keys, " "), "varied height same")
    p.find("Book sizes").on_pick("height")
    eq(draft.spine_same_size, "height")
    eq(openStyle(draft, nil, "Spines").find("Book sizes").active, "height")
    p.find("Book sizes").on_pick("same")
    eq(draft.spine_same_size, true)
    p.find("Book sizes").on_pick("varied")
    eq(draft.spine_same_size, nil)
end)

t.test("shelf style: Author on spine can be turned off and back on (#439)", function()
    local draft = { view_mode = "spines" }
    local p = openStyle(draft, nil, "Spines")
    eq(p.find("Author on spine").active, true, "on by default")
    p.find("Author on spine").on_pick(false)
    eq(draft.spine_show_author, false)
    p.find("Author on spine").on_pick(true)
    eq(draft.spine_show_author, nil)
end)

t.test("shelf style: ornaments step through four stops", function()
    local draft = { view_mode = "spines" }
    local p = openStyle(draft, nil, "Spines")
    eq(#p.find("Ornaments").items, 4)
    p.find("Ornaments").on_pick(1)
    eq(draft.ornament_frequency, 0)
end)

t.test("shelf style: a plank for card shelves only", function()
    assert(not openStyle({ view_mode = "spines" }, nil, "Spines").find("Plank"), "a main shelf was offered a plank")
    assert(openStyle({ view_mode = "spines", card_only = true }, nil, "Spines").find("Plank"),
        "no Plank row for a card shelf")
end)

-- One style: its settings on the View mode page itself. Auto: a card per
-- level, named for the level and its style, even when both levels show the
-- same style (maintainer).
local function optionTexts(p)
    local seen = {}
    for _i, b in ipairs(p.blocks()) do
        if b.type == "option" then seen[#seen + 1] = b.text:gsub(" \xE2\x80\xBA$", "") end
    end
    return table.concat(seen, ",")
end

t.test("shelf style: one style's settings are on the page, with no cards", function()
    local p = openStyle({ view_mode = "spines" })
    eq(optionTexts(p), "")
    assert(p.find("Book binding"), "spines settings are not on the page")
    assert(openStyle({}).find("Cover captions"), "covers settings are not on the page")
    assert(openStyle({ view_mode = "list" }).find("Columns"), "list settings are not on the page")
end)

t.test("shelf style: Auto has a card per level, even for the same style", function()
    eq(optionTexts(openStyle({ view_mode = "auto", view_level1 = "spines", view_level2 = "covers" })),
        "Top level: Spines,Inside folders and stacks: Covers")
    eq(optionTexts(openStyle({ view_mode = "auto", view_level1 = "covers", view_level2 = "covers" })),
        "Top level: Covers,Inside folders and stacks: Covers")
    local p = openStyle({ view_mode = "auto", view_level1 = "spines", view_level2 = "covers" }, nil, "Top level")
    assert(p.find("Book binding") and not p.find("Cover captions"), "the card's page is not its level's style")
    local opds = openStyle({ view_mode = "auto", view_level1 = "spines" }, { is_opds = true })
    assert(not optionTexts(opds):find("Spines", 1, true), "a catalogue was offered spines")
end)

t.test("shelf style: under Auto, each listing level's card has its own numbers", function()
    local draft = { view_mode = "auto", view_level1 = "list", view_level2 = "list", list_rows = 6 }
    local top = openStyle(draft, nil, "Top level")
    assert(top.find("Columns") and not top.find("Inside folders and stacks"))
    local inside = openStyle(draft, nil, "Inside folders and stacks")
    eq(inside.find("Rows").value, "6", "an unset Level 2 number does not show Level 1's")
    inside.find("Rows").on_inc()
    eq(draft.list_rows_l2, 7); eq(draft.list_rows, 6)
end)

t.test("the editor's no-spines flag comes from the source's own answer (588)", function()
    local src = io.open("lib/bookshelf_chip_editor.lua"):read("*a")
    assert(src:find("is_opds = is_opds_src or no_spines_src,", 1, true),
        "the editor withholds Spines from every fetch-mode source")
    assert(src:find("and not Sources.spinesOk(draft.source.kind)", 1, true),
        "the editor does not ask the source whether it can stand as spines")
end)

t.test("shelf style: a spines shelf whose source became a catalogue shows covers", function()
    -- A catalogue has no spines; the shelf draws covers. The page showed Show
    -- as with nothing picked, and the editor's card still said Spines.
    local draft = { view_mode = "spines" }
    local p = openStyle(draft, { is_opds = true })
    eq(p.find("Show as").active, "covers")
    eq(draft.view_mode, "spines", "the pin is kept for a source that can show it")
    eq(Editor._chipModeLabel(Editor._shownMode("spines", true)), nil)
    eq(Editor._chipModeLabel(Editor._shownMode("spines", false)), "Spines")
    local auto = openStyle({ view_mode = "auto", view_level1 = "spines" }, { is_opds = true })
    eq(auto.find("Top level").active, "covers")
end)

-- ── Catalog settings and the folder filter, as pages ───────────────────────
local function openPage(fn)
    local spec, refreshed = nil, 0
    Editor._host = { push = function(sp) spec = sp; return { refresh = function() refreshed = refreshed + 1 end } end }
    fn()
    Editor._host = nil
    return spec, function() return refreshed end
end

t.test("catalog settings: the refresh in force is marked, a tap sets it in place", function()
    package.loaded["lib/bookshelf_opds_prefs"] = { REFRESH_OPTIONS = {
        { value = 0, label_func = function() return "Only when I swipe down" end },
        { value = 3600, label_func = function() return "If it's over an hour old" end } } }
    package.loaded["lib/bookshelf_folder_picker"] = {}
    local draft, closes = { source = { kind = "opds", id = "k1", feed_url = "u", feed_label = "Fiction" } }, 0
    local spec, refreshed = openPage(function() Editor:_openCatalogSettings(draft, function() closes = closes + 1 end) end)
    eq(spec.title, "Catalog settings")
    local function find(text)
        for _i, b in ipairs(spec.page().blocks) do if b.text == text then return b end end
    end
    assert(find("Only when I swipe down").on, "unset does not mark what the catalog does")
    find("If it's over an hour old").callback()
    eq(draft.opds_refresh_age, 3600); eq(closes, 1); eq(refreshed(), 1)
    local start = find("Fiction")
    assert(start and start.links, "the start folder has no way back to the top")
    start.links[1].callback()
    eq(draft.source.feed_url, nil); eq(draft.source.feed_label, nil)
    assert(find("The top of the catalog"), "the page does not say it starts at the top")
end)

t.test("folder filter: each folder has a cross, and both lists can be added to", function()
    package.loaded["ui/widget/pathchooser"] = {}
    local draft, closes = { filter = { folders = { include = { ["/a/Fiction"] = true }, exclude = {} } } }, 0
    local spec = openPage(function() Editor:_pickFolderFilter(draft, function() closes = closes + 1 end) end)
    local blocks = spec.page().blocks
    local row, adds = nil, 0
    for _i, b in ipairs(blocks) do
        if b.type == "row" and b.label == "/a/Fiction" then row = b end
        if b.type == "chips" then adds = adds + 1 end
    end
    assert(row and row.on_clear, "an included folder cannot be dropped")
    eq(adds, 2, "not a way to add to each list")
    row.on_clear()
    eq(draft.filter.folders.include["/a/Fiction"], nil); eq(closes, 1)
end)

-- A drag refreshes the window's box as MovableContainer recorded it, at
-- first paint: a taller page (Sort, a pager at its foot) left that foot
-- behind on e-ink (maintainer, PW5, landscape). The box follows each page,
-- and the shell is not centred on it, which would move the window.
t.test("the editor window's box follows the page, and the page doesn't move it", function()
    local src = assert(io.open("lib/bookshelf_chip_editor.lua")):read("*a")
    assert(src:find("mv.dimen.w, mv.dimen.h = size.w, size.h", 1, true),
        "the movable keeps its first size")
    local shell = src:match("dialog%[1%] = WidgetContainer:new(%b{})")
    assert(shell, "no editor shell")
    assert(not shell:find("align", 1, true), "the shell centres the window on its size")
end)

-- The editor's Source card shows the source's own icon, the one its option
-- or chip has on the Source page (maintainer: "a star for ratings").
t.test("the Source card's icon is the source's own", function()
    eq(Editor._sourceIcon({ kind = "ratings" }), "\u{EBCD}", "ratings: star")
    eq(Editor._sourceIcon({ kind = "rating" }), "\u{EBCD}", "one rating: star")
    eq(Editor._sourceIcon({ kind = "series" }), "\u{E97A}")
    eq(Editor._sourceIcon({ kind = "folder_flat" }), "\u{E94A}")
    eq(Editor._sourceIcon({ kind = "all" }), "\u{E952}")
    eq(Editor._sourceIcon({ kind = "something_registered" }), "\u{EA31}", "fallback: library")
    eq(Editor._sourceIcon(nil), "\u{EA31}")
end)

-- KOReader only hands events to the top window, so with the shelf editor
-- up the menu tap and brightness swipes were dead (maintainer, PW5). A
-- gesture outside it goes to KOReader's zones first, and KOReader's actions
-- are passed on, as the book popup does.
t.test("the shelf editor passes KOReader's gestures and actions on", function()
    local src = assert(io.open("lib/bookshelf_chip_editor.lua")):read("*a")
    local tap = src:match("dialog%.onTapClose = function.-\n    end\n")
    assert(tap and tap:find("GestureZones.tryLiveZones(ges_ev)", 1, true),
        "a tap outside closes the editor before KOReader's zones get it")
    local he = src:match("function dialog:handleEvent%(event%).-\n    end\n")
    assert(he, "the editor's window keeps every event")
    assert(he:find("GestureZones.overlayEvent", 1, true), "gestures outside are dropped")
end)

t.test("Move to says why when there is nowhere to move", function()
    -- A fresh install has no shelf of shelves; a greyed button said nothing.
    local ed = io.open("lib/bookshelf_chip_editor.lua"):read("*a")
    local i = ed:find('text         = _("Move to\\xE2\\x80\\xA6")', 1, true)
    assert(i, "the Move to button moved")
    local body = ed:sub(i, i + 900)
    assert(not body:find("hasSource() and canMove()", 1, true), "Move to is greyed again when there is nowhere to go")
    assert(body:find("if canMove() then return moveShelf() end", 1, true), "a tap no longer moves when it can")
    assert(body:find("Shelf of shelves", 1, true), "no hint about how to make somewhere to move to")
end)

t.done()
