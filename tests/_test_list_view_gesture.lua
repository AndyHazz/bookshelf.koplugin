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

local t = dofile("tests/_helpers.lua").runner()

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

-- ── _viewMode: the widget asks ViewMode, with the two real keys ────────────

local function viewMode(opts)
    local settings = opts.settings or {}
    local env = {
        ViewMode = ViewMode,
        _covers_pin = opts.pin or 0,
        BookshelfSettings = {
            isTrue = function(key)
                -- Fails loudly on a key nobody stubbed, so a widget that went
                -- back to a single setting (or invented a fourth) is caught
                -- here rather than by a screenshot.
                assert(key == ViewMode.KEY_EXPANDED
                       or key == ViewMode.KEY_COLLAPSED
                       or key == ViewMode.KEY_IN_FOLDER,
                    "_viewMode read an unexpected setting key: " .. tostring(key))
                return settings[key] == true
            end,
        },
    }
    return methodOf("_viewMode", env)({
        _expanded         = opts.expanded,
        _isDrilledIn      = function() return opts.in_folder == true end,
        _chipViewMode     = function()
            return ViewMode.chipOverride(opts.chip_mode)
        end,
    })
end

t.test("_viewMode resolves through ViewMode's three keys", function()
    assert(viewMode{ expanded = true } == "covers")
    assert(viewMode{ expanded = true,
        settings = { list_when_expanded = true } } == "list")
    -- The collapsed key must not reach an expanded shelf, or the two
    -- checkboxes are one checkbox with two labels.
    assert(viewMode{ expanded = true,
        settings = { list_when_collapsed = true } } == "covers")
    assert(viewMode{ expanded = false,
        settings = { list_when_collapsed = true } } == "list")
    assert(viewMode{ expanded = false,
        settings = { list_when_expanded = true } } == "covers")
end)

t.test("the folder key turns a list on, and only inside a folder", function()
    local s = { list_when_in_folder = true }
    assert(viewMode{ expanded = false, settings = s } == "covers",
        "the folder key must not reach the top level of a chip")
    assert(viewMode{ expanded = true, settings = s } == "covers")
    assert(viewMode{ expanded = false, in_folder = true, settings = s } == "list")
    assert(viewMode{ expanded = true,  in_folder = true, settings = s } == "list",
        "it applies in both shelf states -- it is not a third exclusive case")
end)

t.test("the folder key can only turn a list ON, never off", function()
    -- The OR, from the widget's side. A user with the shelf-wide setting on
    -- must not lose their list by drilling into a folder -- that reads as the
    -- drill breaking a setting, and nobody asked for it.
    local s = { list_when_expanded = true, list_when_collapsed = true }
    assert(viewMode{ expanded = true,  in_folder = true, settings = s } == "list")
    assert(viewMode{ expanded = false, in_folder = true, settings = s } == "list")
end)

t.test("a chip pinned to List is a list wherever you are in it", function()
    -- Nothing else is on, so this is the pin doing all of the work.
    assert(viewMode{ expanded = false, chip_mode = ViewMode.LIST } == "list")
    assert(viewMode{ expanded = true,  chip_mode = ViewMode.LIST } == "list")
    assert(viewMode{ expanded = false, in_folder = true,
                     chip_mode = ViewMode.LIST } == "list")
end)

t.test("a chip pinned to Covers is the ONE thing that can force covers off",
function()
    -- Every other term in the model is an OR that can only turn a list ON.
    -- A chip is where a reader says "not here", explicitly and per shelf, and
    -- it has to beat all three globals AND the folder key.
    local all_on = { list_when_expanded = true, list_when_collapsed = true,
                     list_when_in_folder = true }
    assert(viewMode{ expanded = false, chip_mode = ViewMode.COVERS,
                     settings = all_on } == "covers")
    assert(viewMode{ expanded = true, chip_mode = ViewMode.COVERS,
                     settings = all_on } == "covers")
    assert(viewMode{ expanded = true, in_folder = true,
                     chip_mode = ViewMode.COVERS, settings = all_on } == "covers")
end)

t.test("an unset or unrecognised pin falls through to the globals", function()
    -- Absence is the third state: follow the settings. A value from a later
    -- release, or a hand-edited chip, must do the same rather than reach a
    -- renderer as a mode it has no branch for.
    for _i, v in ipairs({ "default", "grid", "", "list-view", 7 }) do
        assert(viewMode{ expanded = false, chip_mode = v } == "covers",
            "unrecognised pin was honoured: " .. tostring(v))
        assert(viewMode{ expanded = false, chip_mode = v,
                         settings = { list_when_collapsed = true } } == "list",
            "unrecognised pin blocked the globals: " .. tostring(v))
    end
    assert(viewMode{ expanded = false, chip_mode = nil,
                     settings = { list_when_collapsed = true } } == "list")
end)

t.test("the tile style is not consulted for the mode at all", function()
    -- The two settings were briefly one field. _viewMode must read the mode
    -- key and nothing else -- a stub that only answers _chipViewMode proves
    -- it, since a widget still reaching for _groupDisplayMode would error.
    assert(viewMode{ expanded = false } == "covers")
    assert(viewMode{ expanded = false,
                     settings = { list_when_collapsed = true } } == "list")
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
    -- puts the user in the same "inside one thing" place the setting is about.
    local env = { ViewMode = ViewMode }
    local f = methodOf("_isDrilledIn", env)
    assert(f({ _drilldown_path = {} }) == false)
    assert(f({ _drilldown_path = nil }) == false)
    assert(f({ _drilldown_path = { { kind = "series" } } }) == true)
    assert(f({ _drilldown_path = { { kind = "folder" }, { kind = "author" } } })
        == true)
end)

t.test("the covers pin beats both settings", function()
    -- What _asCoverGrid buys: every geometry helper asks _isListMode(), so
    -- this is the only way a caller can ask them "what would the cover grid
    -- do on this screen". A pin that lost to the settings would let
    -- _gridBaseRows answer with a count of LIST rows and resize the grid the
    -- user returns to.
    assert(viewMode{ expanded = true, pin = 1,
        settings = { list_when_expanded = true, list_when_collapsed = true } }
        == "covers")
    assert(viewMode{ expanded = false, pin = 2,
        settings = { list_when_expanded = true, list_when_collapsed = true } }
        == "covers")
end)

t.test("_isListMode is _viewMode, not a second derivation", function()
    local calls = 0
    local env = { ViewMode = ViewMode }
    local self = { _viewMode = function() calls = calls + 1 return "list" end }
    assert(methodOf("_isListMode", env)(self) == true)
    self._viewMode = function() calls = calls + 1 return "covers" end
    assert(methodOf("_isListMode", env)(self) == false)
    assert(calls == 2, "_isListMode must go through _viewMode")
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

-- ── _flipViewMode: the long-press writes ONE key ───────────────────────────

local function flip(expanded, settings, in_folder, chip_mode)
    local saved, flushes = {}, 0
    local rebuilt, notices = 0, {}
    local env = {
        ViewMode = ViewMode,
        BookshelfSettings = {
            isTrue = function(key) return settings[key] == true end,
            save   = function(key, value)
                settings[key] = value
                saved[#saved + 1] = key
            end,
            flush  = function() flushes = flushes + 1 end,
        },
        logger    = { dbg = function() end },
        UIManager = {
            setDirty = function() end,
            show     = function(_self, w) notices[#notices + 1] = w.text end,
        },
        -- The "still a list here" notice: a Notification stand-in that records
        -- its text, so the test can assert the gesture EXPLAINS itself rather
        -- than appearing to do nothing.
        require   = function() return { new = function(_s, t) return t end } end,
        _         = function(s) return s end,
        tostring  = tostring,
        -- No page items: the cursor re-anchoring is _test_jump_scan_list's
        -- business, and stubbing it here would only assert the stub.
        _itemFilepath = function() return nil end,
    }
    local self
    self = {
        _expanded         = expanded,
        _markOpdsNav      = function() end,
        _rebuild          = function() rebuilt = rebuilt + 1 end,
        _isDrilledIn      = function() return in_folder == true end,
        _chipViewMode     = function()
            return ViewMode.chipOverride(chip_mode)
        end,
        -- The real resolver, run against the same stubs, so the "still a list"
        -- check is answering the question the shelf would answer rather than a
        -- convenient constant.
        _isListMode = function()
            local vm = methodOf("_viewMode", {
                ViewMode = ViewMode,
                        _covers_pin = 0,
                BookshelfSettings = {
                    isTrue = function(k) return settings[k] == true end,
                },
            })
            return vm(self) == ViewMode.LIST
        end,
    }
    methodOf("_flipViewMode", env)(self)
    return saved, flushes, rebuilt, notices
end

t.test("holding while expanded writes only the expanded key", function()
    local s = {}
    local saved, flushes, rebuilt = flip(true, s)
    assert(#saved == 1 and saved[1] == ViewMode.KEY_EXPANDED,
        "keys written: " .. table.concat(saved, ","))
    assert(s.list_when_expanded == true, "the expanded setting did not go on")
    assert(s.list_when_collapsed == nil,
        "the collapsed setting was touched by an expanded hold")
    assert(flushes == 1, "the write was not flushed (" .. flushes .. " flushes)")
    assert(rebuilt == 1, "the flip must force a full rebuild, not the fast path")
end)

t.test("holding while collapsed writes only the collapsed key", function()
    local s = {}
    local saved = flip(false, s)
    assert(#saved == 1 and saved[1] == ViewMode.KEY_COLLAPSED,
        "keys written: " .. table.concat(saved, ","))
    assert(s.list_when_collapsed == true)
    assert(s.list_when_expanded == nil,
        "the expanded setting was touched by a collapsed hold")
end)

t.test("the hold toggles rather than sets", function()
    local s = { list_when_expanded = true, list_when_collapsed = true }
    flip(true, s)
    assert(s.list_when_expanded == false, "a second hold did not turn it off")
    assert(s.list_when_collapsed == true, "the other key moved")
    flip(true, s)
    assert(s.list_when_expanded == true, "a third hold did not turn it back on")
end)

t.test("the two states are toggled independently across a sequence", function()
    -- Expanded on, collapsed on, expanded off: three holds in two states, and
    -- the pair must end up exactly where the sequence says.
    local s = {}
    flip(true,  s)
    flip(false, s)
    flip(true,  s)
    assert(s.list_when_expanded == false and s.list_when_collapsed == true,
        string.format("ended at expanded=%s collapsed=%s",
            tostring(s.list_when_expanded), tostring(s.list_when_collapsed)))
end)

t.test("holding inside a folder writes only the folder key", function()
    local s = {}
    local saved, _flushes, _rebuilt, notices = flip(false, s, true)
    assert(#saved == 1 and saved[1] == ViewMode.KEY_IN_FOLDER,
        "keys written: " .. table.concat(saved, ","))
    assert(s.list_when_in_folder == true)
    assert(s.list_when_collapsed == nil,
        "the collapsed setting was touched by a hold inside a folder")
    assert(#notices == 0, "turning it ON needs no explanation")
end)

t.test("turning the folder key off while the shelf-wide one is on says so",
function()
    -- The OR means this changes nothing on screen. A deliberate long-press
    -- that appears to do nothing is indistinguishable from one that did not
    -- register, so it has to explain itself.
    local s = { list_when_in_folder = true, list_when_collapsed = true }
    local _saved, _flushes, _rebuilt, notices = flip(false, s, true)
    assert(s.list_when_in_folder == false, "the key must still be written")
    assert(#notices == 1, "expected one notice, got " .. #notices)
    assert(notices[1]:find("shelf%-wide"), "unhelpful notice: " .. notices[1])

    -- ...and NOT when the folder key really was what was holding the list on.
    local s2 = { list_when_in_folder = true }
    local _s, _f, _r, quiet = flip(false, s2, true)
    assert(#quiet == 0, "a decisive toggle must not apologise for working")
end)

t.test("the hold names the CHIP when that is what is deciding", function()
    -- The same trap one layer out: with the chip pinned, the shelf-state key
    -- changes nothing on screen. The message has to name the setting that is
    -- actually responsible, or it sends the user to the wrong screen.
    local s = { list_when_collapsed = true }
    local _saved, _f, _r, notices = flip(false, s, false, ViewMode.LIST)
    assert(s.list_when_collapsed == false, "the key must still be written")
    assert(#notices == 1, "expected one notice, got " .. #notices)
    assert(notices[1]:find("chip"),
        "the notice blamed the wrong setting: " .. notices[1])
end)

t.test("the hold explains a chip pinned to COVERS too", function()
    -- The other direction, which only the chip pin can produce: the user holds
    -- to turn a list ON and the shelf stays covers. Silently doing nothing here
    -- is the same failure as the list case and needs the same answer.
    local s = {}
    local _saved, _f, _r, notices = flip(false, s, false, ViewMode.COVERS)
    assert(s.list_when_collapsed == true, "the key must still be written")
    assert(#notices == 1, "expected one notice, got " .. #notices)
    assert(notices[1]:lower():find("covers"),
        "the notice did not mention covers: " .. notices[1])
end)

t.test("no notice when the write actually did what it said", function()
    -- A chip that follows the globals, nothing else on: the hold turns the
    -- list on and the shelf becomes a list. Explaining that would be noise.
    local s = {}
    local _saved, _f, _r, notices = flip(false, s, false, nil)
    assert(s.list_when_collapsed == true)
    assert(#notices == 0,
        "a working toggle apologised for itself: " .. (notices[1] or ""))
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
local function listCols(setting, content_w)
    local env = {
        BookshelfSettings = { read = function() return setting end },
        Screen = { scaleBySize = function(_self, n) return n end },
        LIST_COLUMNS_MAX = LIST_COLUMNS_MAX,
        LIST_MIN_COL_DP  = LIST_MIN_COL_DP,
        math = math, type = type,
    }
    local f = methodWithArgs("_listCols", env)
    return f({
        _layoutPrimitives = function() return 20, content_w, 0, 0 end,
    })
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

t.done()
