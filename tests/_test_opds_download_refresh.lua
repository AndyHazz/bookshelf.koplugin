-- tests/_test_opds_download_refresh.lua
-- The shelf refresh that follows a completed OPDS download.
--
-- Regression guard for the missing downloaded tick (device report, PW5): the
-- refresh used to hang off the "Read it now?" box's cancel_callback, so the
-- "Read" answer parked a shelf whose page records predated the download. The
-- way back from the reader is main.lua's _raiseInPlace, which reorders the
-- window stack and repaints -- it never re-fetches -- so the cell the user had
-- just downloaded showed no tick for the rest of the visit.
--
-- What is asserted: _opdsRunDownload rebuilds the shelf ONCE, BEFORE the prompt
-- is shown, and neither answer to the prompt adds or removes a rebuild.
--
-- Usage (from plugin root): lua tests/_test_opds_download_refresh.lua

package.path = "./?.lua;./?/init.lua;" .. package.path

-- ── Minimal class system ───────────────────────────────────────────────────
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

-- ── Recorders the stubs write into ─────────────────────────────────────────
local log = {}
local function note(what) log[#log + 1] = what end
local shown = {}   -- every widget handed to UIManager:show

-- ── KOReader stubs ─────────────────────────────────────────────────────────
local widget_cls = make_widget_class()
package.loaded["ui/widget/container/inputcontainer"]  = widget_cls
package.loaded["ui/widget/container/framecontainer"]  = make_widget_class()
package.loaded["ui/widget/container/centercontainer"] = make_widget_class()
package.loaded["ui/widget/verticalgroup"]             = make_widget_class()
package.loaded["ui/widget/horizontalgroup"]           = make_widget_class()
package.loaded["ui/widget/textwidget"]                = make_widget_class()
package.loaded["ui/widget/textboxwidget"]             = make_widget_class()
package.loaded["ui/widget/verticalspan"]              = make_widget_class()
package.loaded["ui/geometry"]     = { new = function(_, t) return t or {} end }
package.loaded["ui/gesturerange"] = { new = function(_, t) return t or {} end }
package.loaded["ui/size"] = {
    padding = { default = 4, large = 8, fullscreen = 16 },
    item    = { height_default = 30 },
    border  = { thin = 1 },
    line    = { medium = 1 },
}
package.loaded["ui/font"] = { getFace = function() return {} end }
package.loaded["ui/uimanager"] = {
    setDirty       = function() note("setDirty") end,
    close          = function() note("close") end,
    show           = function(_, w) note("show"); shown[#shown + 1] = w end,
    nextTick       = function(_, fn) if fn then fn() end end,
    scheduleIn     = function() end,
    unschedule     = function() end,
    isWidgetShown  = function() return false end,
}
package.loaded["ffi/blitbuffer"] = { COLOR_BLACK = 0, COLOR_WHITE = 0xFF,
                                     gray = function(v) return v end }
package.loaded["device"] = {
    screen = {
        getWidth    = function() return 1236 end,
        getHeight   = function() return 1648 end,
        scaleBySize = function(_, n) return n end,
    },
    isKindle = function() return false end,
}
package.loaded["logger"] = { dbg = function() end, warn = function() end,
                             err = function() end, info = function() end }
package.loaded["lib/bookshelf_settings_store"] = {
    read      = function(_, default) return default end,
    save      = function() note("settings_save") end,
    delete    = function() end,
    flush     = function() end,
    isTrue    = function() return false end,
    nilOrTrue = function() return true end,
}
package.loaded["lib/bookshelf_i18n"] = {
    gettext  = function(t) return t end,
    ngettext = function(s, p, n) return n == 1 and s or p end,
}
package.loaded["lib/bookshelf_book_repository"] = {
    invalidateWalkCache = function() note("invalidateWalkCache") end,
}
package.loaded["lib/bookshelf_hero_card"] = {
    new = function() return {} end,
    buildStatusRow = function() return nil end,
}
package.loaded["lib/bookshelf_chip_bar"]  = { new = function() return {} end }
package.loaded["lib/bookshelf_shelf_row"] = {}
-- Stubbed rather than loaded: bookshelf_cover_progress opens the real
-- ffi.typeof("ColorRGB32") at load, which only resolves inside KOReader (the
-- cdef lives in its blitbuffer). Loading it here would make this suite a
-- luajit-only failure, which is exactly the shape _test_collection_sort.lua
-- already has. Nothing on the download tail reads from it.
package.loaded["lib/bookshelf_cover_progress"] = {
    decide          = function() return { bar = false, bar_pct = 0, glyph = nil } end,
    resolvedColors  = function() return {} end,
    badgeSize       = function(n) return n end,
    glyphRenderedH  = function() return 0 end,
}
-- Same reason (it opens the ffi type too, at lib/bookshelf_spine_widget.lua's
-- top). The download tail never builds a cover.
package.loaded["lib/bookshelf_spine_widget"] = {
    new                 = function() return {} end,
    setDraftMode        = function() end,
    trueAspectBoxHeight = function(_w, _b, max_h) return max_h end,
    downloadedTickOffset = function() return 0, 0 end,
}

-- Modules _opdsRunDownload requires at CALL time. Each is the smallest thing
-- that lets the success path run to the prompt.
package.loaded["lib/bookshelf_opds_download"] = {
    STORE_KEY = "opds_downloads",
    download  = function(_url, dest) note("download"); return dest end,
    pruneMap  = function(map) return map, 0 end,
}
package.loaded["lib/bookshelf_opds_source"] = {
    getServer = function() return { url = "http://host/", title = "T" } end,
    serverKey = function() return "deadbeef" end,
}
package.loaded["lib/bookshelf_opds_feed"] = {
    sameOrigin = function() return true end,
}
package.loaded["lib/bookshelf_cover_fetch"] = {
    runWhenOnline = function(fn) fn() end,
}
package.loaded["ui/trapper"] = {
    wrap  = function(_, fn) fn() end,
    info  = function() return true end,
    clear = function() end,
}
package.loaded["ui/widget/confirmbox"] = {
    new = function(_, spec) spec.is_confirmbox = true; return spec end,
}
package.loaded["ui/widget/notification"] = { new = function(_, s) return s end }
package.loaded["ui/widget/infomessage"]  = { new = function(_, s) return s end }

_G.G_reader_settings = {
    readSetting = function() return nil end,
    saveSetting = function() end,
    isTrue      = function() return false end,
    flush       = function() end,
}

-- Benign mock for every KOReader core dep the widget pulls in at load time but
-- this path never reads a real value from (same fallback the tall-screen
-- suite installs, and for the same reason).
local function mock()
    local m = {}
    return setmetatable(m, {
        __index = function() return function() return mock() end end,
        __call  = function() return mock() end,
    })
end
table.insert(package.searchers or package.loaders, function(_name)
    return function() return mock() end
end)

local BW = dofile("lib/bookshelf_widget.lua")

local t = dofile("tests/_helpers.lua").runner()
local function eq(a, e, msg)
    if a ~= e then
        error((msg or "") .. " expected=" .. tostring(e) .. " got=" .. tostring(a), 2)
    end
end
local function count(what)
    local n = 0
    for _i = 1, #log do if log[_i] == what then n = n + 1 end end
    return n
end
local function indexOf(what)
    for i = 1, #log do if log[i] == what then return i end end
    return nil
end

-- A shelf stand-in carrying only what the download tail touches.
local function shelf()
    local s = setmetatable({
        _opds_download_started_at = nil,
        _opds_fetch_started_at    = nil,
    }, { __index = BW })
    s._rebuild      = function() note("rebuild") end
    s._launchReader = function() note("launchReader") end
    return s
end

local BOOK = { filepath = "OPDS://deadbeef/urn:uuid:1", title = "Zeta Remote" }
local ACQ  = { href = "http://host/zeta.epub", type = "application/epub+zip" }
local DEST = "/books/Zeta Remote.epub"

local function run()
    log, shown = {}, {}
    local s = shelf()
    BW.live = s
    s:_opdsRunDownload(BOOK, ACQ, DEST, nil)
    local box
    for _i = 1, #shown do if shown[_i].is_confirmbox then box = shown[_i] end end
    return s, box
end

t.test("download tail rebuilds the shelf exactly once", function()
    run()
    eq(count("rebuild"), 1, "rebuild count:")
end)

t.test("the rebuild happens BEFORE the prompt is shown", function()
    local _s, box = run()
    assert(box, "no ConfirmBox was shown")
    local r, sh = indexOf("rebuild"), indexOf("show")
    assert(r and sh, "missing rebuild/show in log")
    assert(r < sh, "rebuild must run before the prompt is shown")
end)

t.test("the rebuild happens AFTER the mapping is stored", function()
    run()
    local save, r = indexOf("settings_save"), indexOf("rebuild")
    assert(save and r, "missing save/rebuild in log")
    assert(save < r, "the mapping must be written before the shelf re-reads it")
end)

-- The regression itself: "Read" must not be the answer that skips the refresh.
-- Returning from the reader goes through _raiseInPlace, which repaints the
-- parked widget without re-fetching, so a shelf rebuilt only on the cancel
-- branch stays stale for the whole visit.
t.test("Read answer inherits the refresh and adds no second rebuild", function()
    local _s, box = run()
    assert(box and box.ok_callback, "no ok_callback on the prompt")
    box.ok_callback()
    eq(count("rebuild"), 1, "rebuild count after Read:")
    eq(count("launchReader"), 1, "launchReader count:")
end)

t.test("Not now answer adds no second rebuild", function()
    local _s, box = run()
    assert(box, "no ConfirmBox was shown")
    -- No cancel_callback by design: the refresh runs before the box is shown,
    -- so every dismissal already sits on a current shelf.
    eq(box.cancel_callback, nil, "cancel_callback should be gone")
    eq(count("rebuild"), 1, "rebuild count after Not now:")
end)

t.test("a shelf that died mid-transfer is not rebuilt", function()
    log, shown = {}, {}
    local s = shelf()
    BW.live = shelf()   -- a DIFFERENT widget is live now
    s:_opdsRunDownload(BOOK, ACQ, DEST, nil)
    eq(count("rebuild"), 0, "rebuild count on a dead shelf:")
end)

t.done()
