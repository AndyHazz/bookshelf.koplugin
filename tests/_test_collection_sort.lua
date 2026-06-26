-- tests/_test_collection_sort.lua
-- Regression test for #205: drilling into a grouped collection (or any stack)
-- must apply the chip's within-group sort, including time-based keys
-- (last_opened / date_added) that are NOT present in the light BIM meta.
-- Before the fix, _applyWithinGroupSort rebuilt books_meta via buildBookMeta
-- (no last_opened) and hydrated only progress/rating/page_count, so a
-- within-stack sort by "Opened" compared all-nil and silently no-op'd.
--
-- Usage (from plugin root): lua tests/_test_collection_sort.lua

package.path = "./?.lua;./?/init.lua;" .. package.path

-- ── Minimal class system ────────────────────────────────────────────────────
local function make_widget_class()
    local cls = {}
    cls.__index = cls
    function cls:extend(props)
        local sub = props or {}
        sub.__index = sub
        setmetatable(sub, { __index = cls })
        return sub
    end
    return cls
end

-- ── KOReader / widget stubs (mirrors _test_tall_screen's harness) ────────────
local widget_cls = make_widget_class()
package.loaded["ui/widget/container/inputcontainer"] = widget_cls
package.loaded["ui/widget/container/framecontainer"] = make_widget_class()
package.loaded["ui/widget/container/centercontainer"] = make_widget_class()
package.loaded["ui/widget/verticalgroup"]             = make_widget_class()
package.loaded["ui/widget/horizontalgroup"]            = make_widget_class()
package.loaded["ui/widget/textwidget"]                = make_widget_class()
package.loaded["ui/widget/textboxwidget"]             = make_widget_class()
package.loaded["ui/widget/verticalspan"]              = make_widget_class()
package.loaded["ui/geometry"]    = { new = function(_, t) return t or {} end }
package.loaded["ui/gesturerange"] = { new = function(_, t) return t or {} end }
package.loaded["ui/size"]        = {
    padding = { default = 4, large = 8, fullscreen = 16 },
    item    = { height_default = 30 }, border = { thin = 1 }, line = { medium = 1 },
}
package.loaded["ui/font"]        = { getFace = function() return {} end }
package.loaded["ui/uimanager"]   = { setDirty = function() end, close = function() end,
                                     show = function() end, nextTick = function(_, fn) end }
package.loaded["ffi/blitbuffer"] = { COLOR_BLACK = 0, COLOR_WHITE = 0xFF,
                                     gray = function(v) return v end }
package.loaded["device"]         = {
    screen = { getWidth = function() return 600 end, getHeight = function() return 800 end,
               scaleBySize = function(_, n) return n end },
    isKindle = function() return false end,
}
package.loaded["logger"]         = { dbg = function() end, warn = function() end,
                                     err = function() end, info = function() end }
package.loaded["lib/bookshelf_settings_store"] = {
    read = function(_, default) return default end, save = function() end,
    delete = function() end, flush = function() end,
    isTrue = function() return false end, nilOrTrue = function() return true end,
    generation = function() return 0 end,   -- SortEngine's pinyin-epoch memo
}
package.loaded["lib/bookshelf_i18n"] = { gettext = function(t) return t end,
                                         ngettext = function(s, p, n) return n == 1 and s or p end }
package.loaded["lib/bookshelf_hero_card"] = { new = function() return {} end,
                                              buildStatusRow = function() return nil end }
package.loaded["lib/bookshelf_chip_bar"] = { new = function() return {} end }
package.loaded["lib/bookshelf_shelf_row"] = {}

-- Repo stub: buildBookMeta returns LIGHT meta with NO last_opened / date_added,
-- exactly reproducing the field gap that caused #205.
package.loaded["lib/bookshelf_book_repository"] = {
    buildBookMeta = function(fp)
        return { filepath = fp, title = (fp:match("([^/]+)$") or fp):gsub("%.%w+$", "") }
    end,
    readProgress = function() return nil end,
}

-- TabModel stub: getById returns our controlled tab; any other call is a no-op.
local TEST_TAB = { sort_priority = nil }
package.loaded["lib/bookshelf_tab_model"] = setmetatable(
    { getById = function() return TEST_TAB end },
    { __index = function() return function() return nil end end })

-- ReadHistory + lfs stubs the fix reads from.
local HIST = {}        -- { { file=, time= }, ... }
local MTIMES = {}      -- filepath -> modification time
package.loaded["readhistory"] = setmetatable({ hist = HIST },
    { __index = function() return function() end end })
package.loaded["libs/libkoreader-lfs"] = {
    attributes = function(path, what)
        if what == "modification" then return MTIMES[path] or 0 end
        return nil   -- no .sdr directories in this test
    end,
}

_G.G_reader_settings = { readSetting = function() return nil end, saveSetting = function() end,
                         isTrue = function() return false end, flush = function() end }

-- Permissive fallback for any unstubbed KOReader core module (explicit stubs and
-- on-disk lib/* files resolve first). NB: bookshelf_sort_engine loads for real.
local function mock()
    return setmetatable({}, { __index = function() return function() return mock() end end,
                              __call = function() return mock() end })
end
table.insert(package.searchers, function(_name) return function() return mock() end end)

local BW = dofile("lib/bookshelf_widget.lua")

-- ── Tiny test runner ─────────────────────────────────────────────────────────
local pass, fail = 0, 0
local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then pass = pass + 1 else fail = fail + 1; print("FAIL  " .. name .. "\n  " .. tostring(err)) end
end
local function widget(chip) return setmetatable({ chip = chip or "x" }, { __index = BW }) end
local function titles(books)
    local t = {} for _i, b in ipairs(books) do t[#t + 1] = b.title end return table.concat(t, ",")
end

-- ── Tests ────────────────────────────────────────────────────────────────────
test("within-group sort by last_opened reorders a drilled stack (#205)", function()
    -- Level 1 orders the stacks; levels 2+ order books within. Here the
    -- within-group key is last_opened (as in the #205 reporter's settings).
    TEST_TAB.sort_priority = { { key = "title" }, { key = "last_opened", reverse = true } }
    for k in pairs(HIST) do HIST[k] = nil end
    HIST[1] = { file = "/lib/B.epub", time = 300 }   -- most recent
    HIST[2] = { file = "/lib/A.epub", time = 200 }
    HIST[3] = { file = "/lib/C.epub", time = 100 }    -- least recent
    -- Books arrive in title order (A, B, C) as getTags would leave them.
    local group = { books = {
        { filepath = "/lib/A.epub", title = "A" },
        { filepath = "/lib/B.epub", title = "B" },
        { filepath = "/lib/C.epub", title = "C" },
    } }
    widget():_applyWithinGroupSort(group)
    -- Most-recently-opened first: B (300), A (200), C (100).
    assert(titles(group.books) == "B,A,C",
        "expected B,A,C by last_opened, got " .. titles(group.books))
end)

test("within-group sort by date_added reorders a drilled stack", function()
    TEST_TAB.sort_priority = { { key = "title" }, { key = "date_added", reverse = true } }
    for k in pairs(MTIMES) do MTIMES[k] = nil end
    MTIMES["/lib/A.epub"] = 50
    MTIMES["/lib/B.epub"] = 90    -- newest
    MTIMES["/lib/C.epub"] = 70
    local group = { books = {
        { filepath = "/lib/A.epub", title = "A" },
        { filepath = "/lib/B.epub", title = "B" },
        { filepath = "/lib/C.epub", title = "C" },
    } }
    widget():_applyWithinGroupSort(group)
    assert(titles(group.books) == "B,C,A",
        "expected B,C,A by date_added, got " .. titles(group.books))
end)

test("single-level sort_priority leaves the group's default order untouched", function()
    -- With only a level-1 sort there are no within-group levels, so the
    -- pre-arranged order is preserved (level 1 orders the stacks, not books).
    TEST_TAB.sort_priority = { { key = "last_opened", reverse = true } }
    local group = { books = {
        { filepath = "/lib/A.epub", title = "A" },
        { filepath = "/lib/B.epub", title = "B" },
    } }
    widget():_applyWithinGroupSort(group)
    assert(titles(group.books) == "A,B", "single-level sort should not reorder books")
end)

print(string.format("%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
