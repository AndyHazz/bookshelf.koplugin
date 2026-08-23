-- tests/_test_list_view_gesture.lua
-- The WIDGET side of the view-mode model, driven against its real method
-- bodies: BookshelfWidget:_viewMode(), :_flipViewMode() and the file-scope
-- _asCoverGrid() pin.
--
-- tests/_test_view_mode.lua proves the resolver. It cannot prove that the
-- widget asks it the right question, or that the long-press writes the key
-- matching the state the shelf is in -- and that independence is the entire
-- point of having two settings instead of one. So the bodies are extracted by
-- name and run under stubs, the same way _test_list_row_budget drives the
-- density accessors.
--
-- Usage (from plugin root): lua tests/_test_list_view_gesture.lua

package.path = "./?.lua;./?/init.lua;" .. package.path

local helpers = dofile("tests/_helpers.lua")
local t  = helpers.runner()
local eq = helpers.eq

local ViewMode = require("lib/bookshelf_view_mode")

local src = io.open("lib/bookshelf_widget.lua"):read("*a")

-- The per-chip view-mode pin lives on the tab as ViewMode.CHIP_KEY and is
-- resolved by ViewMode.chipOverride -- both from the real module, which this
-- suite already loads (it is a pure resolver with no dependencies).

local function compile(code, env, chunkname)
    if _G.setfenv then
        local f = assert(_G.loadstring(code, chunkname))
        _G.setfenv(f, env)
        return f
    end
    return assert(load(code, chunkname, "t", env))
end

-- A no-argument method, as a function of self.
local function methodOf(name, env)
    local body = src:match("\nfunction BookshelfWidget:" .. name
        .. "%(%)\n(.-)\nend\n")
    assert(body, "could not find BookshelfWidget:" .. name .. "() - renamed?")
    return compile("return function(self)\n" .. body .. "\nend", env, name)()
end

-- ── _viewMode: chip pin, else the Auto policy ─────────────────────────────

local settings_reads = 0
local function viewMode(opts)
    settings_reads = 0
    local env = {
        ViewMode = ViewMode,
        _covers_pin = opts.pin or 0,
        -- The ONE settings key the resolver may read is the search view --
        -- and only on the search branch (asserted per test below). Any other
        -- key is the old three-global model growing back.
        BookshelfSettings = {
            read = function(k)
                assert(k == "search_view_mode",
                    "_viewMode read an unexpected settings key: " .. tostring(k))
                settings_reads = settings_reads + 1
                return opts.search_mode
            end,
        },
    }
    return methodOf("_viewMode", env)({
        _expanded         = opts.expanded,
        _isDrilledIn      = function() return opts.in_folder == true end,
        _isSearchResults  = function() return opts.in_search == true end,
        _chipViewMode     = function()
            return ViewMode.chipOverride(opts.chip_mode)
        end,
    })
end

t.test("UNSET is covers everywhere: the pre-list-view shelf", function()
    -- The maintainer's reversal: a chip that never touched Show as must look
    -- exactly as it did before list view existed -- no opting anyone into
    -- Auto. And the default path must read no settings at all.
    assert(viewMode{ expanded = false } == "covers")
    assert(viewMode{ expanded = true } == "covers")
    assert(viewMode{ expanded = false, in_folder = true } == "covers")
    assert(viewMode{ expanded = true,  in_folder = true } == "covers")
    assert(settings_reads == 0, "the chip path must not read settings")
end)

t.test("a chip set to Auto gets the policy: covers collapsed, list expanded or drilled",
function()
    -- The policy the maintainer named: "auto: list when expanded or lists
    -- inside folders". Nothing configurable inside it -- but it must now be
    -- CHOSEN, stored on the chip like the other two modes.
    local M = ViewMode.AUTO
    assert(viewMode{ expanded = false, chip_mode = M } == "covers")
    assert(viewMode{ expanded = true, chip_mode = M } == "list")
    assert(viewMode{ expanded = false, in_folder = true, chip_mode = M } == "list")
    assert(viewMode{ expanded = true,  in_folder = true, chip_mode = M } == "list")
end)

t.test("search results have their own mode, covers by default", function()
    -- Decoupled from every chip, like their content: the active chip's pin
    -- must not leak into the results page.
    assert(viewMode{ in_search = true } == "covers")
    assert(viewMode{ in_search = true, expanded = true } == "covers")
    assert(viewMode{ in_search = true, chip_mode = ViewMode.LIST } == "covers",
        "a chip pinned to List must not restyle the search results")
    assert(viewMode{ in_search = true, search_mode = "list" } == "list")
    assert(viewMode{ in_search = true, search_mode = "auto" } == "list",
        "auto search results are a drill, so they list")
    assert(viewMode{ in_search = true, search_mode = "nonsense" } == "covers",
        "an unrecognised stored mode degrades to the covers default")
end)

t.test("a chip pinned to List is a list wherever you are in it", function()
    assert(viewMode{ expanded = false, chip_mode = ViewMode.LIST } == "list")
    assert(viewMode{ expanded = true,  chip_mode = ViewMode.LIST } == "list")
    assert(viewMode{ expanded = false, in_folder = true,
                     chip_mode = ViewMode.LIST } == "list")
end)

t.test("a chip pinned to Covers beats the Auto policy everywhere", function()
    assert(viewMode{ expanded = false, chip_mode = ViewMode.COVERS } == "covers")
    assert(viewMode{ expanded = true, chip_mode = ViewMode.COVERS } == "covers")
    assert(viewMode{ expanded = true, in_folder = true,
                     chip_mode = ViewMode.COVERS } == "covers")
end)

t.test("an unset or unrecognised pin falls through to the covers default",
function()
    -- A value from a later release, or a hand-edited chip, must degrade to
    -- the default rather than reach a renderer as a mode it has no branch for.
    for _i, v in ipairs({ "default", "grid", "", "list-view", 7 }) do
        assert(viewMode{ expanded = false, chip_mode = v } == "covers",
            "unrecognised pin was honoured: " .. tostring(v))
        assert(viewMode{ expanded = true, chip_mode = v } == "covers",
            "unrecognised pin must degrade to covers: " .. tostring(v))
    end
end)

t.test("the covers pin still beats a chip pinned to List", function()
    -- _asCoverGrid asks "what would the cover grid do here", and a chip pin
    -- that outranked it would let a geometry probe answer with list rows and
    -- resize the grid the user comes back to.
    assert(viewMode{ expanded = false, pin = 1,
                     chip_mode = ViewMode.LIST } == "covers")
end)

t.test("a drill is any drill, not only a filesystem folder", function()
    -- _isDrilledIn is depth, not kind: a series, author, genre or tag drill
    -- puts the user in the same "inside one thing" place the policy is about.
    -- The widget hands _viewMode a boolean, so this pins only that the
    -- boolean is consulted on the Auto branch; what counts as a drill is
    -- _isDrilledIn's own suite's business.
    assert(viewMode{ expanded = false, in_folder = true,
                     chip_mode = ViewMode.AUTO } == "list")
end)

-- ── _asCoverGrid: a depth counter, restored on the way out ─────────────────

local function coverPin()
    local body = src:match("\nlocal function _asCoverGrid%(fn%)\n(.-)\nend\n")
    assert(body, "could not find _asCoverGrid - renamed?")
    local env = { _covers_pin = 0, pcall = pcall }
    local f = compile("return function(fn)\n" .. body .. "\nend",
        env, "_asCoverGrid")()
    return f, env
end

t.test("_asCoverGrid arms the pin and drops it again", function()
    local f, env = coverPin()
    assert(env._covers_pin == 0, "the pin does not start clear")
    local inside = f(function() return env._covers_pin end)
    assert(inside == 1, "the pin was not armed inside fn, saw " .. tostring(inside))
    assert(env._covers_pin == 0, "the pin survived the call")
end)

t.test("_asCoverGrid drops the pin when fn throws", function()
    -- The old implementation restored a saved override, and this was the case
    -- it used pcall for. A counter that leaked on an error would pin the whole
    -- shelf to cover mode for the rest of the session.
    local f, env = coverPin()
    local out = f(function() error("boom") end)
    assert(out == nil, "a throwing fn must degrade to nil, got " .. tostring(out))
    assert(env._covers_pin == 0, "the pin leaked after an error")
end)

t.test("_asCoverGrid nests", function()
    -- Why a counter rather than a boolean: an inner ask must not drop the
    -- outer caller's pin on its way out.
    local f, env = coverPin()
    local depths = {}
    f(function()
        depths[#depths + 1] = env._covers_pin
        f(function() depths[#depths + 1] = env._covers_pin end)
        depths[#depths + 1] = env._covers_pin
    end)
    assert(depths[1] == 1 and depths[2] == 2 and depths[3] == 1,
        "nesting depths were " .. table.concat(depths, ","))
    assert(env._covers_pin == 0)
end)

-- ── _flipViewMode: the long-press pins THIS CHIP ──────────────────────────
--
-- It used to write one of three shelf-wide booleans and carry a notification
-- to explain the cases where a chip pin outranked the write. The globals are
-- gone: the gesture writes the same per-chip pin the Shelf style dialog
-- writes, so it is always effective and the explanations went with them.

local function flip(opts)
    local saved, rebuilt, notices = nil, 0, {}
    local tabs = opts.tabs or { { id = "home" } }
    local env = {
        ViewMode = ViewMode,
        ipairs   = ipairs,
        logger   = { dbg = function() end },
        UIManager = {
            setDirty = function() end,
            show     = function(_self, w) notices[#notices + 1] = w.text end,
        },
        require = function(name)
            if name == "lib/bookshelf_tab_model" then
                return {
                    load = function() return tabs end,
                    save = function(t) saved = t end,
                }
            end
            return { new = function(_s, t) return t end }
        end,
        _ = function(str) return str end,
        tostring = tostring,
        _itemFilepath = function() return nil end,
    }
    local pickers = 0
    local search_writes = {}
    env.BookshelfSettings = {
        save = function(k, v)
            assert(k == "search_view_mode", "unexpected save: " .. tostring(k))
            search_writes[#search_writes + 1] = v == nil and "__nil__" or v
        end,
        flush = function() end,
    }
    local self = {
        chip = opts.chip or "home",
        _drilldown_path = opts.drill,
        _expanded = false,
        _markOpdsNav = function() end,
        _rebuild = function(s2) rebuilt = rebuilt + 1 end,
        _setCursorToShow = function() end,
        _globalIndexOfFilepath = function() return nil end,
        _isListMode = function() return opts.is_list == true end,
        _isSearchResults = function(s2)
            local tip = s2._drilldown_path
                        and s2._drilldown_path[#s2._drilldown_path]
            return tip ~= nil and tip.kind == "search"
        end,
        _showSearchViewModePicker = function() pickers = pickers + 1 end,
    }
    methodOf("_flipViewMode", env)(self)
    return tabs, saved, rebuilt, notices, pickers, search_writes
end

t.test("the hold pins the current chip to the OTHER mode", function()
    local tabs, saved, rebuilt = flip{ chip = "home", is_list = false }
    assert(saved ~= nil, "the pin must be persisted through TabModel.save")
    eq(tabs[1][ViewMode.CHIP_KEY], ViewMode.LIST,
        "covers on screen: the hold pins List")
    assert(rebuilt == 1, "the flip must force a full rebuild, not the fast path")

    local tabs2 = { { id = "home", [ViewMode.CHIP_KEY] = ViewMode.LIST } }
    flip{ chip = "home", is_list = true, tabs = tabs2 }
    eq(tabs2[1][ViewMode.CHIP_KEY], ViewMode.COVERS,
        "list on screen: the hold pins Covers")
end)

t.test("the hold writes THIS chip and leaves the others alone", function()
    local tabs = { { id = "home" }, { id = "recent" } }
    flip{ chip = "recent", is_list = false, tabs = tabs }
    eq(tabs[1][ViewMode.CHIP_KEY], nil)
    eq(tabs[2][ViewMode.CHIP_KEY], ViewMode.LIST)
end)

t.test("in a search drill the hold toggles the SEARCH mode, writes no pin",
function()
    -- Chip pins are deliberately not consulted in a search, so a silent write
    -- would be invisible now and a surprise later, on the chip's own shelf.
    -- The gesture toggles search_view_mode instead - the maintainer's ruling:
    -- "that should just toggle between cover and list mode like it does
    -- elsewhere". The three-way picker lives on the pill's long-press.
    local tabs, saved, rebuilt, notices, pickers, search_writes = flip{
        chip = "home", is_list = false,
        drill = { { kind = "search" } },
    }
    assert(saved == nil, "a search hold must not write a pin")
    eq(pickers, 0, "the footer hold must not open the picker")
    eq(search_writes[1], "list", "covers on screen: the hold flips to list")
    eq(rebuilt, 1, "the flip must rebuild")

    local _t2, _s2, _r2, _n2, _p2, writes2 = flip{
        chip = "home", is_list = true,
        drill = { { kind = "search" } },
    }
    -- Covers is stored as absence, like a chip pin's default.
    eq(writes2[1], "__nil__", "list on screen: the hold flips back to covers")
end)

-- ── _listCols: the count, clamped to what fits ─────────────────────────────
--
-- A method WITH arguments, so it needs the general form of the extractor.

local function methodWithArgs(name, env)
    local args, body = src:match("\nfunction BookshelfWidget:" .. name
        .. "%((.-)%)\n(.-)\nend\n")
    assert(body, "could not find BookshelfWidget:" .. name .. " - renamed?")
    local sig = "self" .. (args ~= "" and (", " .. args) or "")
    return compile("return function(" .. sig .. ")\n" .. body .. "\nend",
        env, name)()
end

-- The two constants are read OUT of the source rather than restated, so the
-- expectations below cannot quietly disagree with the shipped values.
local LIST_COLUMNS_MAX = tonumber(src:match("\nlocal LIST_COLUMNS_MAX%s*=%s*(%d+)"))
local LIST_MIN_COL_DP  = tonumber(src:match("\nlocal LIST_MIN_COL_DP%s*=%s*(%d+)"))
assert(LIST_COLUMNS_MAX and LIST_MIN_COL_DP, "column constants renamed?")

-- content_w in device pixels, and a scaleBySize that is the identity so the
-- minimum column width in the source is directly comparable to it.
-- _chipListValue, driven from its OWN source rather than faked, because the
-- precedence it encodes -- this chip's own override, then the library key --
-- is the part worth testing and a stub would assert my assumptions back at
-- me. The preset layer that used to sit between them went with the preset
-- feature.
local function chipValue(self_tbl, chip_own, default)
    local env = {
        require = function(name)
            assert(name == "lib/bookshelf_tab_model", "unexpected require: " .. name)
            return { getById = function() return chip_own end }
        end,
        BookshelfSettings = { read = function() return default end },
        type = type,
    }
    local f = methodWithArgs("_chipListValue", env)
    return f(self_tbl, "list_columns")
end

local function listCols(setting, content_w, chip_own)
    local env = {
        Screen = { scaleBySize = function(_self, n) return n end },
        LIST_COLUMNS_MAX = LIST_COLUMNS_MAX,
        LIST_MIN_COL_DP  = LIST_MIN_COL_DP,
        math = math, type = type,
    }
    local f = methodWithArgs("_listCols", env)
    local self_tbl
    self_tbl = {
        _layoutPrimitives = function() return 20, content_w, 0, 0 end,
        _chipListValue    = function(_s, key)
            return chipValue(self_tbl, chip_own, setting)
        end,
    }
    return f(self_tbl)
end

t.test("the chip's own count beats the library default", function()
    local self_tbl = { }
    eq(chipValue(self_tbl, { list_columns = 3 }, 1), 3)
    eq(chipValue(self_tbl, { }, 1), 1)
    eq(chipValue(self_tbl, nil, nil), nil)
end)

-- The same accessor with a chip pinned to a preset: the preset's column count
-- replaces the setting, and then meets the identical ceiling and width clamp.
-- A chip with its own count. Goes through the same _chipListValue the live
-- code does, so the precedence and the clamps are tested together rather
-- than one of them being assumed.
local function pinnedCols(own_cols, setting, content_w)
    return listCols(setting, content_w, { list_columns = own_cols })
end

t.test("an unset or nonsense column count is one", function()
    assert(listCols(nil, 1248) == 1)
    assert(listCols("two", 1248) == 1)
    assert(listCols(0, 1248) == 1)
    assert(listCols(-3, 1248) == 1)
end)

t.test("the count is clamped to what the width can actually hold", function()
    -- Widths are DERIVED from the minimum rather than typed, so tuning the
    -- constant retunes the test with it. The stub's gap is 20.
    local GAP = 20
    local function widthFor(cols) return cols * LIST_MIN_COL_DP + (cols - 1) * GAP end
    -- Exactly enough room for n columns gets n; one pixel short gets n-1. A
    -- narrow screen must come back to something usable rather than render
    -- slivers.
    for want = 2, LIST_COLUMNS_MAX do
        local exact = widthFor(want)
        assert(listCols(want, exact) == want,
            string.format("%d columns did not fit in %dpx", want, exact))
        assert(listCols(want, exact - 1) == want - 1,
            string.format("%d columns squeezed into %dpx", want, exact - 1))
    end
    -- A PW5's content width, which is what the setting is offered on: all
    -- three have to be reachable there, or the option reads as broken.
    assert(listCols(3, 1174) == 3, "three columns must fit a PW5")
end)

t.test("the ceiling holds however large the saved value is", function()
    -- A hand-edited settings file, or a later release with a bigger maximum.
    assert(listCols(99, 100000) == LIST_COLUMNS_MAX)
end)

-- ── _listRowFilled: what decides the hairline ──────────────────────────────

t.test("a row is filled when its FIRST slot is", function()
    local function filled(items, r, cols)
        local env = { }
        local f = methodWithArgs("_listRowFilled", env)
        return f({ _listCols = function() return cols end }, items, r)
    end
    local three = { "a", "b", "c" }
    -- One column: row r is item r.
    assert(filled(three, 3, 1) == true)
    assert(filled(three, 4, 1) == false)
    -- Two columns: three items fill rows 1 and 2 (the second raggedly), and
    -- row 2 must still carry a rule above it.
    assert(filled(three, 2, 2) == true)
    assert(filled(three, 3, 2) == false)
    assert(filled(nil, 1, 2) == false)
end)

t.test("the retired override is not written from the widget either", function()
    -- A leftover setOverride call would compile fine (it would be a nil index
    -- on the ViewMode table) and only fail when someone held the page label.
    assert(not src:match("ViewMode%.setOverride"),
        "bookshelf_widget.lua still calls ViewMode.setOverride")
    assert(not src:match("ViewMode%.clearOverride"),
        "bookshelf_widget.lua still calls ViewMode.clearOverride")
    assert(not src:match("ViewMode%.override"),
        "bookshelf_widget.lua still reads ViewMode.override")
end)

t.test("a chip's own count supplies the columns, under the same clamps",
function()
    local wide = 10000   -- wide enough that the width clamp never bites
    -- The chip wins over the library key...
    eq(pinnedCols(2, 1, wide), 2)
    eq(pinnedCols(1, 3, wide), 1)
    -- ...an unset chip falls back to it...
    eq(pinnedCols(nil, 3, wide), 3)
    -- ...and the chip's number is not privileged: same ceiling, same "does it
    -- actually fit" clamp as any other.
    eq(pinnedCols(99, 1, wide), LIST_COLUMNS_MAX)
    eq(pinnedCols(3, 1, LIST_MIN_COL_DP + 10), 1)
end)

-- ── The OPDS start folder ──────────────────────────────────────────────────
--
-- Which feed a catalogue chip OPENS on. No new setting: tab.source.feed_url
-- has always meant this and has always been resolved as
-- `tab.source.feed_url or server.url`; what was missing was any way to set it.
-- So what these pin is the read, the write, and the fact that clearing it is
-- the way back to the top.

local function startFeed(tab)
    local env = { require = function(mod)
        assert(mod == "lib/bookshelf_tab_model", "unexpected module: " .. mod)
        return { getById = function() return tab end }
    end }
    return methodWithArgs("_opdsStartFeed", env)({ chip = "cat" }, tab)
end

t.test("the start feed is read off the chip's own source", function()
    local url, label = startFeed{ id = "cat", source = {
        kind = "opds", id = "srv", feed_url = "http://x/sub", feed_label = "Sci-fi" } }
    eq(url, "http://x/sub")
    eq(label, "Sci-fi")
    -- Absent means the server root, which is what every consumer already
    -- resolves it to. nil, not "" -- a chip that has never been pointed
    -- anywhere must be indistinguishable from one that was reset.
    eq(startFeed{ id = "cat", source = { kind = "opds", id = "srv" } }, nil)
end)

t.test("a non-catalogue chip has no start feed at all", function()
    -- The gesture and the menu are both reachable from any chip; asking a
    -- local shelf where it starts has to answer nothing rather than reaching
    -- into a source that has no feed.
    eq(startFeed{ id = "home", source = { kind = "all" } }, nil)
    eq(startFeed{ id = "home" }, nil)
    eq(startFeed(nil), nil)
end)

local function setFeed(tab, url, label)
    local saved, selected
    local env = { ipairs = ipairs, require = function(mod)
        assert(mod == "lib/bookshelf_tab_model", "unexpected module: " .. mod)
        return {
            load = function() return { tab } end,
            save = function(t) saved = t end,
        }
    end }
    local self = { chip = "cat",
                   _selectChip = function(_s, key) selected = key end }
    local ok = methodWithArgs("_setOpdsStartFeed", env)(self, url, label)
    return ok, saved, selected
end

t.test("setting the start feed writes the tab and re-selects the chip",
function()
    local tab = { id = "cat", source = { kind = "opds", id = "srv" } }
    local ok, saved, selected = setFeed(tab, "http://x/sub", "Sci-fi")
    assert(ok)
    eq(saved[1].source.feed_url, "http://x/sub")
    eq(saved[1].source.feed_label, "Sci-fi")
    -- Re-SELECTED, not just rebuilt: the drilldown was reached from the old
    -- root and may sit above the new one, the cursor has to go back to the
    -- first item, and the fetch gate has to be armed because this is the first
    -- render of a feed the chip has never shown.
    eq(selected, "cat")
end)

t.test("clearing drops the label with the url", function()
    local tab = { id = "cat", source = { kind = "opds", id = "srv",
                                         feed_url = "http://x/sub",
                                         feed_label = "Sci-fi" } }
    local ok, saved = setFeed(tab, nil, nil)
    assert(ok)
    eq(saved[1].source.feed_url, nil)
    -- A label left behind would have the settings row naming a folder the chip
    -- no longer starts at.
    eq(saved[1].source.feed_label, nil)
end)

t.test("a label without a url is never stored", function()
    -- The two travel together: _setOpdsStartFeed is also the clear, and a
    -- caller that passed a label with no url would leave the row lying.
    local tab = { id = "cat", source = { kind = "opds", id = "srv" } }
    local _ok, saved = setFeed(tab, nil, "Sci-fi")
    eq(saved[1].source.feed_label, nil)
end)

t.test("a chip that is not this chip is never written", function()
    local other = { id = "elsewhere", source = { kind = "opds", id = "srv" } }
    local ok, saved, selected = setFeed(other, "http://x/sub", "Sci-fi")
    assert(not ok, "a chip with no matching id must report failure")
    eq(saved, nil, "nothing should be saved")
    eq(selected, nil, "and the shelf should not be re-selected")
end)

-- ── The rule between rows, and what suppresses a segment ───────────────────

-- ListGroup, stubbed rather than loaded: the real module pulls in a widget
-- stack this suite has no business standing up, and what is under test here is
-- whether _listDividerOpts ASKS it -- a stub that answers the wrong thing
-- would show up as a wrong skip set. Which items answer true is
-- ListGroup.fillsRow's own business and is pinned in tests/_test_list_group.
local ListGroupStub = {
    fillsRow = function(item)
        return type(item) == "table" and item.kind == "opds_nav"
    end,
}

local function dividerOpts(items, r, opts)
    opts = opts or {}
    local env = {
        ipairs = ipairs,
        require = function(mod)
            assert(mod == "lib/bookshelf_list_group",
                   "unexpected module: " .. mod)
            return ListGroupStub
        end,
        _itemFilepath = function(it) return it and it.filepath or nil end,
    }
    local self = {
        _listCols            = function() return opts.cols or 1 end,
        _listRowColumnGap    = function() return 12 end,
        _selectedFilepath    = function() return opts.selected end,
    }
    return methodWithArgs("_listDividerOpts", env)(self, items, r)
end

local function book(fp)  return { filepath = fp } end
local function nav(fp)   return { kind = "opds_nav", filepath = fp } end

t.test("no selection and no buttons means no skipped segments", function()
    local o = dividerOpts({ book("/a"), book("/b") }, 1)
    eq(o.n_cols, 1)
    eq(o.skip, nil, "nothing on this page has an edge of its own")
end)

t.test("a button row suppresses the rule on both of its sides", function()
    -- "get rid of the hairline borders between cells when the folder button
    -- style is used". The card is bordered, so a hairline hard against it is a
    -- second line doing the first one's job.
    local items = { book("/a"), nav("/n"), book("/c") }
    -- Rule 1 sits between row 1 (a book) and row 2 (the button).
    eq(dividerOpts(items, 1).skip[1], true)
    -- Rule 2 sits between the button and row 3.
    eq(dividerOpts(items, 2).skip[1], true)
    -- Rule 3 is below row 3 and above nothing: no button either side.
    eq(dividerOpts(items, 3).skip, nil)
end)

t.test("only the button's OWN column loses its segment", function()
    -- Two columns: a button on the left and an ordinary book on the right must
    -- leave the right-hand rule intact, or one catalogue entry erases the rule
    -- under the book beside it.
    local items = { nav("/n"), book("/b"), book("/c"), book("/d") }
    local o = dividerOpts(items, 1, { cols = 2 })
    eq(o.skip[1], true)
    eq(o.skip[2], nil)
end)

t.test("the selection skip still works, and does not fire on a nil path",
function()
    local items = { book("/a"), book("/b") }
    eq(dividerOpts(items, 1, { selected = "/a" }).skip[1], true)
    -- THE NIL TRAP. With no selection _selectedFilepath is nil, and so is the
    -- filepath of an item that has none -- `nil == nil` would skip the rule
    -- under every such row for entirely the wrong reason.
    eq(dividerOpts({ { kind = "folder" }, { kind = "folder" } }, 1).skip, nil)
end)

t.done()



