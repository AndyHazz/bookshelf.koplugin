-- tests/_test_book_popup_review.lua
-- Fixes from the 2026-10-31 review of the book popup.
--
-- Usage (from plugin root): lua tests/_test_book_popup_review.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local H = dofile("tests/_helpers.lua")
local t = H.runner()
local w = dofile("tests/_widget_source.lua")

t.test("a plugin's action card is keyed by its registration, not its label", function()
    assert(w:find('if type(id) == "string" then row._bs_id = id end', 1, true), "the registration id is not kept")
    assert(w:find('local key = row._bs_id and (row._bs_id .. "#" .. _ci) or text', 1, true),
        "a card's place is keyed by a label that can change")
end)

-- Maintainer: the Hardcover section sat at the foot of the Edit tab, half
-- under the footer; the Arrange card goes (a long-press on the shelf opens
-- Arrange) and a Hardcover card takes the slot.
t.test("Actions: a Hardcover card, no Arrange card, no Hardcover section at the foot", function()
    assert(w:find('id = "hardcover", text = _("Hardcover link"),', 1, true), "no Hardcover card")
    assert(w:find('after = "select",   -- its place in an order saved before it existed', 1, true),
        "the card has no place in an order saved before it")
    assert(not w:find('id = "shelf_move"', 1, true), "the Arrange card is still there")
    assert(not w:find('vg[#vg + 1] = heading("Hardcover")', 1, true), "the section at the foot is still there")
end)

-- Maintainer: the cards mixed one-line and two-line labels. Labels of a
-- like length, left to wrap on their own (no forced breaks: another font
-- size would break them badly).
t.test("card labels of a like length: a shelf, book info, multiple, Hardcover link", function()
    assert(w:find('text = _("Add to a shelf")', 1, true), "Add to a shelf")
    assert(w:find('text = _("Show book info")', 1, true), "Show book info")
    assert(w:find('text = _("Select multiple")', 1, true), "Select multiple")
    -- Two words each, so the whole grid wraps alike on a PW5 (maintainer).
    assert(w:find('id = "move", text = _("Move book files\\xE2\\x80\\xA6")', 1, true), "Move book files...")
    assert(w:find('id = "delete", text = _("Delete book files\\xE2\\x80\\xA6")', 1, true), "Delete book files...")
    -- "Favorite on/off" broke after the slash (PW5): a card's label keeps
    -- a word with a slash in it whole.
    assert(w:find('local function keepSlashWords(text) return (text:gsub("/", "/\\xE2\\x81\\xA0")) end', 1, true),
        "a slash in a card's label can still break")
    assert(w:find("TextBoxWidget:new{ text = keepSlashWords(a.text)", 1, true), "the cards do not use it")
end)

-- Maintainer's order, and two more labels: "Favourite on/off", "Reload
-- metadata". Built top to bottom in that order, so the code reads as the
-- grid does.
t.test("the cards' default order, and the two relabelled", function()
    local order = { "favorite", "shelf", "info", "refresh", "select", "hardcover",
                    "move", "history", "reset", "delete" }
    local last = 0
    for _i, id in ipairs(order) do
        local at = w:find('id = "' .. id .. '"', 1, true)
        assert(at, "no card " .. id)
        assert(at > last, id .. " is out of order")
        last = at
    end
    assert(w:find('text = _("Favorite on/off")', 1, true), "Favorite on/off")
    assert(w:find('text = _("Reload metadata")', 1, true), "Reload metadata")
end)

-- Maintainer: "If a book is linked to hardcover, the old menu would show
-- that, and the title of the book linked. We have lost that by moving to an
-- action button."
t.test("a linked book: the Hardcover card lit, and the linked title under Hardcover's stars", function()
    assert(w:find('id = "hardcover", text = _("Hardcover link"),\n            on = hc_linked,', 1, true),
        "the card does not show the book is linked")
    -- Not under the stars (maintainer: "I don't think it looks right"): a
    -- line below the actions.
    assert(not w:find("hcCaption(", 1, true), "the title is still under the stars")
    assert(w:find('T(_("Hardcover linked to: %1"), hc_linked_label)', 1, true), "no line below the actions")
    assert(w:find("function tap:onTapHcLinked()", 1, true)
        and w:find("bw:_openHardcoverMenu(book) end)", w:find("function tap:onTapHcLinked()", 1, true), true),
        "the line does not open the Hardcover menu")
end)

t.test("an empty reviews list says when Hardcover withheld them", function()
    assert(w:find("Hardcover.reviewsWithheld(result)", 1, true), "the popup never asks")
    assert(w:find("Tokens.reviewsHtml{ reviews = list, empty_text = empty_text }", 1, true),
        "the reason does not reach the list")
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
