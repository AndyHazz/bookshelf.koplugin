-- tests/_test_tokens.lua
-- Pure-Lua test runner. No KOReader dependencies.
-- Usage: cd into the plugin dir, then `lua tests/_test_tokens.lua`.

package.loaded["device"] = {
    getPowerDevice = function() return nil end,
    isKindle = function() return false end,
    hasNaturalLight = function() return false end,
    home_dir = "/",
}
package.loaded["datetime"] = {
    secondsToClockDuration = function(s)
        if not s or s <= 0 then return "" end
        local h = math.floor(s / 3600)
        local m = math.floor((s % 3600) / 60)
        return string.format("%dh %02dm", h, m)
    end,
}
-- Stub both require keys: lib code requires the canonical "lib/bookshelf_i18n"
-- (e.g. bookshelf_tokens for its catalogue descriptions), some callers the
-- bare "bookshelf_i18n". gettext is identity so the catalogue holds source.
local _i18n_stub = {
    gettext = function(t) return t end,
    ngettext = function(s, p, n) return n == 1 and s or p end,
}
package.loaded["bookshelf_i18n"] = _i18n_stub
package.loaded["lib/bookshelf_i18n"] = _i18n_stub
_G.G_reader_settings = setmetatable({}, {
    readSetting = function() return nil end,
    isTrue = function() return false end,
    __index = function() return function() return false end end,
})

local Tokens = dofile("lib/bookshelf_tokens.lua")

local pass, fail = 0, 0
local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then pass = pass + 1
    else fail = fail + 1; io.stderr:write("FAIL  " .. name .. "\n  " .. tostring(err) .. "\n") end
end
local function eq(a, e, msg)
    if a ~= e then error((msg or "") .. " expected=" .. tostring(e) .. " got=" .. tostring(a), 2) end
end

-- ============================================================================
test("smoke: Tokens module loads", function()
    assert(type(Tokens) == "table", "Tokens is not a table")
    assert(type(Tokens.expand) == "function", "Tokens.expand missing")
end)

local function bookFixture()
    return {
        title = "Dune",
        author = "Frank Herbert",
        authors = { "Frank Herbert" },
        series = "Dune #1",
        series_name = "Dune",
        series_num = "1",
        filename = "dune",
        lang = "en",
        format = "EPUB",
    }
end

test("metadata: %title", function()
    eq(Tokens.expand("%title", bookFixture()), "Dune")
end)
test("metadata: %author", function()
    eq(Tokens.expand("%author", bookFixture()), "Frank Herbert")
end)
test("metadata: %series", function()
    eq(Tokens.expand("%series", bookFixture()), "Dune #1")
end)
test("metadata: literal text passes through", function()
    eq(Tokens.expand("Reading %title by %author.", bookFixture()),
       "Reading Dune by Frank Herbert.")
end)
test("metadata: %hardcover_rating formats cached rating", function()
    local b = bookFixture(); b.hardcover_rating = 4.5
    eq(Tokens.expand("%hardcover_rating", b), "4.5")
end)
-- Nerd Font star glyphs: full U+F005, half-empty U+F123, empty U+F006.
local HC_STAR  = "\xef\x80\x85"
local HC_HALF  = "\xef\x84\xa3"
local HC_EMPTY = "\xef\x80\x86"

test("metadata: %hardcover_stars renders half-star ratings", function()
    local b = bookFixture(); b.hardcover_rating = 4.5
    eq(Tokens.expand("%hardcover_stars", b),
       HC_STAR:rep(4) .. HC_HALF)
end)
-- User ratings stay in native KOReader integer format (plain Unicode stars),
-- kept deliberately separate from the Hardcover half-star rendering.
local U_STAR  = "\xE2\x98\x85"  -- ★ U+2605
local U_EMPTY = "\xE2\x98\x86"  -- ☆ U+2606
test("metadata: %rating renders whole stars (native integer)", function()
    local b = bookFixture(); b.rating = 3
    eq(Tokens.expand("%rating", b), U_STAR:rep(3) .. U_EMPTY:rep(2))
end)
test("metadata: %rating floors a fractional rating (no half stars)", function()
    local b = bookFixture(); b.rating = 4.5
    eq(Tokens.expand("%rating", b), U_STAR:rep(4) .. U_EMPTY)
end)
test("metadata: %rating stays empty for an unrated book", function()
    eq(Tokens.expand("%rating", bookFixture()), "")
end)
test("metadata: empty Hardcover rating stays empty", function()
    eq(Tokens.expand("%hardcover_rating|%hardcover_stars", bookFixture()), "|")
end)
test("metadata: missing token resolves to empty", function()
    local b = bookFixture(); b.series = nil
    eq(Tokens.expand("%series", b), "")
end)

test("position: %page_num / %page_count", function()
    local b = bookFixture(); b.page_num = 142; b.page_count = 688
    eq(Tokens.expand("%page_num / %page_count", b), "142 / 688")
end)
test("position: %book_pct rounds to integer percent", function()
    local b = bookFixture(); b.book_pct = 0.213
    eq(Tokens.expand("%book_pct", b), "21%")
end)
test("position: %book_pct_left", function()
    local b = bookFixture(); b.book_pct = 0.213
    eq(Tokens.expand("%book_pct_left", b), "79%")
end)
test("position: %pages_left = page_count - page_num", function()
    local b = bookFixture(); b.page_num = 142; b.page_count = 688
    eq(Tokens.expand("%pages_left", b), "546")
end)

-- ── %size / %added / %opened ───────────────────────────────────────────────
--
-- The three file facts. The FORMAT is what is pinned here, not merely
-- non-emptiness: the list view's own accessors render the same three values
-- through Tokens.formatFileSize / Tokens.formatDate, so a change to either
-- formatter has to break something.

test("file: %size renders bytes / KB / MB the way the list column did", function()
    local b = bookFixture()
    b.size = 900;              eq(Tokens.expand("%size", b), "900 B")
    b.size = 2048;             eq(Tokens.expand("%size", b), "2 KB")
    b.size = 1024 * 1024 * 3 / 2
    eq(Tokens.expand("%size", b), "1.5 MB")
end)
test("file: %size is empty when the record has no size", function()
    eq(Tokens.expand("%size", bookFixture()), "")
end)
test("file: a zero-byte file is '0 B', not empty", function()
    local b = bookFixture(); b.size = 0
    eq(Tokens.expand("%size", b), "0 B")
end)
test("file: a negative size is nonsense, so it is empty", function()
    local b = bookFixture(); b.size = -1
    eq(Tokens.expand("%size", b), "")
end)

test("file: %added / %opened render an ISO date", function()
    local when = os.time({ year = 2026, month = 3, day = 9, hour = 12 })
    local b = bookFixture()
    b.date_added, b.last_opened = when, when
    eq(Tokens.expand("%added", b), os.date("%Y-%m-%d", when))
    eq(Tokens.expand("%opened", b), os.date("%Y-%m-%d", when))
end)
test("file: an absent or zero epoch is no date, not 1970", function()
    local b = bookFixture()
    eq(Tokens.expand("%added|%opened", b), "|")
    -- The OPDS feed parser stamps a literal modification = 0 on every
    -- catalogue record it builds; 1970-01-01 down a column of them was the
    -- bug the list view's own date accessor already had to refuse.
    b.date_added, b.last_opened = 0, 0
    eq(Tokens.expand("%added|%opened", b), "|")
end)

test("file: the three tokens are in the picker catalogue", function()
    local seen = {}
    for _i, e in ipairs(Tokens.CATALOGUE) do seen[e.token] = e end
    for _i, tok in ipairs({ "%size", "%added", "%opened" }) do
        assert(seen[tok], tok .. " is expandable but not offered in the picker")
        assert(type(seen[tok].description) == "string"
            and seen[tok].description ~= "", tok .. " has no description")
        assert(Tokens.categoryLabel(seen[tok].category),
            tok .. " has no category label")
    end
end)

test("file: %size does not swallow another token's name", function()
    -- Tokens.expand gsubs each name in turn, longest first. A new short name
    -- that is a prefix of a longer one would eat it; assert the three new ones
    -- leave every existing token intact.
    local b = bookFixture()
    b.size, b.date_added, b.last_opened = 1024, 1, 1
    for name in pairs(Tokens.expanders) do
        if name ~= "size" and name ~= "added" and name ~= "opened" then
            assert(not name:find("^size") and not name:find("^added")
                and not name:find("^opened"),
                "%" .. name .. " starts with one of the new token names")
        end
    end
end)

local function clockState()
    return { now = os.time({ year=2026, month=5, day=3, hour=14, min=35, sec=0 }) }
end

test("time: %time_24h", function()
    eq(Tokens.expand("%time_24h", bookFixture(), clockState()), "14:35")
end)
test("time: %time_12h", function()
    eq(Tokens.expand("%time_12h", bookFixture(), clockState()), "2:35 PM")
end)
test("date: %weekday", function()
    eq(Tokens.expand("%weekday", bookFixture(), clockState()), "Sunday")
end)
test("datetime: custom strftime", function()
    eq(Tokens.expand("%datetime{%d %B}", bookFixture(), clockState()), "03 May")
end)

test("stats: %book_time_left formats minutes → 'Nh MMm'", function()
    local b = bookFixture(); b.book_time_left_minutes = 131
    eq(Tokens.expand("%book_time_left", b), "2h 11m")
end)
test("stats: missing → empty", function()
    eq(Tokens.expand("%book_time_left", bookFixture()), "")
end)
test("annotations: %highlights pluralisation", function()
    local b = bookFixture(); b.highlights = 3
    eq(Tokens.expand("%highlights", b), "3")
end)
test("device: %batt with state", function()
    eq(Tokens.expand("%batt", bookFixture(), { batt = 73 }), "73%")
end)
test("device: %wifi off → wifi-off Nerd Font glyph", function()
    eq(Tokens.expand("%wifi", bookFixture(), { wifi = "off" }), "\xee\xb2\xa9")
end)
test("device: %wifi on → wifi Nerd Font glyph", function()
    eq(Tokens.expand("%wifi", bookFixture(), { wifi = "on" }), "\xee\xb2\xa8")
end)

test("if: token-truthy", function()
    local b = bookFixture()
    eq(Tokens.expand("[if:series]Series: %series_name[/if]", b), "Series: Dune")
end)
test("if: token-falsy → empty", function()
    local b = bookFixture(); b.series = nil; b.series_name = nil
    eq(Tokens.expand("[if:series]Series: %series_name[/if]", b), "")
end)
test("if/else: book_pct numeric compare", function()
    local b = bookFixture(); b.book_pct = 0.7
    eq(Tokens.expand("[if:book_pct>50]Almost done[else]%book_pct[/if]", b), "Almost done")
end)
test("if: not operator", function()
    local b = bookFixture(); b.series = nil
    eq(Tokens.expand("[if:not series]Standalone[/if]", b), "Standalone")
end)
test("if: nested", function()
    local b = bookFixture(); b.book_pct = 0.95
    eq(Tokens.expand("[if:book_pct>50][if:book_pct>90]Final![else]Halfway+[/if][/if]", b), "Final!")
end)
test("if: equality with quoted string", function()
    eq(Tokens.expand([=[[if:author="Frank Herbert"]✓[/if]]=], bookFixture()), "✓")
end)
test("if: full_width gates on state.full_width (issue 178)", function()
    eq(Tokens.expand("%title[if:full_width] · DATE[/if]", bookFixture(), { full_width = true }),
       "Dune · DATE")
    -- absent / false -> empty (cover-view narrow status)
    eq(Tokens.expand("%title[if:full_width] · DATE[/if]", bookFixture()), "Dune")
    eq(Tokens.expand("%title[if:full_width] · DATE[/if]", bookFixture(), {}), "Dune")
end)
test("device: [if:connected] gates the Wi-Fi icon on actual link (issue 181)", function()
    eq(Tokens.expand("[if:connected]ON[/if]", bookFixture(), { connected = "yes" }), "ON")
    eq(Tokens.expand("[if:connected]ON[/if]", bookFixture(), { connected = "no"  }), "")
    -- bookends-style explicit comparison works too
    eq(Tokens.expand("[if:connected=yes]ON[/if]", bookFixture(), { connected = "yes" }), "ON")
    eq(Tokens.expand("[if:connected=yes]ON[/if]", bookFixture(), { connected = "no"  }), "")
end)

test("inline: [b]bold[/b] tags survive expansion", function()
    eq(Tokens.expand("[b]%title[/b]", bookFixture()), "[b]Dune[/b]")
end)
test("inline: nested [b][i] preserved", function()
    eq(Tokens.expand("[b][i]%title[/i][/b]", bookFixture()), "[b][i]Dune[/i][/b]")
end)

test("width: {N} cap is preserved as marker for renderer", function()
    -- The token engine resolves the value but leaves {N} intact, so the
    -- renderer can measure pixels and truncate. We test that the token
    -- expansion happens AND the width-cap suffix is preserved.
    local b = bookFixture(); b.title = "An extremely long book title that goes on"
    eq(Tokens.expand("%title{200}", b), "An extremely long book title that goes on{200}")
end)

test("autoHide: line of all empty tokens is hidden", function()
    local b = bookFixture(); b.book_time_left_minutes = nil
    eq(Tokens.isEmpty(Tokens.expand("%book_time_left", b)), true)
end)
test("autoHide: line with literal text is not empty", function()
    eq(Tokens.isEmpty(Tokens.expand("Reading %title", bookFixture())), false)
end)

test("if: or before and (left-to-right operator scan)", function()
    local b = bookFixture(); b.series = nil; b.book_pct = 0.95
    -- 'series' is empty (false), but 'book_pct>50' is true; left-to-right
    -- evaluation: false or true = true; (true) and (true [book_pct>0]) = true
    eq(Tokens.expand("[if:series or book_pct>50]yes[/if]", b), "yes")
end)

test("if: unknown comparison operator → false (defensive default)", function()
    -- '==' is not a supported operator. The atom should evaluate to false,
    -- not silently flip to true via 'not nil'.
    eq(Tokens.expand("[if:not author==\"Frank\"]matched[/if]", bookFixture()), "matched")
end)

test("isEmpty: only [b][i][u] tags strip, not arbitrary single-letter tags", function()
    -- A future hypothetical [c]color[/c] tag should NOT be stripped by isEmpty.
    eq(Tokens.isEmpty("[c]hi[/c]"), false)
end)

test("nightmode: sun glyph when night_mode off (default mock)", function()
    -- The shared mock returns false for any G_reader_settings:isTrue check,
    -- so the expander takes the day branch and emits U+EC98 (weather-sunny).
    eq(Tokens.expand("%nightmode", bookFixture()), "\xee\xb2\x98")
end)

test("nightmode: never expands to literal %nightmode", function()
    local result = Tokens.expand("%nightmode", bookFixture())
    assert(result ~= "%nightmode", "expander missing — token leaked through")
end)

test("bar: %bar survives expansion as literal (renderer splits on it)", function()
    eq(Tokens.expand("%bar", bookFixture()), "%bar")
    -- Other tokens around %bar still expand normally.
    local b = bookFixture(); b.book_pct = 0.36
    eq(Tokens.expand("%book_pct  %bar  done", b), "36%  %bar  done")
end)

test("description: empty when book has no blurb", function()
    local b = bookFixture(); b.description = nil
    eq(Tokens.expand("%description", b), "")
end)

test("description: passes plain text through", function()
    local b = bookFixture(); b.description = "A novel about sandworms."
    eq(Tokens.expand("%description", b), "A novel about sandworms.")
end)

test("description: strips HTML tags", function()
    local b = bookFixture(); b.description = "<p>Hello <b>world</b>.</p>"
    eq(Tokens.expand("%description", b), "Hello world.")
end)

test("description: <br> becomes newline", function()
    local b = bookFixture(); b.description = "Line one<br/>Line two"
    eq(Tokens.expand("%description", b), "Line one\nLine two")
end)

test("description: </p> becomes blank line", function()
    local b = bookFixture(); b.description = "<p>One</p><p>Two</p>"
    eq(Tokens.expand("%description", b), "One\n\nTwo")
end)

test("description: decodes named entities", function()
    local b = bookFixture(); b.description = "Tom &amp; Jerry &lt;3"
    eq(Tokens.expand("%description", b), "Tom & Jerry <3")
end)

test("description: decodes numeric entity to UTF-8", function()
    local b = bookFixture(); b.description = "It&#8217;s good"
    eq(Tokens.expand("%description", b), "It\xE2\x80\x99s good")
end)

test("description: trims surrounding whitespace", function()
    local b = bookFixture(); b.description = "   leading and trailing   "
    eq(Tokens.expand("%description", b), "leading and trailing")
end)

test("description: decodes &rsquo; / &lsquo; / &ldquo; / &rdquo;", function()
    local b = bookFixture()
    b.description = "&lsquo;hi&rsquo; said &ldquo;the cat&rdquo;"
    eq(Tokens.expand("%description", b),
       "\xE2\x80\x98hi\xE2\x80\x99 said \xE2\x80\x9Cthe cat\xE2\x80\x9D")
end)

test("description: decodes &mdash; / &ndash; / &hellip; / &nbsp;", function()
    local b = bookFixture()
    b.description = "wait&hellip; ndash&ndash;mdash&mdash;nbsp&nbsp;end"
    eq(Tokens.expand("%description", b),
       "wait\xE2\x80\xA6 ndash\xE2\x80\x93mdash\xE2\x80\x94nbsp\xC2\xA0end")
end)

test("description: decodes hex numeric entity", function()
    local b = bookFixture()
    b.description = "It&#x2019;s &#xA9; mine"
    eq(Tokens.expand("%description", b), "It\xE2\x80\x99s \xC2\xA9 mine")
end)

test("description: <div> blocks become paragraphs", function()
    local b = bookFixture()
    b.description = "<div>One</div><div>Two</div>"
    eq(Tokens.expand("%description", b), "One\n\nTwo")
end)

test("description: collapses 3+ newlines to 2", function()
    local b = bookFixture()
    -- Source has literal \n between </p> and <p>: </p> → \n\n, then the
    -- existing \n adds a third → would render as a triple-blank line.
    b.description = "<p>One</p>\n<p>Two</p>"
    eq(Tokens.expand("%description", b), "One\n\nTwo")
end)

test("description: case-insensitive tags (BR, P, DIV)", function()
    local b = bookFixture()
    b.description = "<P>Upper</P><BR/>after"
    eq(Tokens.expand("%description", b), "Upper\n\nafter")
end)

test("description: strips indentation from pretty-printed <p> blocks (#306)", function()
    local b = bookFixture()
    -- Some publishers/editors pretty-print paragraph HTML with an indented
    -- newline right after the opening tag: <p>\n  Text\n</p>. The </p> -> \n\n
    -- pass and the 3+-newline collapse only touch newlines, so the leading
    -- indentation spaces survive and show up as a stray leading space on
    -- every paragraph after the first.
    b.description = "<p>\n  One\n</p>\n<p>\n  Two\n</p>"
    eq(Tokens.expand("%description", b), "One\n\nTwo")
end)

-- Hardcover reviews HTML (sanitiser + builder) ------------------------------
local function has(s, sub, msg)
    if not (type(s) == "string" and s:find(sub, 1, true)) then
        error((msg or "missing substring") .. " : [" .. tostring(sub)
            .. "] not in [" .. tostring(s) .. "]", 2)
    end
end
local function hasnt(s, sub, msg)
    if type(s) == "string" and s:find(sub, 1, true) then
        error((msg or "unexpected substring") .. " : [" .. tostring(sub) .. "]", 2)
    end
end

test("sanitiseReviewHtml keeps whitelisted tags, strips attrs + unknown tags", function()
    local out = Tokens.sanitiseReviewHtml(
        '<p class="x">Hi <i>there</i> <span>kept-text</span></p>')
    eq(out, "<p>Hi <i>there</i> kept-text</p>")
end)
test("sanitiseReviewHtml drops script blocks with their content", function()
    local out = Tokens.sanitiseReviewHtml('<p>ok</p><script>alert(1)</script>')
    eq(out, "<p>ok</p>")
end)
test("sanitiseReviewHtml normalises self-closing br and tag case", function()
    eq(Tokens.sanitiseReviewHtml('a<BR/>b'), "a<br>b")
end)
test("sanitiseReviewHtml strips <br> padding at paragraph edges", function()
    -- leading <br> after a blockquote (the quote/attribution gap) is dropped;
    -- the real break after the attribution is kept.
    eq(Tokens.sanitiseReviewHtml(
        "<blockquote>q</blockquote><p><br><strong>cite</strong><br>text<br></p>"),
       '<blockquote>q</blockquote><div class="p"><strong>cite</strong><br>text</div>')
end)
test("sanitiseReviewHtml returns empty for nil/empty", function()
    eq(Tokens.sanitiseReviewHtml(nil), "")
    eq(Tokens.sanitiseReviewHtml(""), "")
end)

test("reviewsHtml italicises reviewer names and escapes them", function()
    local html = Tokens.reviewsHtml{
        title = "Dune", rating = 4, ratings_count = 10, reviews_count = 1,
        reviews = { { user_name = "A<B", text = "<p>Great</p>" } },
    }
    has(html, "<i>A&lt;B</i>", "reviewer name not italic+escaped")
    has(html, "<b>Review by</b>", "missing bold Review-by label")
end)
test("reviewsHtml puts the book title in a large h1 heading, escaped", function()
    local html = Tokens.reviewsHtml{
        title = "Tom & Jerry", reviews = { { user_name = "x", text = "hi" } },
    }
    has(html, "<h1>Tom &amp; Jerry</h1>", "title not a large escaped heading")
end)
test("reviewsHtml renders shared star glyphs for each review", function()
    local html = Tokens.reviewsHtml{
        title = "T",
        reviews = { { user_name = "x", rating = 4, text = "hi" } },
    }
    -- Same glyph row as the ratings area (Tokens.starString, F005/F123/F006),
    -- embedded via @font-face, on its own line above each review. 4 -> ★★★★☆
    -- (the overall rating/counts/Refresh line is a native widget row now, not
    -- part of this HTML -- see bookshelf_widget.lua's ReviewsHeader).
    has(html, '<p class="stars">' .. HC_STAR:rep(4) .. HC_EMPTY .. "</p>", "per-review star row")
end)
test("reviewsHtml formats the date (ISO fallback without datetime module)", function()
    local html = Tokens.reviewsHtml{
        title = "T",
        reviews = { { user_name = "x", reviewed_at = "2026-04-02T00:00:00", text = "hi" } },
    }
    has(html, "<i>2026-04-02</i>", "date not rendered in italics")
end)
test("reviewsHtml embeds the sanitised review body (script stripped)", function()
    local html = Tokens.reviewsHtml{
        title = "T",
        reviews = { { user_name = "x", text = "<p>Good <i>read</i></p><script>x</script>" } },
    }
    has(html, "<p>Good <i>read</i></p>", "sanitised body missing")
    hasnt(html, "<script>", "script leaked into output")
end)

test("sanitiseReviewHtml: collapses stacked breaks and malformed </br>", function()
    -- Real shape from a Hardcover review that rendered a big mid-review gap:
    -- stacked "<br><br></br>" runs after a paragraph.
    local out = Tokens.sanitiseReviewHtml(
        "<p>quote</p><br><br></br><p>(p.196)</p><br><br></br><br><br></br><br><br></br>")
    assert(not out:find("</br>", 1, true), "malformed </br> survived: " .. out)
    assert(not out:find("<br>%s*<br>"), "stacked <br> not collapsed: " .. out)
    assert(not out:find("</p>%s*<br>"), "<br> hugging </p> survived: " .. out)
    assert(not out:find("<br>%s*$"), "trailing <br> survived: " .. out)
end)

test("sanitiseReviewHtml: drops break between block boundary and paragraph", function()
    local out = Tokens.sanitiseReviewHtml("</blockquote><br><br><p>x</p>")
    eq(out, "</blockquote><p>x</p>", "boundary break not dropped:")
end)

test("sanitiseReviewHtml: keeps a single intra-paragraph break", function()
    local out = Tokens.sanitiseReviewHtml("<p>line one<br>line two</p>")
    -- div.p, not p: a break-carrying paragraph is converted so KOReader's
    -- <br> workaround cannot close it early (issue #338, tested above).
    eq(out, '<div class="p">line one<br>line two</div>', "single intra-paragraph break lost:")
end)

test("autoLinkReportHtml: lists linked books and counts no-id (exact mode)", function()
    local html = Tokens.autoLinkReportHtml{
        best_guess = false,
        linked  = { { name = "Time Shelter", matched = "Time Shelter", author = "Georgi Gospodinov" } },
        nomatch = { { name = "Obscure Title" } },
        no_id   = 184,
    }
    assert(html:find("Auto%-link report"), "missing title")
    assert(html:find("Time Shelter", 1, true), "linked book name missing")
    assert(html:find("Georgi Gospodinov", 1, true), "matched author missing")
    assert(html:find("Linked %(1%)"), "linked count missing")
    assert(html:find("Not matched %(1%)"), "not-matched section missing")
    assert(html:find("No identifier %(184%)"), "no-id count missing")
    assert(html:find("Obscure Title", 1, true), "not-matched name missing")
end)

test("autoLinkReportHtml: best-guess shows score and no no-id section", function()
    local html = Tokens.autoLinkReportHtml{
        best_guess = true,
        linked  = { { name = "Dune", matched = "Dune", author = "Frank Herbert", score = 97 } },
        nomatch = {},
        no_id   = 0,
    }
    assert(html:find("97%%"), "confidence score missing")
    assert(not html:find("No identifier"), "no-id section should be absent in best-guess mode")
end)

test("autoLinkReportHtml: escapes HTML in names/titles", function()
    local html = Tokens.autoLinkReportHtml{
        best_guess = false,
        linked  = { { name = "A & B <x>", matched = "M & N" } },
        nomatch = {},
    }
    assert(html:find("A &amp; B &lt;x&gt;", 1, true), "name not escaped: " .. html)
    assert(not html:find("<x>", 1, true), "raw angle bracket leaked")
end)

-- ── %status vs %status_label ───────────────────────────────────────────────

test("%status keeps its four canonical values", function()
    -- Load-bearing: [if:status=finished] compares against these, and they must
    -- be the same in every language. Translating them would break every
    -- conditional written against the token, and only for non-English users.
    eq(Tokens.expand("%status", { status = "complete" }, nil),  "finished")
    eq(Tokens.expand("%status", { status = "abandoned" }, nil), "on_hold")
    eq(Tokens.expand("%status", { status = "new" }, nil),       "unread")
    eq(Tokens.expand("%status", {}, nil),                       "unread")
    eq(Tokens.expand("%status", { status = "reading" }, nil),   "reading")
end)

test("%status_label is the readable half, and a separate token", function()
    eq(Tokens.expand("%status_label", { status = "complete" }, nil),  "Finished")
    eq(Tokens.expand("%status_label", { status = "abandoned" }, nil), "On hold")
    eq(Tokens.expand("%status_label", { status = "reading" }, nil),   "Reading")
    eq(Tokens.expand("%status_label", {}, nil),                       "Unread")
    -- A state this build has not heard of is still information: show the raw
    -- value rather than blanking, which would look like a broken token.
    eq(Tokens.expand("%status_label", { status = "marinating" }, nil),
       "marinating")
end)

test("the longest-name-first pass does not eat %status_label", function()
    -- The expander loop substitutes by name, longest first. Were the order
    -- ever reversed, "%status_label" would match "%status" and render
    -- "reading_label" -- which compiles, renders, and is wrong.
    eq(Tokens.expand("%status_label / %status", { status = "reading" }, nil),
       "Reading / reading")
end)

-- ── %favourite ─────────────────────────────────────────────────────────────
--
-- Membership comes from ReadCollection, not from the book record: on every
-- fetch path except the Favourites chip itself, book.in_favorites is nil, so a
-- token that trusted the record would render nothing on almost every page.
-- Stubbed here for the same reason the real one reaches past the record.

local FAV = {}
package.loaded["readcollection"] = { coll = { favorites = FAV } }
package.loaded["lib/bookshelf_cover_progress"] = {
    FAV_GLYPH_STAR  = "STAR",
    FAV_GLYPH_HEART = "HEART",
    favoriteIcon    = function() return package.loaded._fav_icon or "heart" end,
}

test("%favourite renders the icon only for a favourite", function()
    for k in pairs(FAV) do FAV[k] = nil end
    eq(Tokens.expand("%favourite", { filepath = "/a.epub" }, nil), "")
    FAV["/a.epub"] = true
    eq(Tokens.expand("%favourite", { filepath = "/a.epub" }, nil), "HEART")
    eq(Tokens.expand("%favourite", { filepath = "/b.epub" }, nil), "")
    -- No filepath at all (a group projection) must not error.
    eq(Tokens.expand("%favourite", { title = "Sci-fi" }, nil), "")
end)

test("%favourite follows the fav_icon setting the cover badge reads", function()
    for k in pairs(FAV) do FAV[k] = nil end
    FAV["/a.epub"] = true
    package.loaded._fav_icon = "star"
    eq(Tokens.expand("%favourite", { filepath = "/a.epub" }, nil), "STAR")
    package.loaded._fav_icon = nil
end)

test("both spellings resolve, and gate a conditional", function()
    for k in pairs(FAV) do FAV[k] = nil end
    FAV["/a.epub"] = true
    eq(Tokens.expand("%favorite", { filepath = "/a.epub" }, nil), "HEART")
    -- The conditional grammar falls through to the expanders, so one
    -- definition gives [if:favourite] as well -- which is what lets a template
    -- put a separator round the icon without leaving a stray one everywhere
    -- else.
    eq(Tokens.expand("[if:favourite]%favourite [/if]%title",
        { filepath = "/a.epub", title = "Dune" }, nil), "HEART Dune")
    eq(Tokens.expand("[if:favourite]%favourite [/if]%title",
        { filepath = "/b.epub", title = "Dune" }, nil), "Dune")
end)

-- ── A modifier never outlives its token ────────────────────────────────────
--
-- %bar takes brace modifiers ({rel} today). Every surface that DELETES a %bar
-- has to delete the brace form first, or the token goes and the modifier stays
-- -- and "{rel}" renders as literal text next to nothing.
--
-- Asserted against the source because the renderers need a framebuffer to run
-- and the mistake is a missing gsub, which is visible. Tokens owns this because
-- Tokens owns the modifier vocabulary: menuPreview strips modifiers before it
-- expands for exactly the same reason.

test("the hero drops %bar{rel} when it drops %bar", function()
    local src = io.open("lib/bookshelf_hero_card.lua"):read("*a")
    -- The branch that runs for a book with no reading position, which is EVERY
    -- OPDS preview -- a remote book has no book_pct. Reported from one:
    -- "%bar{rel} ... in an opds preview '{rel}' is left as text in the hero".
    -- Bounded by the landmark that FOLLOWS it rather than by a matching
    -- `end`: an `end` anchor is indentation-sensitive, and against the buggy
    -- one-line version it ran on and swallowed unrelated source that happened
    -- to contain a brace pattern -- so the test passed the check it was
    -- supposed to fail and reported the wrong reason for failing the next one.
    local block = src:match(
        "if not %(book and book%.book_pct%) then(.-)if not Tokens%.isEmpty")
    assert(block, "the unopened-book strip is gone or was renamed")
    -- COMMENTS OUT FIRST, the same precaution _test_list_row_budget takes on
    -- its own source read: the comment beside this code quotes the pattern it
    -- is describing, so a check that reads the prose passes on the strength of
    -- the documentation while the code beneath it is wrong. Caught by breaking
    -- the code deliberately and watching the test stay green.
    block = block:gsub("%-%-[^\n]*", "")
    local braces = block:find('{[%w_,]*}', 1, true)
    -- Either spelling of a bare strip: the constant, or the literal it holds.
    local bare = block:find('BAR_TOKEN_PATTERN, ""', 1, true)
                 or block:find('gsub("%%bar", "")', 1, true)
    assert(braces, "the strip must remove %bar with a brace modifier")
    assert(bare, "the strip must remove a bare %bar too")
    -- ORDER. A bare strip first eats the token and leaves the braces behind,
    -- which is precisely the reported bug -- so this is not a stylistic point.
    assert(braces < bare,
        "the brace form has to be stripped BEFORE the bare token")
end)

test("the list drops %bar{rel} when it drops %bar", function()
    -- The same rule on the other renderer: stripElastic and stripBar both
    -- delete bar tokens, and a remote record's bar is dropped through the
    -- latter.
    local src = io.open("lib/bookshelf_list_row.lua"):read("*a")
    for _i, fn in ipairs({ "stripElastic", "stripBar" }) do
        local block = src:match("local function " .. fn .. "%(s%)(.-)\nend")
        assert(block, fn .. " is gone or was renamed")
        local braces = block:find('{[%w_,]*}', 1, true)
        local bare   = block:find('BAR_TOKEN_PATTERN, ""', 1, true)
        assert(braces and bare and braces < bare,
            fn .. " must strip the brace form, and before the bare token")
    end
end)

-- ── mapOutsideElastic: a case transform must not respell a token ───────────
--
-- The bug it fixes: a list line with UPPERCASE set ran its whole expanded
-- string through TextSegments.upper, "%spacer" included. findElastic matches
-- the token lowercase, so the line stopped having one and rendered
-- "THE HOBBIT%SPACER★★★★☆" as a single left-aligned run.
--
-- string.upper stands in for TextSegments.upper here: this suite runs under a
-- plain interpreter and the real one needs utf8proc. What is being tested is
-- WHERE the function is applied, not what it does.

test("uppercasing a line leaves %spacer a spacer", function()
    local out = Tokens.mapOutsideElastic("The Hobbit%spacer4 stars",
                                         string.upper)
    eq(out, "THE HOBBIT%spacer4 STARS")
    -- The point of the whole exercise: the result still splits.
    assert(out:find("%%spacer"), "the token must survive as a token")
end)

test("uppercasing leaves %bar and its modifier alone", function()
    eq(Tokens.mapOutsideElastic("read%bar{rel}left", string.upper),
       "READ%bar{rel}LEFT")
    eq(Tokens.mapOutsideElastic("a%barb", string.upper), "A%barB")
end)

test("mapOutsideElastic walks tokens in the order they appear", function()
    -- NOT findElastic's ranking, which hands %bar the slack wherever it sits.
    -- Applied in that order the spacer would fall inside the "before" run and
    -- be uppercased anyway, which is the bug all over again.
    eq(Tokens.mapOutsideElastic("a%spacerb%bar{rel}c", string.upper),
       "A%spacerB%bar{rel}C")
end)

test("mapOutsideElastic transforms a line with no tokens at all", function()
    eq(Tokens.mapOutsideElastic("plain text", string.upper), "PLAIN TEXT")
    eq(Tokens.mapOutsideElastic("", string.upper), "")
    eq(Tokens.mapOutsideElastic(nil, string.upper), nil)
end)

test("mapOutsideElastic keeps a token at either end", function()
    eq(Tokens.mapOutsideElastic("%spacertail", string.upper), "%spacerTAIL")
    eq(Tokens.mapOutsideElastic("head%spacer", string.upper), "HEAD%spacer")
    eq(Tokens.mapOutsideElastic("%spacer", string.upper), "%spacer")
end)

test("the elastic patterns are spelled in exactly one place", function()
    -- The fix above only holds while the walker and the renderer agree on what
    -- a token looks like. A second copy of "%%spacer" in the row is how they
    -- come apart -- and it is how this bug was introduced in the first place.
    local src = io.open("lib/bookshelf_list_row.lua"):read("*a")
    local code = {}
    for line in src:gmatch("[^\n]+") do
        if not line:match("^%s*%-%-") then code[#code + 1] = line end
    end
    code = table.concat(code, "\n")
    assert(code:match("SPACER_TOKEN_PATTERN%s*=%s*Tokens%.SPACER_PATTERN"),
        "the row must take the spacer pattern from Tokens, not restate it")
    assert(code:match("BAR_TOKEN_PATTERN%s*=%s*Tokens%.BAR_PATTERN"),
        "the row must take the bar pattern from Tokens, not restate it")
    assert(not code:match('"%%%%spacer"'),
        "a second literal spelling of the spacer token is back in the row")
end)

test("the row uppercases AROUND the elastic tokens", function()
    -- The call site, pinned. lineText hands one pre-rendered string to both
    -- the budget and the renderer, so it is the only place the transform can
    -- happen -- and applying it bare is the bug.
    local src = io.open("lib/bookshelf_list_row.lua"):read("*a")
    local block = src:match("function ListRow%.lineText%b()(.-)\nend\n")
    assert(block, "ListRow.lineText is gone or was renamed")
    block = block:gsub("%-%-[^\n]*", "")   -- the prose quotes both spellings
    assert(block:match("Tokens%.mapOutsideElastic"),
        "lineText must uppercase through Tokens.mapOutsideElastic")
    assert(not block:match("text%s*=%s*TextSegments%.upper%(text%)"),
        "lineText must not uppercase the whole expanded line: that respells "
        .. "%spacer and %bar and demotes them to plain text")
end)

-- ── Issue 338: a <br> must not survive inside a <p> ─────────────────────────
--
-- KOReader's HtmlBoxWidget rewrites every <br> to "&nbsp;<div></div>" to work
-- around a MuPDF bug, and HTML5 parsing closes a <p> at a <div> -- so the
-- FIRST break in any paragraph gained a full paragraph margin. Rendered as:
-- "an extra line break for the first time the <br> appears", and only the
-- first. The sanitiser now converts a break-carrying <p> to <div class="p">,
-- which the modal styles with the same margins.

test("a paragraph containing breaks becomes div.p", function()
    local out = Tokens.sanitiseReviewHtml("<p>a<br>b<br>c</p>")
    eq(out, '<div class="p">a<br>b<br>c</div>')
end)

test("a paragraph without breaks stays a paragraph", function()
    -- The rhythm rules (p.stars, p.byline, the reviews' own paragraphs) key
    -- on <p>; rewriting every paragraph would orphan them.
    eq(Tokens.sanitiseReviewHtml("<p>plain paragraph</p>"),
       "<p>plain paragraph</p>")
end)

test("mixed paragraphs convert individually", function()
    local out = Tokens.sanitiseReviewHtml(
        "<p>a<br>b</p><p>no breaks</p><p>c<br>d</p>")
    eq(out, '<div class="p">a<br>b</div><p>no breaks</p>'
         .. '<div class="p">c<br>d</div>')
end)

test("the reporter's calibre shape comes out break-safe", function()
    -- The exact structure from issue 338: one <p>, every line separated by a
    -- <br> at the start of a source line.
    local raw = "<div>\n<p>Book one\n<br>Book two\n<br>Book three</p></div>"
    local out = Tokens.sanitiseReviewHtml(raw)
    assert(not out:match("<p>"),
        "a break-carrying paragraph must not reach HtmlBoxWidget as a <p>: "
        .. out)
    assert(out:find('<div class="p">', 1, true), "the div.p wrapper is missing")
    -- And the paragraph-edge break rules still ran first: no leading or
    -- trailing breaks inside the converted block.
    assert(not out:match('class="p">%s*<br>'), "an edge break survived")
end)

test("top-level breaks are not touched by the paragraph conversion", function()
    local out = Tokens.sanitiseReviewHtml("<b>x</b><br><b>y</b><br>z")
    assert(out:find("<b>x</b><br>", 1, true),
        "breaks outside any paragraph already rendered correctly and must "
        .. "stay exactly as they were: " .. out)
end)

test("%books_read reads the state, like every device token", function()
    -- A state token on purpose: an expander requiring the repository is the
    -- boundary the token_record suite pins shut. No state, no answer -- the
    -- same degrade %batt has on a list row.
    eq(Tokens.expand("%books_read", bookFixture()), "")
    eq(Tokens.expand("read: %books_read", bookFixture(),
                     { books_read = 42 }), "read: 42")
    -- %sysused (PR 343): same device-state contract as %mem/%ram.
    eq(Tokens.expand("%sysused", bookFixture()), "")
    eq(Tokens.expand("%sysused", bookFixture(), { sysused_mib = 187 }),
       "187 MiB")
    -- The stats-plugin twin follows the same contract.
    eq(Tokens.expand("%books_started", bookFixture()), "")
    eq(Tokens.expand("started: %books_started", bookFixture(),
                     { books_started = 7 }), "started: 7")
end)

test("%calibre{field}: expands from the book's calibre field map", function()
    local book = bookFixture()
    book.calibre = { pubdate = "1974", year = "2005", publisher = "Gollancz" }
    eq(Tokens.expand("(%calibre{pubdate})", book), "(1974)")
    -- Case-insensitive, leading '#' optional: how calibre users know
    -- their own column names.
    eq(Tokens.expand("%calibre{#Year}", book), "2005")
    -- Missing field and missing map both answer empty, not an error.
    eq(Tokens.expand("%calibre{isbn}", book), "")
    eq(Tokens.expand("%calibre{pubdate}", bookFixture()), "")
end)

test("%calibre{field}: works in conditionals, truthy and compared", function()
    local book = bookFixture()
    book.calibre = { pubdate = "1974" }
    eq(Tokens.expand("[if:calibre{pubdate}]dated[/if]", book), "dated")
    eq(Tokens.expand("[if:calibre{pubdate}]dated[/if]", bookFixture()), "")
    eq(Tokens.expand('[if:calibre{pubdate}="1974"]hit[else]miss[/if]', book),
       "hit")
    eq(Tokens.expand("[if:calibre{pubdate}>1980]late[else]early[/if]", book),
       "early")
end)

test("%calibre{field}: survives menuPreview's modifier strip", function()
    local book = bookFixture()
    book.calibre = { pubdate = "1974" }
    local preview = Tokens.menuPreview("%calibre{pubdate} %title", book)
    assert(preview:find("1974", 1, true),
        "the preview must show the expanded field, got: " .. preview)
    assert(not preview:find("calibre", 1, true),
        "no literal %calibre may survive the preview: " .. preview)
end)

io.write(string.format("\n%d passed, %d failed\n", pass, fail))
os.exit(fail == 0 and 0 or 1)
