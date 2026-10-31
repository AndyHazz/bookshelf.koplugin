-- tests/_test_book_popup_review.lua
-- Fixes from the 2026-10-31 review of the book popup.
--
-- Usage (from plugin root): lua tests/_test_book_popup_review.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local H = dofile("tests/_helpers.lua")
local t = H.runner()
local w = io.open("lib/bookshelf_widget.lua"):read("*a")

t.test("a plugin's action card is keyed by its registration, not its label", function()
    assert(w:find('if type(id) == "string" then row._bs_id = id end', 1, true), "the registration id is not kept")
    assert(w:find('local key = row._bs_id and (row._bs_id .. "#" .. _ci) or text', 1, true),
        "a card's place is keyed by a label that can change")
end)

t.test("arranging: greyed where a button can't act, and kept however the popup closes", function()
    assert(w:find("enabled = at ~= nil and at > 1, on_tap = function() move(-1) end", 1, true), "back is not greyed at the first card")
    assert(w:find("enabled = at ~= nil and at < #arranging.order", 1, true), "on is not greyed at the last card")
    assert(w:find("Arr.canHide(all_tiles, arranging.hidden, sel)) and true or false", 1, true), "Hide is not greyed")
    assert(w:find("local arr = modal and modal._actions_edit", 1, true)
        and w:find("BookshelfSettings.save(require(\"lib/bookshelf_book_actions_layout\").KEY,", 1, true),
        "closing the popup while arranging leaves the arrangement unwritten")
end)

t.test("the Favorite card wears the reader's mark; choices act at once; Refresh greys while busy", function()
    assert(w:find('icon = favCardIcon(inFav())', 1, true), "the Favorite card is always a heart")
    assert(w:find('function() startArranging(id) end, id == "favorite")', 1, true), "Favorite shows pressed first")
    assert(w:find("enabled   = not tab.busy,", 1, true), "Refresh goes black while busy")
    assert(w:find("or ((a.enabled == false) and Blitbuffer.COLOR_GRAY)", 1, true), "a greyed card is dark grey")
end)

-- The Reviews tab's source switch, Refresh, Include spoilers and its Edit
-- could not be reached with the keys (only the Description tab's switch was).
t.test("the review tabs' switch and buttons take the keys", function()
    local body = w:match("\n(local function _reviewKeys%(above, btn, on_chips, rest%).-\nend)\n")
    assert(body, "no _reviewKeys")
    local keys = assert(load(body .. "\nreturn _reviewKeys", "rk", "t", _G))()
    local a, b, btn, sp = {}, {}, {}, {}
    local above = { seg_rows = { { a, b } } }
    local rows = keys(above, btn, true, { { sp } })
    H.eq(#rows, 2); assert(rows[1][3] == btn and rows[2][1] == sp, "Refresh not on the chips' row")
    assert(rows[1] ~= above.seg_rows[1], "the switch's own row was handed over to be merged")
    rows = keys(above, btn, false)
    H.eq(#rows, 2); assert(rows[2][1] == btn)
    rows = keys(nil, btn, false)
    H.eq(#rows, 1)
    assert(w:find("if keys and #keys > 0 then body.focus_tables = { focusRow(keys) } end", 1, true),
        "the Reviews tab does not register its keys")
    assert(w:find("body.focus_tables = { focusRow(_reviewKeys(above, btn, on_chips ~= nil)) }", 1, true),
        "My review's Edit does not take the keys")
end)

-- Rig, 2026-10-31: the header is kept for the popup's life, so after
-- picking Finished it still read "Unopened" beside the black Finished.
t.test("a status change builds the header again, its reading line with it", function()
    local rm = io.open("lib/bookshelf_reviews_modal.lua"):read("*a")
    local drop = rm:match("\n(function ReviewsModal:dropHeader%(%).-\nend)\n")
    assert(drop and drop:find("self._header_widget = nil", 1, true), "no way to drop the kept header")
    assert(drop:find("_owned_cover_bb", 1, true), "a dropped header's own cover is not freed")
    local seg = w:match("on_pick = function%(key%)\n%s*bw:_commitBookStatus%(book, key%)(.-)end,")
    assert(seg and seg:find("modal:dropHeader()", 1, true), "the status change keeps the old header")
end)

-- Perf review 2026-10-31: a status, favourite or star tap rebuilt the whole
-- shelf (200-600 ms on a PW5) before the popup could show it.
t.test("the popup shows a tap at once; the shelf behind is rebuilt once the taps pause", function()
    local r = w:match("local function refreshInPlace%(%)(.-)\n    end\n")
    assert(r and r:find("modal:rebuildTab()", 1, true) and r:find("shelfSoon()", 1, true)
        and r:find("rebuildTab", 1, true) < r:find("shelfSoon", 1, true), "the shelf is rebuilt before the popup")
    assert(w:find("UIManager:scheduleIn(0.4, modal._shelf_fire)", 1, true), "the shelf rebuild is not debounced")
    assert(w:find("bw:_setBookRating(book, newv, { skip_rebuild = true })", 1, true), "a star tap rebuilds the shelf at once")
    assert(w:find("if modal and modal._shelf_owed and modal._shelf_fire then", 1, true), "closing leaves the shelf stale")
end)

t.done()
