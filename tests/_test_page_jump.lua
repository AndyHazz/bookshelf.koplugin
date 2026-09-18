-- tests/_test_page_jump.lua
-- Tapping the footer asks for whatever the footer is showing.
--
-- THE RULE, and it is the footer's rule extended to navigation. A grid shelf
-- pages by a fixed number of covers, so "page 3" is exact and its footer
-- prints one. A spine shelf holds a variable number of books a page, its
-- footer prints a BOOK range ("31-38 of 243"), and a page number there is the
-- same fiction the footer already refuses to print -- it comes out of a
-- second planning pass whose page map can disagree with what the render lays
-- out (see _test_pagination_format).
--
-- WHAT WAS WRONG. Not just the label: the jump multiplied the typed page by
-- _viewSize(), the fixed-grid rule a spine shelf does not follow, so a typed
-- page landed neither where the map said nor where the render would draw. A
-- book number needs no arithmetic at all -- the cursor IS the book index, and
-- a spine page starts at the cursor.
--
-- Usage (from plugin root): lua tests/_test_page_jump.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local helpers = dofile("tests/_helpers.lua")
local t  = helpers.runner()
local eq = helpers.eq
local src = io.open("lib/bookshelf_widget.lua"):read("*a")

local body = src:match("\nfunction BookshelfWidget:_openPageJump%(%)\n(.-)\n    UIManager:show%(dialog%)")
assert(body, "_openPageJump moved or was renamed")

-- Runs the dialog builder with a stubbed InputDialog, then presses one of its
-- buttons. Returns what the widget ended up doing.
local function run(opts)
    local shown, typed = {}, opts.typed
    local self_ = {
        page          = opts.page or 1,
        _cursor       = opts.cursor or 1,
        _total_items  = opts.total_items,
        _total_pages  = opts.total_pages,
        _isSpineMode  = function() return opts.spine and true or false end,
        _totalPages   = function(s) return s._total_pages or 1 end,
        _viewSize     = function() return opts.view or 12 end,
        _clampCursor  = function(s) if s._cursor < 1 then s._cursor = 1 end end,
        _syncPageFromCursor = function() end,
        _swapShelvesInPlace = function() shown.swapped = true end,
        _opdsEffectiveTab   = function() return nil end,
        _openSearchDialog   = function() end,
        _jumpToLetterPrefix = function() end,
    }
    local captured
    local env = {
        BookshelfWidget = {},
        _ = function(x) return x end,
        string = string, math = math, tonumber = tonumber, tostring = tostring,
        ipairs = ipairs, pairs = pairs,
        UIManager = {
            show  = function(_s, w) if w and w.text then shown.info = w.text end end,
            close = function() shown.closed = true end,
        },
        require = function(name)
            if name == "ui/widget/inputdialog" then
                return { new = function(_s, cfg)
                    captured = cfg
                    return { getInputText = function() return typed end,
                             onShowKeyboard = function() end }
                end }
            end
            if name == "ui/widget/infomessage" then
                return { new = function(_s, cfg) return cfg end }
            end
            error("unexpected require: " .. tostring(name))
        end,
    }
    local fn = assert(load("return function(self)\n" .. body .. "\nend",
                           "jump", "t", env))()
    fn(self_)
    assert(captured, "the dialog was never built")
    -- The last button row is Cancel + the Go button.
    local go = captured.buttons[#captured.buttons][2]
    if opts.press ~= false then go.callback() end
    return { cfg = captured, go = go, self_ = self_, shown = shown }
end

t.test("a grid shelf still asks for a page, and still pages by the grid", function()
    local r = run{ spine = false, total_pages = 27, page = 3, view = 12, typed = "5" }
    eq(r.cfg.title, "Enter text, letter or page number")
    eq(r.go.text, "Go to page")
    eq(r.cfg.description, "(a - z) or (1 - 27)")
    eq(r.cfg.input_hint, "3", "the hint is the page they are on")
    eq(r.self_._cursor, 49, "page 5 of 12 starts at book 49")
    assert(r.shown.swapped, "the shelf never repainted")
end)

t.test("a spine shelf asks for a book, and the book IS the cursor", function()
    local r = run{ spine = true, total_items = 243, cursor = 31, view = 12,
                   typed = "150" }
    eq(r.cfg.title, "Enter text, letter or book number")
    eq(r.go.text, "Go to book")
    eq(r.cfg.description, "(a - z) or (1 - 243)",
        "the bound must be the book count, not a page estimate")
    eq(r.cfg.input_hint, "31", "the hint is the first book on screen")
    eq(r.self_._cursor, 150, "typing 150 must land on book 150, not 150 * a view")
    assert(r.shown.swapped, "the shelf never repainted")
end)

t.test("the spine jump does not go near _viewSize or the page map", function()
    -- THE BUG. (n - 1) * view + 1 is the fixed-grid rule, and a spine shelf
    -- pages by whatever fits. Reading the page map instead would be no better:
    -- that is the thing that was a page out.
    local go = body:match("text%s+= spine and _%(\"Go to book\"%).-callback%s+= function%(%)(.-)\n                    end")
    assert(go, "the Go button's callback moved")
    local spine_leg = go:match("if spine then(.-)else")
    assert(spine_leg, "the spine leg is gone")
    assert(spine_leg:find("bw._cursor = math.floor(n)", 1, true),
        "the spine jump no longer sets the cursor to the book typed")
    assert(not spine_leg:find("_viewSize", 1, true), "grid arithmetic is back")
    assert(not spine_leg:find("_spineCursorForPage", 1, true),
        "the jump reads the page map, which is the thing that goes stale")
end)

t.test("out of range is refused in the unit the shelf asked for", function()
    local a = run{ spine = true, total_items = 243, typed = "400" }
    assert(a.shown.info and a.shown.info:find("Book must be between", 1, true),
        "a spine shelf complained about pages: " .. tostring(a.shown.info))
    assert(not a.shown.closed, "the dialog closed on bad input")
    local b = run{ spine = false, total_pages = 27, typed = "99" }
    assert(b.shown.info:find("Page must be between", 1, true),
        "a grid shelf complained about books: " .. tostring(b.shown.info))
end)

t.test("an empty shelf still gives a usable bound", function()
    -- total_items nil or 0 would advertise "(1 - 0)" and refuse everything.
    local r = run{ spine = true, total_items = 0, typed = "1" }
    eq(r.cfg.description, "(a - z) or (1 - 1)")
    eq(r.self_._cursor, 1)
end)

t.test("Search and Go to letter are untouched by any of this", function()
    local r = run{ spine = true, total_items = 243, typed = "abc", press = false }
    local first = r.cfg.buttons[1]
    eq(first[1].text, "Search\xE2\x80\xA6")
    eq(first[2].text, "Go to letter")
end)

t.done()
