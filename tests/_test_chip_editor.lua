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
    series_name = true, series_index = true, series_combined = true,
    last_opened = true, date_added = true, percent_read = true,
    read_status = true, read_status_active = true, rating = true,
    page_count = true, book_count = true, size = true,
    collection_order = true,
}

t.test("every SOURCE_SORT_DEFAULTS entry is a non-empty list of {key,reverse}, except fixed-order sources", function()
    -- "opds" is the one deliberate exception: the feed order is fixed
    -- (server-defined), so its defaults are an empty list -- see the
    -- "no sort levels" test below.
    local FIXED_ORDER_KINDS = { opds = true }
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
        Editor:_pickSortLevel({ source = { kind = kind }, sort_priority = {} },
                              1, function() end)
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
        for _i, row in ipairs(shown_buttons) do
            local text = row[1].text
            if text:find("\xE2\x97\x8F", 1, true) then return text end
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
    "_pickMultiFilter", "_pickFolderFilter", "_pickSortLevel",
}) do
    t.test(name .. " anchors its dialog above the shelf", function()
        local body = bodyOf(name)
        assert(body:find("ButtonDialog:new", 1, true), "no dialog in " .. name)
        assert(body:find("_highAnchor", 1, true),
            name .. " went back to a centred dialog, which covers the shelf "
            .. "it is configuring")
    end)
end

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

t.test("the face-out chooser says what it is choosing between", function()
    -- Five bare labels with no heading: once the row that named the setting
    -- has closed behind them, "Favorites" / "First in series" could be
    -- choosing anything.
    local body = bodyOf("_pickGroupDisplay")
    local sub = body:match("sub = ButtonDialog:new{(.-)\n%s+}")
    assert(sub, "the face-out sub-dialog moved or was renamed")
    assert(sub:find('title%s*=%s*_%("Face out"%)'), "no heading")
    assert(sub:find("_helpParagraph", 1, true), "no explanatory line")
    assert(sub:find("_highAnchor", 1, true), "not anchored above the shelf")
end)

t.test("the help paragraph is shared too", function()
    local defs = select(2, editor_src:gsub("local function _helpParagraph", ""))
    eq(defs, 1)
    -- Filters had the only copy of this width arithmetic; it now has a caller.
    local uses = select(2, editor_src:gsub("_helpParagraph%(", ""))
    assert(uses >= 2, "expected at least Filters and Face out, found " .. uses)
end)

t.done()
