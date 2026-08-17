-- tests/_test_view_mode.lua
-- Pure-Lua tests for the list/cover view-mode model.
-- Usage (from plugin root): lua tests/_test_view_mode.lua

package.path = "./?.lua;./?/init.lua;" .. package.path

local helpers = dofile("tests/_helpers.lua")
local t       = helpers.runner()

local ViewMode = require("lib/bookshelf_view_mode")

-- ── The model: two independent persisted booleans ──────────────────────────
--
-- One per shelf state. Each decides its own state and says nothing about the
-- other, so the truth table is a lookup with no arbitration in it. This
-- replaced a persisted setting plus a session override that outranked it in
-- both directions -- see the module header for why that went.

-- (expanded, list_when_expanded, list_when_collapsed) -> effective
local CASES = {
    -- expanded, when_expanded, when_collapsed, want
    { false,     false,         false,          "covers" },
    { false,     false,         true,           "list"   },
    { false,     true,          false,          "covers" },  -- expanded flag is not read here
    { false,     true,          true,           "list"   },
    { true,      false,         false,          "covers" },
    { true,      false,         true,           "covers" },  -- collapsed flag is not read here
    { true,      true,          false,          "list"   },
    { true,      true,          true,           "list"   },
}

t.test("effective covers all four settings against both shelf states", function()
    for i, c in ipairs(CASES) do
        local got = ViewMode.effective(c[1], c[2], c[3])
        assert(got == c[4], string.format(
            "case %d (expanded=%s expanded_setting=%s collapsed_setting=%s):"
            .. " got %s want %s",
            i, tostring(c[1]), tostring(c[2]), tostring(c[3]), got, c[4]))
    end
end)

t.test("each setting is inert in the state it does not describe", function()
    -- The independence, stated as its own assertion rather than left to be
    -- inferred from the table: flipping the collapsed setting cannot change
    -- what an expanded shelf renders, and the reverse.
    for _i, expanded_setting in ipairs({ false, true }) do
        local a = ViewMode.effective(true, expanded_setting, false)
        local b = ViewMode.effective(true, expanded_setting, true)
        assert(a == b, "the collapsed setting moved the expanded answer")
    end
    for _i, collapsed_setting in ipairs({ false, true }) do
        local a = ViewMode.effective(false, false, collapsed_setting)
        local b = ViewMode.effective(false, true,  collapsed_setting)
        assert(a == b, "the expanded setting moved the collapsed answer")
    end
end)

t.test("a fresh install, both settings unset, is covers in both states", function()
    -- nil is what BookshelfSettings.isTrue answers for a key nobody has
    -- written, and preserving today's behaviour for that user is the whole
    -- reason both default off.
    assert(ViewMode.effective(true,  nil, nil) == "covers")
    assert(ViewMode.effective(false, nil, nil) == "covers")
end)

t.test("keyFor names the setting that decides THIS state", function()
    -- What the long-press writes. Getting this backwards would make the
    -- gesture change the mode of the state the user is not looking at.
    assert(ViewMode.keyFor(true)  == "list_when_expanded")
    assert(ViewMode.keyFor(false) == "list_when_collapsed")
    assert(ViewMode.keyFor(nil)   == "list_when_collapsed")
    -- The constants and keyFor must agree; the widget reads both.
    assert(ViewMode.KEY_EXPANDED  == "list_when_expanded")
    assert(ViewMode.KEY_COLLAPSED == "list_when_collapsed")
    assert(ViewMode.KEY_EXPANDED ~= ViewMode.KEY_COLLAPSED,
        "one key for both states would make the two checkboxes one checkbox")
end)

-- ── The folder key ─────────────────────────────────────────────────────────

t.test("omitting the folder arguments is exactly the old behaviour", function()
    -- Every pre-folder caller passes three arguments. If adding two optional
    -- ones changed any of those answers, the change would be a silent
    -- regression everywhere except the one place it was aimed at.
    for _i, case in ipairs({
        { true,  true,  false, "list"   },
        { true,  false, true,  "covers" },
        { false, true,  false, "covers" },
        { false, false, true,  "list"   },
        { true,  nil,   nil,   "covers" },
    }) do
        assert(ViewMode.effective(case[1], case[2], case[3]) == case[4],
            string.format("expanded=%s e=%s c=%s", tostring(case[1]),
                tostring(case[2]), tostring(case[3])))
    end
end)

t.test("the folder key ORs with the state key, in both directions", function()
    -- ON when nothing else is.
    assert(ViewMode.effective(false, false, false, true, true) == "list")
    assert(ViewMode.effective(true,  false, false, true, true) == "list")
    -- It cannot turn one OFF: a user who asked for a list everywhere must not
    -- lose it by drilling into a folder.
    assert(ViewMode.effective(true,  true, false, true, false) == "list")
    assert(ViewMode.effective(false, false, true, true, false) == "list")
    -- And it does nothing outside a folder, whatever it says.
    assert(ViewMode.effective(false, false, false, false, true) == "covers")
end)

t.test("keyFor sends a hold inside a folder to the folder key", function()
    assert(ViewMode.keyFor(true,  true)  == "list_when_in_folder")
    assert(ViewMode.keyFor(false, true)  == "list_when_in_folder")
    assert(ViewMode.keyFor(true,  false) == "list_when_expanded")
    assert(ViewMode.keyFor(false, nil)   == "list_when_collapsed")
    assert(ViewMode.KEY_IN_FOLDER == "list_when_in_folder")
end)

t.test("no predicate for 'is this toggle decisive' survives here", function()
    -- There was one, briefly. The gesture now asks the RESOLVED mode after
    -- writing ("am I still a list?") instead, which is strictly better: it also
    -- catches a chip pinned to List, a term this pure resolver cannot see. A
    -- second copy of the precedence living here is how the message would come
    -- to disagree with the screen.
    assert(ViewMode.inFolderKeyIsDecisive == nil,
        "the retired predicate is back; the gesture should ask the mode")
end)

t.test("isList only accepts the list constant", function()
    assert(ViewMode.isList("list") == true)
    assert(ViewMode.isList("covers") == false)
    assert(ViewMode.isList(nil) == false)
end)

-- ── The gesture, as the widget performs it ─────────────────────────────────
--
-- _flipViewMode reads keyFor(self._expanded), writes the negation of that key
-- and touches nothing else. Modelled here against a settings table so the
-- INDEPENDENCE -- the property the two-toggle model exists for -- is pinned
-- rather than assumed. (tests/_test_list_view_gesture.lua drives the widget's
-- real body against the same claim.)
local function hold(settings, expanded)
    local key = ViewMode.keyFor(expanded)
    settings[key] = not (settings[key] == true)
    return key
end

local function modeOf(settings, expanded)
    return ViewMode.effective(expanded,
        settings.list_when_expanded == true,
        settings.list_when_collapsed == true)
end

t.test("holding while expanded leaves the collapsed setting alone", function()
    local s = {}
    assert(modeOf(s, true) == "covers" and modeOf(s, false) == "covers")
    hold(s, true)
    assert(modeOf(s, true) == "list", "the expanded shelf did not flip")
    assert(modeOf(s, false) == "covers",
        "holding while expanded changed what the COLLAPSED shelf shows")
    assert(s.list_when_collapsed == nil, "the other key was written")
end)

t.test("holding while collapsed leaves the expanded setting alone", function()
    local s = {}
    hold(s, false)
    assert(modeOf(s, false) == "list", "the collapsed shelf did not flip")
    assert(modeOf(s, true) == "covers",
        "holding while collapsed changed what the EXPANDED shelf shows")
    assert(s.list_when_expanded == nil, "the other key was written")
end)

t.test("the gesture and the checkboxes cannot disagree", function()
    -- The defect the session override produced, now unreachable by
    -- construction. Under the old model: hold to get list, hold again to get
    -- covers, and the override was "covers" for the rest of the session -- so
    -- ticking the checkbox afterwards did nothing, with no UI to say why.
    -- Here the gesture IS the checkbox, so a flip-flop lands back exactly
    -- where it started and the setting keeps working.
    local s = { list_when_expanded = true }
    hold(s, true)
    assert(s.list_when_expanded == false and modeOf(s, true) == "covers")
    hold(s, true)
    assert(s.list_when_expanded == true and modeOf(s, true) == "list",
        "a flip-flop did not return the shelf to where it started")
    -- And the settings screen reads the same booleans the gesture wrote, in
    -- both states, always.
    for _i, expanded in ipairs({ true, false }) do
        local key = ViewMode.keyFor(expanded)
        assert((s[key] == true) == (modeOf(s, expanded) == "list"),
            "the checkbox for " .. key .. " does not mirror the screen")
    end
end)

t.test("the retired override API is gone, not just unused", function()
    -- A caller left on the old model must fail loudly rather than silently
    -- arming a piece of state nothing reads any more.
    assert(ViewMode.override == nil, "ViewMode.override survived")
    assert(ViewMode.setOverride == nil, "ViewMode.setOverride survived")
    assert(ViewMode.clearOverride == nil, "ViewMode.clearOverride survived")
    -- flip() went with it: with a boolean per state the toggle is `not`, and
    -- a mode-flipping helper would be a second way to say it.
    assert(ViewMode.flip == nil, "ViewMode.flip survived")
end)

t.done()
